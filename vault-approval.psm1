<#
.SYNOPSIS
    Cross-platform 1-tap mobile biometric approval for Bitwarden vault restore.
.DESCRIPTION
    Generates an ephemeral RSA-2048 keypair, dispatches an urgent push notification
    to ntfy, pops up a full-screen approval prompt via ADB if a phone is attached,
    and listens on the single-use relay topic for client-side encrypted master password.
#>

function Get-CallerIdentity {
    param(
        [string]$Agent,
        [string]$Model
    )

    if (-not $Agent) {
        $Agent = $env:MAINFRAME_AGENT_NAME
        if (-not $Agent) { $Agent = $env:AGENT_NAME }
        if (-not $Agent) { $Agent = $env:AI_AGENT }
        if (-not $Agent) { $Agent = $env:HARNESS_NAME }
    }
    if (-not $Model) {
        $Model = $env:MAINFRAME_MODEL_NAME
        if (-not $Model) { $Model = $env:MODEL_NAME }
        if (-not $Model) { $Model = $env:AI_MODEL }
    }

    if (-not $Agent) {
        if ($env:ANTIGRAVITY_AGENT -or $env:ANTIGRAVITY_CONVERSATION_ID) {
            $Agent = 'antigravity'
        } elseif ($env:OPENCODE -or $env:OPENCODE_SESSION -or $env:OPENCODE_DISABLE_CHANNEL_DB) {
            $Agent = 'opencode'
        } elseif ($env:CLAUDE_CODE -or $env:CLAUDE_PROJECT_DIR) {
            $Agent = 'claude-code'
        } elseif ($env:CODEX -or $env:CODEX_MODEL) {
            $Agent = 'codex'
        } elseif ($env:AIDER_MODEL) {
            $Agent = 'aider'
        } else {
            # Check process ancestry
            try {
                $p = (Get-Process -Id $PID -ErrorAction SilentlyContinue).Parent
                while ($p) {
                    $name = $p.ProcessName.ToLower()
                    if ($name -match 'antigravity') { $Agent = 'antigravity'; break }
                    if ($name -match 'opencode') { $Agent = 'opencode'; break }
                    if ($name -match 'claude') { $Agent = 'claude-code'; break }
                    if ($name -match 'codex') { $Agent = 'codex'; break }
                    if ($name -match 'cursor') { $Agent = 'cursor'; break }
                    if ($name -match 'windsurf') { $Agent = 'windsurf'; break }
                    $p = $p.Parent
                }
            } catch {}
        }
    }

    if (-not $Agent) {
        $Agent = 'terminal'
    }

    # Resolve Model via Ground-Truth Thread Inspection or Environment
    if (-not $Model) {
        $Model = $env:MAINFRAME_MODEL_NAME
        if (-not $Model) { $Model = $env:MODEL_NAME }
        if (-not $Model) { $Model = $env:AI_MODEL }
    }

    if (-not $Model) {
        if ($Agent -eq 'antigravity' -and $env:ANTIGRAVITY_CONVERSATION_ID) {
            # Ground-truth: inspect Antigravity conversation transcript on disk
            $appData = if ($env:ANTIGRAVITY_APP_DATA_DIR) { $env:ANTIGRAVITY_APP_DATA_DIR } else { (Join-Path $HOME '.gemini\antigravity') }
            $transcript = Join-Path $appData "brain\$($env:ANTIGRAVITY_CONVERSATION_ID)\.system_generated\logs\transcript.jsonl"
            if (Test-Path -LiteralPath $transcript) {
                # Check recent lines first for any mid-thread model switches
                $recent = Get-Content -LiteralPath $transcript -Tail 100 -ErrorAction SilentlyContinue
                if ($recent) {
                    $matches = @($recent | Select-String -Pattern "Model Selection.*?from\s+.*?\s+to\s+(.+?)\.\s+No need")
                    if ($matches.Count -gt 0) {
                        $Model = $matches[-1].Matches[0].Groups[1].Value.Trim()
                    }
                }
                # Check initial lines (Step 0) if no recent change
                if (-not $Model) {
                    $head = Get-Content -LiteralPath $transcript -TotalCount 50 -ErrorAction SilentlyContinue
                    if ($head) {
                        $matches = @($head | Select-String -Pattern "Model Selection.*?from\s+.*?\s+to\s+(.+?)\.\s+No need")
                        if ($matches.Count -gt 0) {
                            $Model = $matches[-1].Matches[0].Groups[1].Value.Trim()
                        }
                    }
                }
            }
            if (-not $Model -and $env:ANTIGRAVITY_MODEL) {
                $Model = $env:ANTIGRAVITY_MODEL
            }
        } elseif ($Agent -eq 'opencode') {
            if ($env:OPENCODE_MODEL) { $Model = $env:OPENCODE_MODEL }
        } elseif ($Agent -eq 'claude-code') {
            if ($env:ANTHROPIC_MODEL) { $Model = $env:ANTHROPIC_MODEL }
        } elseif ($Agent -eq 'codex') {
            if ($env:CODEX_MODEL) { $Model = $env:CODEX_MODEL }
        } elseif ($Agent -eq 'aider') {
            if ($env:AIDER_MODEL) { $Model = $env:AIDER_MODEL }
        }
    }

    return [PSCustomObject]@{
        Agent = $Agent
        Model = $Model
    }
}

function Get-VaultApprovalUrl {
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.RSA]$Rsa,
        [string]$ToolRepo = 'FahadBinHussain/mainframe',
        [string]$PromptContext = 'vault access',
        [string]$HostName = $env:COMPUTERNAME,
        [string]$Agent = $null,
        [string]$Model = $null
    )

    $identity = Get-CallerIdentity -Agent $Agent -Model $Model
    $resolvedAgent = $identity.Agent
    $resolvedModel = $identity.Model

    $derBytes = $Rsa.ExportSubjectPublicKeyInfo()
    $k = [Convert]::ToBase64String($derBytes).Replace('+', '-').Replace('/', '_').TrimEnd('=')

    $sidBytes = New-Object byte[] 12
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($sidBytes)
    $sidHex = -join ($sidBytes | ForEach-Object { $_.ToString('x2') })
    $sid = "mf-vault-$sidHex"

    # Cryptographic random 2-digit verification code for Number Matching
    $codeBytes = New-Object byte[] 1
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($codeBytes)
    $code = (10 + ($codeBytes[0] % 90)).ToString()

    $escapedCtx = [Uri]::EscapeDataString($PromptContext)
    $escapedHost = [Uri]::EscapeDataString($HostName)
    $escapedAgent = [Uri]::EscapeDataString($resolvedAgent)
    $modelParam = if ($resolvedModel) { "&model=" + [Uri]::EscapeDataString($resolvedModel) } else { "" }

    $owner = ($ToolRepo -split '/')[0]
    $url = "https://$owner.github.io/mainframe/docs/vault-tab.html#k=$k&sid=$sid&code=$code&host=$escapedHost&ctx=$escapedCtx&agent=$escapedAgent$modelParam"

    return [PSCustomObject]@{
        Url   = $url
        Sid   = $sid
        Code  = $code
        Agent = $resolvedAgent
        Model = $resolvedModel
    }
}

function Send-VaultApprovalNotification {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Topic,
        [Parameter(Mandatory = $true)]
        [string]$Url,
        [string]$HostName = $env:COMPUTERNAME,
        [string]$Code = $null,
        [string]$PromptContext = "vault access",
        [string]$Agent = $null,
        [string]$Model = $null
    )

    try {
        $callerTag = if ($Agent) { "$HostName - $Agent" } else { $HostName }
        $title = if ($Code) { "Vault Unlock: Code [$Code] ($callerTag)" } else { "Vault Unlock ($callerTag)" }
        $actionTitle = if ($Code) { "Unlock [$Code]" } else { "Unlock Vault" }
        $headers = @{
            'Title'   = $title
            'Priority'= 'urgent'
            'Tags'    = 'lock,key'
            'Click'   = $Url
            'Actions' = "view, $actionTitle, $Url, clear=true"
        }
        $bodyParts = @("Request from $HostName")
        if ($Agent) { $bodyParts += "Agent: $Agent" }
        if ($Model) { $bodyParts += "Model: $Model" }
        $bodyParts += "Action: $PromptContext"
        $bodyParts += "Verification Code: [$Code]"
        $bodyParts += "Tap to verify matching number on terminal and approve."
        $body = $bodyParts -join "`n"
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
        [string]$PromptContext = "vault access",
        [int]$TimeoutSeconds = 300,
        [string]$Agent = $null,
        [string]$Model = $null,
        [string]$HostName = $env:COMPUTERNAME
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

    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    try {
        $session = Get-VaultApprovalUrl -Rsa $rsa -PromptContext $PromptContext -HostName $HostName -Agent $Agent -Model $Model
        $url = $session.Url
        $sid = $session.Sid
        $code = $session.Code
        $resolvedAgent = $session.Agent
        $resolvedModel = $session.Model

        $callerDisplay = if ($resolvedModel) { "$resolvedAgent ($resolvedModel) @ $HostName" } else { "$resolvedAgent @ $HostName" }

        Write-Host "`n==> 1-tap mobile approval for $PromptContext" -ForegroundColor Cyan
        Write-Host "==================================================" -ForegroundColor Green
        Write-Host "  VERIFICATION CODE: [ $code ]" -ForegroundColor Green
        Write-Host "  Caller: $callerDisplay" -ForegroundColor White
        Write-Host "  Context: $PromptContext" -ForegroundColor Gray
        Write-Host "  (Ensure the number on your phone matches $code)" -ForegroundColor Yellow
        Write-Host "==================================================" -ForegroundColor Green
        Write-Host "approval url: $url" -ForegroundColor Gray

        if ($NtfyTopic) {
            $sent = Send-VaultApprovalNotification -Topic $NtfyTopic -Url $url -Code $code -PromptContext $PromptContext -HostName $HostName -Agent $resolvedAgent -Model $resolvedModel
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
    Get-CallerIdentity, `
    Get-VaultApprovalUrl, `
    Send-VaultApprovalNotification, `
    Open-VaultApprovalOnPhone, `
    Wait-VaultApprovalCiphertext, `
    Decrypt-VaultApprovalCiphertext, `
    Get-VaultMasterPassword
