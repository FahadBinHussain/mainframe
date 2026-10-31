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
        } elseif ($env:QODER_CLI -or $env:QODER_PRODUCT_ID -or $env:QODER_SESSION_TYPE) {
            # qoder sets OPENCODE_DISABLE_CHANNEL_DB for compatibility, so it
            # must be tested before the opencode branch or it reads as opencode
            $Agent = 'qoder'
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
                    if ($name -match 'qoder') { $Agent = 'qoder'; break }
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

function Get-VaultConfigValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    # one config file drives both machines: linux_real.py reads the same keys,
    # so a windows box and a linux box can be pointed at the same relay and
    # the same approval page without touching code.
    $configCandidates = @(
        (Join-Path $PSScriptRoot 'mainframe.config.json'),
        (Join-Path (Get-Location) 'mainframe.config.json'),
        (Join-Path $HOME '.config\mainframe\mainframe.config.json')
    )
    foreach ($cfg in $configCandidates) {
        if (Test-Path -LiteralPath $cfg) {
            try {
                $json = Get-Content -LiteralPath $cfg -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                $value = $json.$Key
                if ($value) { return ([string]$value).Trim() }
            } catch {}
        }
    }
    return $null
}

function Get-VaultNtfyTopic {
    param(
        [string]$Topic = $null
    )

    # the approval channel is only private when the topic name is unguessable,
    # so there is deliberately no built-in default: an unconfigured machine
    # fails here instead of broadcasting requests on a public topic.
    if (-not $Topic) { $Topic = $env:MAINFRAME_NTFY_TOPIC }
    if (-not $Topic) {
        $Topic = Get-VaultConfigValue -Key 'ntfyTopic'
    }
    if (-not $Topic) {
        throw "no ntfy topic configured: set `$env:MAINFRAME_NTFY_TOPIC, or ntfyTopic in mainframe.config.json. Use a long random topic name -- anyone who knows it can read approval requests and post fake ones."
    }
    return $Topic
}

function Get-VaultNtfyServer {
    param(
        [string]$Server = $null
    )

    # the relay only has to speak the ntfy http api. a machine whose egress
    # proxy denies ntfy.sh points this at a reachable ntfy-compatible relay;
    # the phone keeps using the same ntfy app and the same topic.
    if (-not $Server) { $Server = $env:MAINFRAME_NTFY_SERVER }
    if (-not $Server) { $Server = Get-VaultConfigValue -Key 'ntfyServer' }
    if (-not $Server) { $Server = 'https://ntfy.sh' }
    return $Server.TrimEnd('/')
}

function Get-VaultPagesBase {
    param(
        [string]$PagesBase = $null,
        [string]$ToolRepo = 'FahadBinHussain/mainframe'
    )

    # the approval card is a static file, so any host that serves it works.
    # a first-party deployment keeps the tap link off a raw github.io path.
    if (-not $PagesBase) { $PagesBase = $env:MAINFRAME_PAGES_BASE }
    if (-not $PagesBase) { $PagesBase = Get-VaultConfigValue -Key 'pagesBase' }
    if (-not $PagesBase) {
        $owner = ($ToolRepo -split '/')[0]
        # lowercased so windows and linux emit the exact same approval url
        $PagesBase = "https://$($owner.ToLower()).github.io/mainframe"
    }
    return $PagesBase.TrimEnd('/')
}

function Get-VaultApprovalUrl {
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.RSA]$Rsa,
        [string]$ToolRepo = 'FahadBinHussain/mainframe',
        [string]$PromptContext = 'vault access',
        [string]$HostName = $env:COMPUTERNAME,
        [string]$Agent = $null,
        [string]$Model = $null,
        # how long the runner will keep waiting. landing this in the link lets
        # the phone page say "stale" instead of offering a tap nobody hears.
        [int]$ExpiresInSeconds = 0,
        [string]$PagesBase = $null,
        [string]$Server = $null
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
    $expParam = if ($ExpiresInSeconds -gt 0) { "&exp=" + [DateTimeOffset]::UtcNow.AddSeconds($ExpiresInSeconds).ToUnixTimeSeconds() } else { "" }

    $owner = ($ToolRepo -split '/')[0]
    $resolvedPages = Get-VaultPagesBase -PagesBase $PagesBase -ToolRepo $ToolRepo
    $resolvedRelay = Get-VaultNtfyServer -Server $Server
    $url = "$resolvedPages/docs/vault-tab.html#k=$k&sid=$sid&code=$code&host=$escapedHost&ctx=$escapedCtx&agent=$escapedAgent$modelParam$expParam"
    if ($resolvedRelay -ne 'https://ntfy.sh') {
        # the card has to post the ciphertext back to the same relay this
        # runner reads. without this the page would hardcode ntfy.sh and a
        # machine behind a relay would never see the approval land.
        $url += "&srv=$([Uri]::EscapeDataString($resolvedRelay))"
    }

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
        [string]$Model = $null,
        [string]$Server = $null
    )

    $resolvedServer = Get-VaultNtfyServer -Server $Server
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
        $null = Invoke-RestMethod -Uri "$resolvedServer/$Topic" -Method Post -Headers $headers -Body $bodyBytes -TimeoutSec 10 -ErrorAction Stop
        return $true
    } catch {
        Write-Warning "ntfy push dispatch to topic '$Topic' failed: $_"
        return $false
    }
}

function Send-VaultRequestExpired {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Sid,
        [string]$HostName = $env:COMPUTERNAME,
        [string]$Code = $null,
        [string]$Server = $null
    )

    $resolvedServer = Get-VaultNtfyServer -Server $Server
    # the runner stopped waiting, so the card must stop offering a tap nobody
    # hears. the marker rides the same single-use topic the card already polls.
    try {
        $body = ConvertTo-Json -Compress -InputObject ([ordered]@{
                mf   = 'expired'
                at   = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                host = $HostName
                code = $Code
            })
        $headers = @{
            'Title'    = 'Vault Request Expired'
            'Priority' = 'low'
            'Tags'     = 'hourglass'
        }
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $null = Invoke-RestMethod -Uri "$resolvedServer/$Sid" -Method Post -Headers $headers -Body $bodyBytes -TimeoutSec 10 -ErrorAction Stop
        return $true
    } catch {
        Write-Warning "could not publish the expired marker to '$Sid': $_"
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

function Test-VaultApprovalCiphertext {
    param(
        [string]$Value,
        [System.Security.Cryptography.RSA]$Rsa = $null
    )

    if (-not $Value) { return $false }
    $Value = $Value.Trim()
    # RSA-2048 / OAEP-SHA256 is always one 256-byte block, which is 344 base64
    # chars. anything else on the relay topic is noise (status markers, garbage
    # posted by whoever knows the topic) and must be skipped, not returned.
    if ($Value.Length -ne 344) { return $false }
    if ($Value -notmatch '^[A-Za-z0-9+/]+={0,2}$') { return $false }
    try {
        $bytes = [Convert]::FromBase64String($Value)
    } catch {
        return $false
    }
    if ($bytes.Length -ne 256) { return $false }
    if ($Rsa) {
        # a well-formed block this key cannot decrypt is not our approval --
        # accepting it would kill the real one inside the poll window.
        try {
            $null = $Rsa.Decrypt($bytes, [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
        } catch {
            return $false
        }
    }
    return $true
}

function Wait-VaultApprovalCiphertext {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Sid,
        [int]$TimeoutSeconds = 300,
        [string]$LocalFileName = 'mainframe-vault-pass.enc',
        [DateTime]$StartTimeUtc = [DateTime]::MinValue,
        [System.Security.Cryptography.RSA]$Rsa = $null,
        [string]$Server = $null
    )

    $resolvedServer = Get-VaultNtfyServer -Server $Server
    $downloadPath = Join-Path $HOME "Downloads\$LocalFileName"
    $sessionFile = Join-Path $env:APPDATA 'mainframe\accounts\bitwarden\session.key'
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 2

        # 1. Check if another agent completed the unlock while we were waiting
        if ($StartTimeUtc -ne [DateTime]::MinValue -and (Test-Path -LiteralPath $sessionFile)) {
            $fi = Get-Item -LiteralPath $sessionFile
            if ($fi.LastWriteTimeUtc -ge $StartTimeUtc) {
                return '__SESSION_ALREADY_UNLOCKED__'
            }
        }

        # 2. Poll relay topic
        try {
            # Invoke-RestMethod parses a JSON body into an object, which turns
            # an expired marker into something no regex can recognise. the
            # webrequest content stays text, so markers and ciphertext look
            # the way they were posted.
            $resp = Invoke-WebRequest -Uri "$resolvedServer/$Sid/raw?poll=1" -Method Get -TimeoutSec 5 -ErrorAction Stop
            $body = [string]$resp.Content
            if ($body) {
                # raw returns every message on the topic, newline separated.
                # only a payload that is a valid RSA block for this request is
                # an approval; expired markers and spoofed bodies are skipped so
                # they cannot end the wait.
                $cipherLines = @(
                    $body -split "`n" |
                        ForEach-Object { $_.Trim() } |
                        Where-Object { Test-VaultApprovalCiphertext -Value $_ -Rsa $Rsa }
                )
                if ($cipherLines.Count -gt 0) {
                    return $cipherLines[-1]
                }
            }
        } catch {
            # timeout/no message yet
        }

        # 3. Check local file
        if (Test-Path -LiteralPath $downloadPath) {
            try {
                $content = (Get-Content -LiteralPath $downloadPath -Raw).Trim()
                Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
                if (Test-VaultApprovalCiphertext -Value $content -Rsa $Rsa) {
                    return $content
                }
                if ($content) {
                    Write-Warning "ignoring $LocalFileName -- not a valid approval payload for this request"
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

    if (-not (Test-VaultApprovalCiphertext -Value $Ciphertext)) {
        throw "approval payload is not a well-formed 256-byte RSA ciphertext (length $($Ciphertext.Length)) -- refusing to treat it as the master password"
    }
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
        [string]$HostName = $env:COMPUTERNAME,
        [DateTime]$StartTimeUtc = [DateTime]::MinValue,
        [string]$Server = $null,
        [string]$PagesBase = $null
    )

    # Resolve ntfy topic
    if (-not $NtfyTopic) {
        $NtfyTopic = Get-VaultNtfyTopic
    }
    $resolvedServer = Get-VaultNtfyServer -Server $Server

    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    try {
        $session = Get-VaultApprovalUrl -Rsa $rsa -PromptContext $PromptContext -HostName $HostName -Agent $Agent -Model $Model -ExpiresInSeconds $TimeoutSeconds -Server $resolvedServer -PagesBase $PagesBase
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
            $sent = Send-VaultApprovalNotification -Topic $NtfyTopic -Url $url -Code $code -PromptContext $PromptContext -HostName $HostName -Agent $resolvedAgent -Model $resolvedModel -Server $resolvedServer
            if ($sent) {
                Write-Host "push notification sent to ntfy topic: $NtfyTopic" -ForegroundColor Green
            }
        }

        $opened = Open-VaultApprovalOnPhone -Url $url

        Write-Host "waiting for 1-tap fingerprint approval on phone (or ~/Downloads/mainframe-vault-pass.enc) ..." -ForegroundColor Yellow
        $ct = Wait-VaultApprovalCiphertext -Sid $sid -TimeoutSeconds $TimeoutSeconds -StartTimeUtc $StartTimeUtc -Rsa $rsa -Server $resolvedServer

        if ($ct -eq '__SESSION_ALREADY_UNLOCKED__') {
            $null = Send-VaultRequestExpired -Sid $sid -HostName $HostName -Code $code -Server $resolvedServer
            return '__SESSION_ALREADY_UNLOCKED__'
        }

        if ($ct) {
            $pw = Decrypt-VaultApprovalCiphertext -Rsa $rsa -Ciphertext $ct
            Write-Host "password decrypted successfully via 1-tap biometric approval" -ForegroundColor Green
            return $pw
        } else {
            $null = Send-VaultRequestExpired -Sid $sid -HostName $HostName -Code $code -Server $resolvedServer
            Write-Warning "phone approval timed out after $TimeoutSeconds seconds."
            return $null
        }
    } finally {
        $rsa.Dispose()
    }
}

Export-ModuleMember -Function `
    Get-CallerIdentity, `
    Get-VaultConfigValue, `
    Get-VaultNtfyTopic, `
    Get-VaultNtfyServer, `
    Get-VaultPagesBase, `
    Get-VaultApprovalUrl, `
    Send-VaultApprovalNotification, `
    Send-VaultRequestExpired, `
    Open-VaultApprovalOnPhone, `
    Test-VaultApprovalCiphertext, `
    Wait-VaultApprovalCiphertext, `
    Decrypt-VaultApprovalCiphertext, `
    Get-VaultMasterPassword
