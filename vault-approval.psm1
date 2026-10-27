<#
.SYNOPSIS
    Cross-platform 1-tap mobile biometric approval for Bitwarden vault restore.
.DESCRIPTION
    Generates an ephemeral RSA-2048 keypair, dispatches an urgent push notification
    to ntfy, pops up a full-screen approval prompt via ADB if a phone is attached,
    and listens on the single-use relay topic for client-side encrypted master password.
#>

function Get-VaultApprovalUrl {
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.RSA]$Rsa,
        [string]$ToolRepo = 'FahadBinHussain/mainframe'
    )

    $derBytes = $Rsa.ExportSubjectPublicKeyInfo()
    $k = [Convert]::ToBase64String($derBytes).Replace('+', '-').Replace('/', '_').TrimEnd('=')

    $sidBytes = New-Object byte[] 12
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($sidBytes)
    $sidHex = -join ($sidBytes | ForEach-Object { $_.ToString('x2') })
    $sid = "mf-vault-$sidHex"

    $owner = ($ToolRepo -split '/')[0]
    $url = "https://$owner.github.io/mainframe/docs/vault-tab.html#k=$k&sid=$sid"

    return [PSCustomObject]@{
        Url = $url
        Sid = $sid
    }
}

function Send-VaultApprovalNotification {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Topic,
        [Parameter(Mandatory = $true)]
        [string]$Url,
        [string]$HostName = $env:COMPUTERNAME
    )

    try {
        $headers = @{
            'Title'   = "Mainframe Restore: Vault Unlock ($HostName)"
            'Priority'= 'urgent'
            'Tags'    = 'lock,key'
            'Click'   = $Url
            'Actions' = "view, Unlock Vault, $Url, clear=true"
        }
        $body = "Restore on $HostName requires Bitwarden vault unlock.`nTap to approve with fingerprint."
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $null = Invoke-RestMethod -Uri "https://ntfy.sh/$Topic" -Method Post -Headers $headers -Body $bodyBytes -TimeoutSec 10 -ErrorAction Stop
        return $true
    } catch {
        Write-Warning "ntfy push dispatch to topic '$Topic' failed: $_"
        return $false
    }
}

function Open-VaultApprovalOnPhone {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    $adb = Get-Command adb -ErrorAction SilentlyContinue
    if (-not $adb) { return $false }

    try {
        $devices = & adb devices 2>$null
        if ($devices -match '([A-Za-z0-9_-]+)\s+device\b') {
            Write-Host "phone attached via adb - popping up full-screen prompt on phone..." -ForegroundColor Green
            & adb shell input keyevent KEYCODE_WAKEUP 2>$null
            & adb shell "am start -a android.intent.action.VIEW -d '$Url'" 2>$null
            return $true
        }
    } catch {
        # ignore adb errors
    }
    return $false
}

function Wait-VaultApprovalCiphertext {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Sid,
        [int]$TimeoutSeconds = 300,
        [string]$LocalFileName = 'mainframe-vault-pass.enc'
    )

    $downloadPath = Join-Path $HOME "Downloads\$LocalFileName"
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 2

        # 1. Poll relay topic
        try {
            $resp = Invoke-RestMethod -Uri "https://ntfy.sh/$Sid/raw?poll=1" -Method Get -TimeoutSec 5 -ErrorAction Stop
            if ($resp -and [string]$resp -ne '') {
                return ([string]$resp).Trim()
            }
        } catch {
            # timeout/no message yet
        }

        # 2. Check local file
        if (Test-Path -LiteralPath $downloadPath) {
            try {
                $content = (Get-Content -LiteralPath $downloadPath -Raw).Trim()
                Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
                if (-not [string]::IsNullOrWhiteSpace($content)) {
                    return $content
                }
            } catch {
                # file locked or transient read issue
            }
        }
    }
    return $null
}

function Decrypt-VaultApprovalCiphertext {
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.RSA]$Rsa,
        [Parameter(Mandatory = $true)]
        [string]$Ciphertext
    )

    $cipherBytes = [Convert]::FromBase64String($Ciphertext)
    $plainBytes = $Rsa.Decrypt($cipherBytes, [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
    return [System.Text.Encoding]::UTF8.GetString($plainBytes)
}

function Get-VaultMasterPassword {
    param(
        [string]$NtfyTopic = $null,
        [string]$PromptContext = "vault restore",
        [int]$TimeoutSeconds = 300
    )

    # Resolve ntfy topic
    if (-not $NtfyTopic) {
        $NtfyTopic = $env:MAINFRAME_NTFY_TOPIC
    }
    if (-not $NtfyTopic) {
        $configCandidates = @(
            (Join-Path $PSScriptRoot 'mainframe.config.json'),
            (Join-Path (Get-Location) 'mainframe.config.json'),
            (Join-Path $HOME '.config\mainframe\mainframe.config.json')
        )
        foreach ($cfg in $configCandidates) {
            if (Test-Path -LiteralPath $cfg) {
                try {
                    $json = Get-Content -LiteralPath $cfg -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    if ($json.ntfyTopic) {
                        $NtfyTopic = [string]$json.ntfyTopic
                        break
                    }
                } catch {}
            }
        }
    }
    if (-not $NtfyTopic) {
        $NtfyTopic = 'fahad-vault-restore'
    }

    Write-Host "`n==> 1-tap mobile approval for $PromptContext..." -ForegroundColor Cyan

    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    try {
        $session = Get-VaultApprovalUrl -Rsa $rsa
        $url = $session.Url
        $sid = $session.Sid

        Write-Host "approval url: $url" -ForegroundColor Gray

        if ($NtfyTopic) {
            $sent = Send-VaultApprovalNotification -Topic $NtfyTopic -Url $url
            if ($sent) {
                Write-Host "push notification sent to ntfy topic: $NtfyTopic" -ForegroundColor Green
            }
        }

        $opened = Open-VaultApprovalOnPhone -Url $url

        Write-Host "waiting for 1-tap fingerprint approval on phone (or ~/Downloads/mainframe-vault-pass.enc) ..." -ForegroundColor Yellow
        $ct = Wait-VaultApprovalCiphertext -Sid $sid -TimeoutSeconds $TimeoutSeconds

        if ($ct) {
            $pw = Decrypt-VaultApprovalCiphertext -Rsa $rsa -Ciphertext $ct
            Write-Host "password decrypted successfully via 1-tap biometric approval" -ForegroundColor Green
            return $pw
        } else {
            Write-Warning "phone approval timed out after $TimeoutSeconds seconds."
            return $null
        }
    } finally {
        $rsa.Dispose()
    }
}

Export-ModuleMember -Function `
    Get-VaultApprovalUrl, `
    Send-VaultApprovalNotification, `
    Open-VaultApprovalOnPhone, `
    Wait-VaultApprovalCiphertext, `
    Decrypt-VaultApprovalCiphertext, `
    Get-VaultMasterPassword
