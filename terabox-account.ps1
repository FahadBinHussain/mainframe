param()

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'vault-secret.psm1') -Force

$accountRoot = Join-Path $env:APPDATA 'mainframe\accounts\terabox'
$currentFile = Join-Path $accountRoot 'current.json'
$appId = '250528'
$userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/87.0.4280.88 Safari/537.36'

function Show-Usage {
    @'
TeraBox account profile helper (web-session cookie auth)

Profiles are keyed by email and stored in:
  %APPDATA%\mainframe\accounts\terabox\<email>\
cookie.txt is session state (like wrangler oauth state); the account password
lives only in the Bitwarden vault item terabox.com*.

Usage:
  .\terabox-account.ps1 login <email>                 # capture ndus cookie from a live agent-browser session
  .\terabox-account.ps1 import <email> [-Cookie "<raw header cookie>" | -CookieFile <path>]
  .\terabox-account.ps1 use <email>
  .\terabox-account.ps1 current
  .\terabox-account.ps1 list
  .\terabox-account.ps1 status [email]
  .\terabox-account.ps1 status-all                    # per profile: active, cookie age, quota used/total
  .\terabox-account.ps1 quota [email]
  .\terabox-account.ps1 run [email] <GET|POST> </api/path> [body-form-string]
  .\terabox-account.ps1 path [email]
  .\terabox-account.ps1 env [email]
  .\terabox-account.ps1 logout [email]

Examples:
  .\terabox-account.ps1 import user@example.com -CookieFile $env:TEMP\terabox-cookie2.txt
  .\terabox-account.ps1 run user@example.com GET /api/list "dir=/&num=100"
  .\terabox-account.ps1 status-all

Cookie format required: the raw browser Cookie header value for any *.terabox.com
request. It MUST contain ndus= (session) — browserid/lang recommended. Get it from
DevTools > Application > Cookies after signing in, or via `login` after logging in
through agent-browser.
'@ | Write-Host
}

function Normalize-Email {
    param([string]$Email)
    if ([string]::IsNullOrWhiteSpace($Email)) { throw 'Email is required. TeraBox profiles are keyed by account email.' }
    $normalized = $Email.Trim().ToLowerInvariant()
    if ($normalized -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') { throw "Invalid email: $Email" }
    return $normalized
}

function Test-LooksLikeEmail { param([AllowNull()][string]$Value) return (-not [string]::IsNullOrWhiteSpace($Value)) -and ($Value -match '^[^\s@]+@[^\s@]+\.[^\s@]+$') }

function Get-ProfilePath { param([string]$Email) Join-Path $accountRoot (Normalize-Email -Email $Email) }
function Get-CookiePath { param([string]$ProfilePath) Join-Path $ProfilePath 'cookie.txt' }

function Get-ActiveEmail {
    if (-not (Test-Path -LiteralPath $currentFile)) { return $null }
    try { return Normalize-Email -Email ([string]((Get-Content -LiteralPath $currentFile -Raw | ConvertFrom-Json).email)) } catch { return $null }
}

function Get-EmailOrActive {
    param([AllowNull()][string]$Email)
    if (-not [string]::IsNullOrWhiteSpace($Email)) { return Normalize-Email -Email $Email }
    $active = Get-ActiveEmail
    if (-not $active) { throw 'No email given and no active TeraBox profile. Run .\terabox-account.ps1 use <email>.' }
    return $active
}

function Set-ActiveEmail {
    param([string]$Email)
    New-Item -ItemType Directory -Force -Path $accountRoot | Out-Null
    [ordered]@{ tool = 'terabox'; email = (Normalize-Email -Email $Email); updatedAt = (Get-Date).ToString('o') } |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $currentFile -Encoding UTF8
}

function Write-ProfileMetadata {
    param([string]$Email, [string]$ProfilePath, [AllowNull()]$Quota)
    $meta = [ordered]@{
        tool      = 'terabox'
        email     = (Normalize-Email -Email $Email)
        configDir = $ProfilePath
        authType  = 'web-session-cookie'
        cookiePath = (Get-CookiePath -ProfilePath $ProfilePath)
        quota     = if ($Quota) { [ordered]@{ totalBytes = [long]$Quota.total; usedBytes = [long]$Quota.used; plan = [string]$Quota.extra.init_quota_type } } else { $null }
        updatedAt = (Get-Date).ToString('o')
    }
    $meta | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $ProfilePath 'profile.json') -Encoding UTF8
}

function Read-ProfileCookie {
    param([string]$Email)
    $path = Get-CookiePath -ProfilePath (Get-ProfilePath -Email $Email)
    if (-not (Test-Path -LiteralPath $path)) { throw "No TeraBox cookie saved for $Email. Run import or login first." }
    $cookie = (Get-Content -LiteralPath $path -Raw).Trim()
    if ($cookie -notmatch 'ndus=') { throw "Stored cookie for $Email has no ndus= session cookie — it cannot authenticate. Re-capture." }
    return $cookie
}

function Invoke-TeraboxApi {
    param(
        [string]$Email,
        [ValidateSet('GET', 'POST')][string]$Method = 'GET',
        [string]$Path,
        [AllowNull()][string]$Params = '',
        [AllowNull()][string]$Body = '',
        [AllowNull()][string]$CookieOverride = $null
    )
    $cookie = if ($CookieOverride) { $CookieOverride } else { Read-ProfileCookie -Email $Email }
    if ($CookieOverride -and $cookie -notmatch 'ndus=') { throw 'Supplied cookie has no ndus= session value' }
    $base = 'https://dm.terabox.com'
    for ($hop = 0; $hop -lt 4; $hop++) {
        $headers = @{
            Cookie           = $cookie
            Accept           = 'application/json, text/plain, */*'
            Referer          = "$base/"
            'User-Agent'     = $userAgent
            'X-Requested-With' = 'XMLHttpRequest'
        }
        $homeResp = Invoke-WebRequest -Uri "$base/" -Headers $headers -UseBasicParsing -TimeoutSec 30
        $m = [regex]::Match($homeResp.Content, 'function%20fn%28a%29%7Bwindow.jsToken%20%3D%20a%7D%3Bfn%28%22([^%"]+)%22%29')
        if (-not $m.Success) { throw "jsToken not found on $base/ homepage" }
        $qs = "app_id=$appId&web=1&channel=dubox&clienttype=0&version=4&jsToken=$($m.Groups[1].Value)"
        if ($Params) { $qs = "$Params&$qs" }
        $uri = "$base$Path`?$qs"
        try {
            $r = if ($Method -eq 'GET') {
                Invoke-WebRequest -Uri $uri -Headers $headers -UseBasicParsing -TimeoutSec 60
            } else {
                Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -Body $Body -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing -TimeoutSec 60
            }
        } catch {
            throw "TeraBox API $Method $Path failed: $($_.Exception.Message)"
        }
        $json = $r.Content | ConvertFrom-Json
        if ($json.errno -eq -6) {
            $prefix = $r.Headers['Url-Domain-Prefix']
            if ($prefix) { $base = "https://$prefix.terabox.com"; continue }
            throw 'TeraBox errno -6 with no Url-Domain-Prefix redirect header'
        }
        if ($json.errno -ne 0) { throw "TeraBox errno $($json.errno) on $Method $Path : $($r.Content.Substring(0, [Math]::Min(200, $r.Content.Length)))" }
        return $json
    }
    throw 'TeraBox domain redirect loop (>4 hops)'
}

function Get-TeraboxQuota {
    param([string]$Email, [AllowNull()][string]$CookieOverride = $null)
    Invoke-TeraboxApi -Email $Email -Method 'GET' -Path '/api/quota' -Params 'disk_type=0' -CookieOverride $CookieOverride
}

function Get-TeraboxJsToken {
    param([string]$Cookie, [string]$Base)
    $headers = @{ Cookie = $Cookie; Accept = 'text/html'; 'User-Agent' = $userAgent }
    $r = Invoke-WebRequest -Uri "$Base/" -Headers $headers -UseBasicParsing -TimeoutSec 30
    $m = [regex]::Match($r.Content, 'function%20fn%28a%29%7Bwindow.jsToken%20%3D%20a%7D%3Bfn%28%22([^%"]+)%22%29')
    if (-not $m.Success) { throw "jsToken not found on $Base/" }
    $m.Groups[1].Value
}

function Upload-TeraboxFile {
    param([string]$Email, [string]$LocalPath, [string]$RemoteDir = '/')
    $cookie = Read-ProfileCookie -Email $Email
    $item = Get-Item -LiteralPath $LocalPath
    if (-not $item) { throw "no such file: $LocalPath" }
    if ($item.Length -gt 4294967296) { throw "file >4GB: free-tier web cap (VIP 20GB). refusing: $($item.Name)" }
    $api = 'https://dm.terabox.com'
    $hdr = @{ Cookie = $cookie; Accept = 'application/json, text/plain, */*'; Referer = "$api/"; 'User-Agent' = $userAgent; 'X-Requested-With' = 'XMLHttpRequest' }
    $js = Get-TeraboxJsToken -Cookie $cookie -Base 'https://www.terabox.com'
    function New-TeraBlockMd5s([System.IO.FileInfo]$fi, [int]$chunkSize) {
        $fs = [IO.File]::OpenRead($fi.FullName)
        try {
            $md5 = [Security.Cryptography.MD5]::Create()
            $buf = New-Object byte[] $chunkSize
            $blocks = @()
            while ($fs.Position -lt $fi.Length) {
                $n = $fs.Read($buf, 0, $chunkSize)
                $blocks += , ([BitConverter]::ToString($md5.ComputeHash($buf, 0, $n)) -replace '-', '' ).ToLower()
            }
            return $blocks
        } finally { $fs.Dispose() }
    }
    $chunkSize = 4MB
    $md5s = New-TeraBlockMd5s -fi $item -chunkSize $chunkSize
    $blockJson = ($md5s | ConvertTo-Json -Compress)
    if ($md5s.Count -eq 1) { $blockJson = '["' + $md5s[0] + '"]' }
    $remoteDir = $remoteDir.TrimEnd('/')
    $cloudPath = "$remoteDir/$($item.Name)"
    function Invoke-TeraApiPost([string]$Path, [string]$Query, [string]$Form, [AllowNull()][string]$Token) {
        if (-not $Token) { $Token = $js }
        $r = Invoke-WebRequest -Uri "$api$Path`?app_id=$appId&web=1&channel=dubox&clienttype=0&jsToken=$Token$Query" -Method Post -Headers ($hdr + @{ 'Content-Type' = 'application/x-www-form-urlencoded' }) -Body $Form -UseBasicParsing -TimeoutSec 60
        $j = $r.Content | ConvertFrom-Json
        if ($j.errno -eq 4000023) {
            $Token = Get-TeraboxJsToken -Cookie $cookie -Base 'https://www.terabox.com'
            $r = Invoke-WebRequest -Uri "$api$Path`?app_id=$appId&web=1&channel=dubox&clienttype=0&jsToken=$Token$Query" -Method Post -Headers ($hdr + @{ 'Content-Type' = 'application/x-www-form-urlencoded' }) -Body $Form -UseBasicParsing -TimeoutSec 60
            $j = $r.Content | ConvertFrom-Json
        }
        return @{ Json = $j; Token = $Token }
    }
    $mtime = [DateTimeOffset]::FromUnixTimeSeconds([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()).ToUnixTimeSeconds()
    $pre = Invoke-TeraApiPost -Path '/api/precreate' -Query '' -Form "path=$([Uri]::EscapeDataString($cloudPath))&autoinit=1&target_path=$([Uri]::EscapeDataString($remoteDir))&block_list=$([Uri]::EscapeDataString($blockJson))&local_mtime=$mtime&file_limit_switch_v34=true"
    if ($pre.Json.errno -ne 0) { throw "precreate failed (errno $($pre.Json.errno)): $($pre.Json.errmsg)" }
    if ($pre.Json.return_type -eq 2) {
        Write-Host 'rapid upload (return_type=2): content already on server, skipping chunk transfer'
        $cr = Invoke-TeraApiPost -Path '/api/create' -Query '&isdir=0&rtype=1' -Form "path=$([Uri]::EscapeDataString($cloudPath))&size=$($item.Length)&uploadid=$($pre.Json.uploadid)&target_path=$([Uri]::EscapeDataString($remoteDir))&block_list=$([Uri]::EscapeDataString($blockJson))&local_mtime=$mtime" -Token $pre.Token
        if ($cr.Json.errno -ne 0) { throw "create failed after rapid-upload (errno $($cr.Json.errno)): $($cr.Json.errmsg)" }
        return [pscustomobject]@{ Email = $Email; CloudPath = $cloudPath; SizeBytes = $item.Length; FsId = $cr.Json.fs_id; Rapid = $true }
    }
    $loc = (Invoke-WebRequest -Uri 'https://dm-data.terabox.com/rest/2.0/pcs/file?method=locateupload' -Headers $hdr -UseBasicParsing -TimeoutSec 30).Content | ConvertFrom-Json
    if (-not $loc.host) { throw "locateupload returned no host: $($loc | ConvertTo-Json -Compress)" }
    Write-Host "upload host: $($loc.host)"
    $uploadid = $pre.Json.uploadid
    $curl = (Get-Command curl.exe).Source
    $fs = [IO.File]::OpenRead($item.FullName)
    try {
        $buf = New-Object byte[] $chunkSize
        $seq = 0; $swUp = [Diagnostics.Stopwatch]::StartNew(); $realMd5s = @()
        while ($fs.Position -lt $item.Length) {
            $n = $fs.Read($buf, 0, $chunkSize)
            $tmp = Join-Path $env:TEMP "tbchunk-$([Guid]::NewGuid().ToString('N')).bin"
            [IO.File]::WriteAllBytes($tmp, $buf[0..($n - 1)])
            $qp = "method=upload&path=$([Uri]::EscapeDataString($cloudPath))&uploadid=$([Uri]::EscapeDataString($uploadid))&partseq=$seq&app_id=$appId&web=1&channel=dubox&clienttype=0"
            $out = & $curl -sS --connect-timeout 30 --max-time 300 -X POST -H "Cookie: $cookie" -H "User-Agent: $userAgent" -F "file=@$tmp;filename=$($item.Name)" "https://$($loc.host)/rest/2.0/pcs/superfile2?$qp" 2>&1
            Remove-Item $tmp -Force -EA SilentlyContinue
            $uj = (($out | ForEach-Object { [string]$_ }) -join '') | ConvertFrom-Json
            if (-not $uj.md5) { throw "chunk $seq upload failed: $(($out | Out-String).Trim())" }
            if ($uj.md5 -ne $md5s[$seq]) { throw "chunk $seq md5 mismatch: got $($uj.md5) expected $($md5s[$seq])" }
            $realMd5s += $uj.md5
            $seq++
            if ($seq % 25 -eq 0 -or $fs.Position -ge $item.Length) { Write-Host ("  chunk {0}/{1} [{2:hh\:mm\:ss}]" -f $seq, $md5s.Count, $swUp.Elapsed) }
        }
    } finally { $fs.Dispose() }
    $cr = Invoke-TeraApiPost -Path '/api/create' -Query '&isdir=0&rtype=1' -Form "path=$([Uri]::EscapeDataString($cloudPath))&size=$($item.Length)&uploadid=$($uploadid)&target_path=$([Uri]::EscapeDataString($remoteDir))&block_list=$([Uri]::EscapeDataString(($realMd5s | ConvertTo-Json -Compress)))&local_mtime=$mtime" -Token $pre.Token
    if ($cr.Json.errno -ne 0) { throw "create failed (errno $($cr.Json.errno)): $($cr.Json.errmsg)" }
    [pscustomobject]@{ Email = $Email; CloudPath = $cloudPath; SizeBytes = $item.Length; FsId = $cr.Json.fs_id; Rapid = $false }
}
function Save-CookieProfile {
    param([string]$Email, [string]$Cookie)
    $normalized = Normalize-Email -Email $Email
    if ($Cookie -notmatch 'ndus=') { throw "Provided cookie has no ndus= session value — refusing to save a profile that cannot authenticate." }
    try {
        $quota = Get-TeraboxQuota -Email $normalized -CookieOverride $Cookie.Trim()
    } catch {
        throw "Cookie rejected by TeraBox quota check for $normalized : $($_.Exception.Message)"
    }
    $profilePath = Get-ProfilePath -Email $normalized
    New-Item -ItemType Directory -Force -Path $profilePath | Out-Null
    $cookiePath = Get-CookiePath -ProfilePath $profilePath
    Set-Content -LiteralPath $cookiePath -Value $Cookie.Trim() -Encoding ASCII -NoNewline
    Write-ProfileMetadata -Email $normalized -ProfilePath $profilePath -Quota $quota
    Set-ActiveEmail -Email $normalized
    $usedGB = [math]::Round($quota.used / 1GB, 2); $totalGB = [math]::Round($quota.total / 1GB, 2)
    Write-Host "TeraBox profile saved + verified: $normalized ($usedGB / $totalGB GB used, plan=$($quota.extra.init_quota_type)) — now active"
}

$action = if ($args.Count -gt 0) { [string]$args[0] } else { 'help' }
$rest = @()
if ($args.Count -gt 1) { $rest = @($args[1..($args.Count - 1)]) }

switch ($action.ToLowerInvariant()) {
    'help' { Show-Usage }

    'import' {
        if ($rest.Count -lt 1 -or -not (Test-LooksLikeEmail $rest[0])) { throw 'Usage: import <email> [-Cookie "..."] | [-CookieFile <path>]' }
        $email = $rest[0]
        $cookie = $null
        for ($i = 1; $i -lt $rest.Count; $i++) {
            switch ($rest[$i]) {
                '-Cookie' { $cookie = $rest[++$i] }
                '-CookieFile' { $cookie = (Get-Content -LiteralPath $rest[++$i] -Raw) }
                default { throw "Unknown option: $($rest[$i])" }
            }
        }
        if ([string]::IsNullOrWhiteSpace($cookie)) {
            Write-Host 'Paste the raw Cookie header from a *.terabox.com request (must contain ndus=). Hidden.'
            $ss = Read-Host -AsSecureString 'TeraBox cookie'
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
            try { $cookie = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        }
        Save-CookieProfile -Email $email -Cookie $cookie
    }

    'login' {
        if ($rest.Count -lt 1 -or -not (Test-LooksLikeEmail $rest[0])) { throw 'Usage: login <email>' }
        $email = Normalize-Email -Email $rest[0]
        $ab = Get-Command agent-browser -ErrorAction SilentlyContinue
        if (-not $ab) { throw 'agent-browser not on PATH. Sign in at https://www.terabox.com in a browser, then use: import <email> -Cookie "..." ' }
        Write-Host 'Opening TeraBox in agent-browser — complete the login in that window (it polls for the ndus cookie for 5 min).'
        Start-Process pwsh -ArgumentList '-NoExit', '-Command', "& '$PSScriptRoot\agent-browser-account.ps1' run $email -Url https://www.terabox.com" 
        $deadline = (Get-Date).AddMinutes(5)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 10
            $tmp = Join-Path $env:TEMP "terabox-cookies-$([Guid]::NewGuid().ToString('N')).json"
            try { & $ab.Source cookies get --json 2>$null | Set-Content -LiteralPath $tmp -Encoding UTF8 } catch {}
            $json = Get-Content $tmp -Raw -EA SilentlyContinue | ConvertFrom-Json
            Remove-Item $tmp -EA SilentlyContinue
            $ndus = @($json.cookies | Where-Object { $_.name -eq 'ndus' })
            if ($ndus.Count -gt 0) {
                $tb = @($json.cookies | Where-Object { $_.domain -like '*terabox.com' })
                $cookie = (($tb | ForEach-Object { "$($_.name)=$($_.value)" }) -join '; ')
                Save-CookieProfile -Email $email -Cookie $cookie
                exit 0
            }
            Write-Host '  waiting for login (no ndus yet)...'
        }
        throw 'Timed out after 5 min waiting for a logged-in TeraBox session.'
    }

    'use' {
        if ($rest.Count -lt 1) { throw 'Usage: use <email>' }
        $email = Normalize-Email -Email $rest[0]
        if (-not (Test-Path -LiteralPath (Get-ProfilePath -Email $email))) { throw "TeraBox profile does not exist: $email" }
        Set-ActiveEmail -Email $email
        Write-Host "Active TeraBox profile: $email"
    }

    'current' {
        $active = Get-ActiveEmail
        if ($active) { Write-Host $active } else { Write-Host 'No active TeraBox profile set.' }
    }

    'list' {
        if (-not (Test-Path -LiteralPath $accountRoot)) { Write-Host 'No TeraBox profiles found.'; return }
        $profiles = @(Get-ChildItem -LiteralPath $accountRoot -Directory | Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } | Sort-Object Name)
        if ($profiles.Count -eq 0) { Write-Host 'No TeraBox profiles found.'; return }
        $active = Get-ActiveEmail
        foreach ($p in $profiles) { $marker = if ($p.Name -eq $active) { '*' } else { ' ' }; Write-Host "$marker $($p.Name)" }
    }

    { $_ -in @('status', 'quota') } {
        $email = Get-EmailOrActive -Email $(if ($rest.Count -gt 0 -and (Test-LooksLikeEmail $rest[0])) { $rest[0] } else { $null })
        $profilePath = Get-ProfilePath -Email $email
        $cookiePath = Get-CookiePath -ProfilePath $profilePath
        Write-Host "profile : $email"
        if (-not (Test-Path -LiteralPath $profilePath)) { Write-Host 'state  : missing-profile'; return }
        Write-Host "config : $profilePath"
        if (-not (Test-Path -LiteralPath $cookiePath)) { Write-Host 'state  : missing-cookie'; return }
        Write-Host "cookie : present, saved $((Get-Item $cookiePath).LastWriteTime.ToString('yyyy-MM-dd HH:mm'))"
        Write-Host ("active : {0}" -f ((Get-ActiveEmail) -eq $email))
        try {
            $q = Get-TeraboxQuota -Email $email
            Write-Host ("quota  : {0:N2} GB used / {1:N0} GB total ({2})" -f ($q.used / 1GB), ($q.total / 1GB), $q.extra.init_quota_type)
        } catch {
            Write-Host "quota  : FAILED — $($_.Exception.Message)"
        }
    }

    'status-all' {
        if (-not (Test-Path -LiteralPath $accountRoot)) { Write-Host 'No TeraBox profiles found.'; return }
        $profiles = @(Get-ChildItem -LiteralPath $accountRoot -Directory | Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } | Sort-Object Name)
        if ($profiles.Count -eq 0) { Write-Host 'No TeraBox profiles found.'; return }
        $active = Get-ActiveEmail
        $rows = foreach ($p in $profiles) {
            $cookiePath = Get-CookiePath -ProfilePath $p.FullName
            $row = [ordered]@{ Email = $p.Name; Active = ($p.Name -eq $active); Cookie = if (Test-Path $cookiePath) { (Get-Item $cookiePath).LastWriteTime.ToString('MM-dd HH:mm') } else { 'missing' }; UsedGB = ''; TotalGB = ''; Plan = ''; State = '' }
            if (Test-Path $cookiePath) {
                try {
                    $q = Get-TeraboxQuota -Email $p.Name
                    $row.UsedGB = [math]::Round($q.used / 1GB, 2); $row.TotalGB = [math]::Round($q.total / 1GB, 0)
                    $row.Plan = [string]$q.extra.init_quota_type; $row.State = 'ok'
                } catch { $row.State = 'cookie-invalid-or-network' }
            } else { $row.State = 'missing-cookie' }
            [pscustomobject]$row
        }
        $rows | Format-Table -AutoSize
    }

    'mkdir' {
        if ($rest.Count -lt 2) { throw 'Usage: mkdir <email> </remote/dir>' }
        $email = Normalize-Email -Email $rest[0]
        $dir = $rest[1]
        $cookie = Read-ProfileCookie -Email $email
        $js = Get-TeraboxJsToken -Cookie $cookie -Base 'https://www.terabox.com'
        $r = Invoke-WebRequest -Uri "https://dm.terabox.com/api/create?path=$([Uri]::EscapeDataString($dir))&size=0&isdir=1&name=$([Uri]::EscapeDataString((Split-Path $dir -Leaf)))&app_id=$appId&web=1&channel=dubox&clienttype=0&version=4&jsToken=$js" -Method Post -Headers @{ Cookie = $cookie; 'User-Agent' = $userAgent; Referer = 'https://dm.terabox.com/'; Origin = 'https://www.terabox.com'; 'Content-Type' = 'application/x-www-form-urlencoded' } -Body '' -UseBasicParsing -TimeoutSec 40 | ConvertFrom-Json
        if ($r.errno -ne 0) { throw "mkdir failed: $($r | ConvertTo-Json -Compress)" }
        Write-Host "dir: $($r.path)"
    }

    'upload' {
        if ($rest.Count -lt 2) { throw 'Usage: upload <email> <local-file> [-RemoteDir /dir]' }
        $email = Normalize-Email -Email $rest[0]
        $file = $rest[1]
        $rd = '/'
        for ($i = 2; $i -lt $rest.Count; $i++) { if ($rest[$i] -eq '-RemoteDir') { $rd = $rest[++$i] } }
        $r = Upload-TeraboxFile -Email $email -LocalPath $file -RemoteDir $rd
        Write-Host "uploaded: $($r.CloudPath)  ($([math]::Round($r.SizeBytes/1MB,2)) MB, fs_id=$($r.FsId))"
    }

    'delete' {
        if ($rest.Count -lt 2) { throw 'Usage: delete <email> </remote/path> [more paths...]' }
        $email = Normalize-Email -Email $rest[0]
        $paths = @($rest[1..($rest.Count - 1)])
        $list = ($paths | ForEach-Object { '"' + $_ + '"' }) -join ','
        $null = Invoke-TeraboxApi -Email $email -Method 'POST' -Path '/api/filemanager' -Params 'onnest=fail&opera=delete' -Body "async=0&filelist=$([Uri]::EscapeDataString("[$list]"))&ondup=newcopy"
        Write-Host "deleted: $($paths -join ', ')"
    }

    'run' {
        if ($rest.Count -lt 2) { throw 'Usage: run [email] <GET|POST> </api/path> [params-or-body]' }
        $idx = 0
        $email = if (Test-LooksLikeEmail $rest[0]) { $idx = 1; Normalize-Email -Email $rest[0] } else { Get-EmailOrActive -Email $null }
        $method = $rest[$idx].ToUpperInvariant()
        $path = $rest[$idx + 1]
        $extra = if ($rest.Count -gt ($idx + 2)) { $rest[$idx + 2] } else { $null }
        $params = if ($method -eq 'GET') { $extra } else { '' }
        $body = if ($method -eq 'POST') { $extra } else { '' }
        Invoke-TeraboxApi -Email $email -Method $method -Path $path -Params $params -Body $body | ConvertTo-Json -Depth 12
    }

    'path' {
        $email = Get-EmailOrActive -Email $(if ($rest.Count -gt 0) { $rest[0] } else { $null })
        Write-Host (Get-ProfilePath -Email $email)
    }

    'env' {
        $email = Get-EmailOrActive -Email $(if ($rest.Count -gt 0) { $rest[0] } else { $null })
        $profilePath = Get-ProfilePath -Email $email
        $cookiePath = Get-CookiePath -ProfilePath $profilePath
        $state = if (Test-Path -LiteralPath $cookiePath) { '<profile cookie>' } else { '<missing cookie>' }
        Write-Host "`$env:TERABOX_EMAIL = $email"
        Write-Host "`$env:TERABOX_COOKIE_FILE = $cookiePath $state"
    }

    'logout' {
        $email = Get-EmailOrActive -Email $(if ($rest.Count -gt 0) { $rest[0] } else { $null })
        $profilePath = Get-ProfilePath -Email $email
        if (-not (Test-Path -LiteralPath $profilePath)) { Write-Host "TeraBox profile does not exist: $email"; return }
        $backup = "$profilePath.logged-out-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Move-Item -LiteralPath $profilePath -Destination $backup
        Write-Host "TeraBox profile moved to: $backup"
        if ((Get-ActiveEmail) -eq $email -and (Test-Path -LiteralPath $currentFile)) { Remove-Item -LiteralPath $currentFile; Write-Host 'Active TeraBox profile cleared.' }
    }

    default { Show-Usage; throw "Unknown action: $action" }
}
