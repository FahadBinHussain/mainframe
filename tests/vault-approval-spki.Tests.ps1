# No Pester dependency. This file has to pass under windows powershell 5.1 AND
# pwsh 7 - the whole point is that the approval flow works in both.
#
# It never touches the network, the vault or the phone. It only builds an RSA
# key in memory and checks the bytes the approval page would import.
$ErrorActionPreference = 'Stop'
$module = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../vault-approval.psm1'))

$script:checks = 0
function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "FAIL: $Message`n  expected: $Expected`n  actual:   $Actual" }
    $script:checks++
}

# a tiny DER reader, enough to walk a SubjectPublicKeyInfo
function Read-DerElement {
    param([byte[]]$Bytes, [ref]$Index)

    $tag = $Bytes[$Index.Value]
    $Index.Value++
    $first = $Bytes[$Index.Value]
    $Index.Value++
    $length = 0
    if ($first -band 0x80) {
        $count = $first -band 0x7F
        for ($i = 0; $i -lt $count; $i++) {
            $length = ($length -shl 8) -bor $Bytes[$Index.Value]
            $Index.Value++
        }
    } else {
        $length = $first
    }
    $content = $Bytes[$Index.Value..($Index.Value + $length - 1)]
    $Index.Value += $length
    return [pscustomobject]@{ Tag = $tag; Length = $length; Content = $content }
}

# 1. the module parses
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($module, [ref]$null, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) 'vault-approval.psm1 parses'

# 2. the native export call is guarded. RSA.ExportSubjectPublicKeyInfo() is
#    .NET Core only, so a bare call would break windows powershell 5.1.
$source = Get-Content -LiteralPath $module -Raw
$bareCalls = [regex]::Matches($source, '\$Rsa\.ExportSubjectPublicKeyInfo\(\)')
Assert-Equal 1 $bareCalls.Count 'the native SPKI export is called from exactly one place'
Assert-True ($source -match "GetMethod\('ExportSubjectPublicKeyInfo'\)") 'the native call is guarded by a runtime check'

Import-Module $module -Force -DisableNameChecking

# 3. the hand rolled encoder and the public helper agree, and where the
#    runtime has the native exporter the bytes are identical to it
$rsa = [System.Security.Cryptography.RSA]::Create(2048)
try {
    $manual = ConvertTo-SubjectPublicKeyInfoManual -Rsa $rsa
    $picked = ConvertTo-SubjectPublicKeyInfo -Rsa $rsa
    Assert-Equal ([Convert]::ToBase64String($manual)) ([Convert]::ToBase64String($picked)) `
        'the public helper returns the hand rolled bytes'

    if ([System.Security.Cryptography.RSA].GetMethod('ExportSubjectPublicKeyInfo')) {
        $native = $rsa.ExportSubjectPublicKeyInfo()
        Assert-Equal ([Convert]::ToBase64String($native)) ([Convert]::ToBase64String($manual)) `
            'the hand rolled bytes are identical to the native ones'
    }

    # 4. the bytes really are a SubjectPublicKeyInfo, because the phone page
    #    imports them with WebCrypto as 'spki' and a wrong structure fails
    #    there with a confusing error
    $idx = 0
    $spki = Read-DerElement -Bytes $manual -Index ([ref]$idx)
    Assert-Equal 0x30 $spki.Tag 'SubjectPublicKeyInfo is a SEQUENCE'
    Assert-Equal $manual.Length ($idx) 'the SEQUENCE covers the whole buffer'

    $idx = 0
    $algorithm = Read-DerElement -Bytes $spki.Content -Index ([ref]$idx)
    Assert-Equal 0x30 $algorithm.Tag 'the algorithm is a SEQUENCE'

    # the algorithm has its own content, so it needs a fresh offset
    $oidIdx = 0
    $oid = Read-DerElement -Bytes $algorithm.Content -Index ([ref]$oidIdx)
    Assert-Equal 0x06 $oid.Tag 'the algorithm carries an OID'
    Assert-Equal '2A864886F70D010101' (($oid.Content | ForEach-Object { $_.ToString('x2') }) -join '') `
        'the OID is rsaEncryption (1.2.840.113549.1.1.1)'

    $nulls = Read-DerElement -Bytes $algorithm.Content -Index ([ref]$oidIdx)
    Assert-Equal 0x05 $nulls.Tag 'the algorithm carries NULL parameters'

    $bitString = Read-DerElement -Bytes $spki.Content -Index ([ref]$idx)
    Assert-Equal 0x03 $bitString.Tag 'the public key is a BIT STRING'
    Assert-Equal 0 $bitString.Content[0] 'the BIT STRING has no unused bits'

    $idx = 0
    $rsaPublicKey = Read-DerElement -Bytes $bitString.Content[1..($bitString.Content.Length - 1)] -Index ([ref]$idx)
    Assert-Equal 0x30 $rsaPublicKey.Tag 'the BIT STRING holds an RSAPublicKey SEQUENCE'

    $innerIdx = 0
    $modulus = Read-DerElement -Bytes $rsaPublicKey.Content -Index ([ref]$innerIdx)
    Assert-Equal 0x02 $modulus.Tag 'the modulus is an INTEGER'
    $exponent = Read-DerElement -Bytes $rsaPublicKey.Content -Index ([ref]$innerIdx)
    Assert-Equal 0x02 $exponent.Tag 'the exponent is an INTEGER'

    # the modulus in the DER has to be the one the key really has
    $expected = $rsa.ExportParameters($false).Modulus
    $actual = $modulus.Content
    if ($actual[0] -eq 0) { $actual = $actual[1..($actual.Length - 1)] }
    Assert-Equal ([Convert]::ToBase64String($expected)) ([Convert]::ToBase64String($actual)) `
        'the DER carries the real modulus'

    # 5. the approval url carries the same key bytes
    $url = Get-VaultApprovalUrl -Rsa $rsa -ExpiresInSeconds 60
    $fragment = ($url.Url -split '#', 2)[1]
    $keyParam = (($fragment -split '&') | Where-Object { $_ -like 'k=*' }) -replace '^k=', ''
    $keyBytes = $keyParam.Replace('-', '+').Replace('_', '/')
    switch ($keyBytes.Length % 4) {
        2 { $keyBytes += '==' }
        3 { $keyBytes += '=' }
    }
    Assert-Equal ([Convert]::ToBase64String($manual)) ([Convert]::ToBase64String([Convert]::FromBase64String($keyBytes))) `
        'the key in the approval url is the exported public key'
} finally {
    $rsa.Dispose()
}

Write-Host "vault-approval spki checks: $script:checks passed"
