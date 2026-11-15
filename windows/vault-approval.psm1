<#
.SYNOPSIS
    Cross-platform 1-tap mobile biometric approval for Bitwarden vault restore.
.DESCRIPTION
    Generates an ephemeral RSA-2048 keypair, dispatches an urgent push notification
    to ntfy, pops up a full-screen approval prompt via ADB if a phone is attached,
    and listens on the single-use relay topic for client-side encrypted master password.
#>

# the profile root is resolved by one shared module, so windows and linux read
# the same place (see mainframe-paths.psm1).
Import-Module (Join-Path $PSScriptRoot 'mainframe-paths.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'mainframe-json.psm1') -Force -DisableNameChecking

function Get-MiniMaxSessionId {
    # The MiniMax Code desktop app gives each session an id that shows up in
    # two places: an env var when the runtime sets one, and the session
    # workspace path the agent runs in. The v2 session tree on disk is keyed
    # by that id, which is how the active model can be read back ground-truth.
    foreach ($name in @('MINIMAX_SESSION_ID', 'MAVIS_SESSION_ID', 'MINIMAX_CODE_SESSION_ID', 'MINIMAX_CONVERSATION_ID')) {
        $v = [Environment]::GetEnvironmentVariable($name)
        if ($v) { return $v.Trim() }
    }
    try {
        $cwd = (Get-Location).Path
        if ($cwd -match 'sessions[\\/](mvs_[A-Za-z0-9]+)') { return $matches[1] }
    } catch {}
    return $null
}

function Get-MiniMaxModelFromDisk {
    param([string]$SessionId = $null)

    # Ground truth: MiniMax Code writes the request payload of every LLM call
    # to <data>/v2/sessions/<yyyy>/<mm>/<dd>/<hh-mm-ss-mmm>-session_<b64url-id>/llm-call.json
    # and that file carries the model the call actually used.
    $root = Join-Path $HOME '.minimax\v2\sessions'
    if (-not (Test-Path -LiteralPath $root)) { return $null }

    $files = @()
    if ($SessionId) {
        $enc = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($SessionId)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        $files = @(Get-ChildItem -LiteralPath $root -Recurse -Filter 'llm-call.json' -ErrorAction SilentlyContinue |
                Where-Object { $_.Directory.Name -like "*_${enc}" })
        # an explicitly asked-for session is authoritative: if it has no
        # llm-call.json then the model is simply unknown. falling back to
        # another session here would put the wrong model on the phone card.
        if ($files.Count -eq 0) { return $null }
    } else {
        # No session id to scope with: fall back to the session that wrote an
        # llm-call.json most recently. The window is short on purpose - a
        # finished session must not keep claiming the tag after the agent
        # moved on.
        $cutoff = (Get-Date).AddMinutes(-15)
        $files = @(Get-ChildItem -LiteralPath $root -Recurse -Filter 'llm-call.json' -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -ge $cutoff })
    }
    if ($files.Count -eq 0) { return $null }

    $f = $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    try {
        $j = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($j.model) { return ([string]$j.model).Trim() }
    } catch {}
    return $null
}

function Get-CallerIdentity {
    param(
        [string]$Agent,
        [string]$Model,
        [string]$PromptContext = $null
    )

    # 1. Explicit or context-inferred browser requests from web UI
    if (-not $Agent -and $PromptContext -and ($PromptContext -match 'monitor' -or $PromptContext -match 'browser')) {
        return [PSCustomObject]@{
            Agent = 'browser'
            Model = $null
        }
    }

    # 2. An explicit operator override wins over everything else.
    if (-not $Agent) {
        $Agent = $env:MAINFRAME_AGENT_NAME
    }
    if (-not $Model) {
        $Model = $env:MAINFRAME_MODEL_NAME
        if (-not $Model) { $Model = $env:MODEL_NAME }
        if (-not $Model) { $Model = $env:AI_MODEL }
    }

    # 3. Process ancestry BEFORE the generic environment variables.
    #    Two things make the env vars untrustworthy on their own:
    #      - a harness env var leaks DOWN into long-lived services (the
    #        monitor api inherits the agent that started it), and
    #      - a compatibility flag can lie: MiniMax Code sets
    #        OPENCODE_DISABLE_CHANNEL_DB for opencode compatibility, so the
    #        env branch read every MiniMax Code request as 'opencode'.
    #    The process tree cannot be inherited wrongly, so it decides first.
    if (-not $Agent) {
        $p = $null
        try { $p = (Get-Process -Id $PID -ErrorAction SilentlyContinue).Parent } catch { $p = $null }
        while ($p) {
            $name = ''
            try { $name = $p.ProcessName.ToLower() } catch { $name = '' }
            # If running under node.exe serving the monitor, it's the browser
            if ($name -match 'node') {
                $cmd = ''
                try { $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId = $($p.Id)" -ErrorAction SilentlyContinue).CommandLine } catch { $cmd = '' }
                if ($cmd -match 'monitor' -or $cmd -match 'server\.ts') {
                    $Agent = 'browser'
                    break
                }
            }
            if ($name -match 'minimax|mcode') { $Agent = 'minimax-code'; break }
            if ($name -match 'qoder') { $Agent = 'qoder'; break }
            if ($name -match 'claude') { $Agent = 'claude-code'; break }
            if ($name -match 'opencode') { $Agent = 'opencode'; break }
            if ($name -match 'cursor') { $Agent = 'cursor'; break }
            if ($name -match 'windsurf') { $Agent = 'windsurf'; break }
            if ($name -match 'codex') { $Agent = 'codex'; break }
            if ($name -match 'antigravity') { $Agent = 'antigravity'; break }
            try { $p = $p.Parent } catch { $p = $null }
        }
    }

    # 4. The named agent env vars, now only as a fallback.
    if (-not $Agent) {
        $Agent = $env:AGENT_NAME
        if (-not $Agent) { $Agent = $env:AI_AGENT }
        if (-not $Agent) { $Agent = $env:HARNESS_NAME }
    }

    # 5. Environment variables, last resort.
    if (-not $Agent) {
        if ($env:QODER_CLI -or $env:QODER_PRODUCT_ID -or $env:QODER_SESSION_TYPE) {
            # qoder sets OPENCODE_DISABLE_CHANNEL_DB for compatibility, so it
            # must be tested before the opencode branch or it reads as opencode
            $Agent = 'qoder'
        } elseif ($env:OPENCODE -or $env:OPENCODE_SESSION) {
            $Agent = 'opencode'
        } elseif ($env:CLAUDE_CODE -or $env:CLAUDE_PROJECT_DIR) {
            $Agent = 'claude-code'
        } elseif ($env:CODEX -or $env:CODEX_MODEL) {
            $Agent = 'codex'
        } elseif ($env:AIDER_MODEL) {
            $Agent = 'aider'
        } elseif ($env:ANTIGRAVITY_AGENT -or $env:ANTIGRAVITY_CONVERSATION_ID) {
            $Agent = 'antigravity'
        } elseif ($env:OPENCODE_DISABLE_CHANNEL_DB) {
            # the compat flag ALONE, with no harness-specific marker. it is
            # the weakest signal there is - MiniMax Code sets it as well - so
            # it goes last, after every marker above has had its chance.
            $Agent = 'opencode'
        } else {
            $Agent = 'terminal'
        }
    }

    # Human / browser / terminal callers do not have an LLM model
    if ($Agent -eq 'browser' -or $Agent -eq 'terminal') {
        return [PSCustomObject]@{
            Agent = $Agent
            Model = $null
        }
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
                # Scan transcript for user model settings changes across the conversation.
                # Only match USER_INPUT entries so tool outputs or agent responses echoing
                # the prompt pattern do not get falsely picked as model switches.
                $userLines = @(Get-Content -LiteralPath $transcript -ErrorAction SilentlyContinue |
                    Where-Object { $_ -match '"type"\s*:\s*"USER_INPUT"' -and $_ -match 'Model Selection.*?from\s+.*?\s+to\s+(.+?)\.\s+No need' })
                if ($userLines.Count -gt 0) {
                    $matches = @($userLines | Select-String -Pattern "Model Selection.*?from\s+.*?\s+to\s+(.+?)\.\s+No need")
                    if ($matches.Count -gt 0) {
                        $Model = $matches[-1].Matches[0].Groups[1].Value.Trim()
                    }
                }
            }
            if (-not $Model -and $env:ANTIGRAVITY_MODEL) {
                $Model = $env:ANTIGRAVITY_MODEL
            }
        } elseif ($Agent -eq 'opencode') {
            if ($env:OPENCODE_MODEL) { $Model = $env:OPENCODE_MODEL }
        } elseif ($Agent -eq 'minimax-code') {
            # MiniMax Code exposes no model env var, so the ground truth is
            # the session tree on disk: every LLM call writes llm-call.json
            # into the session's folder, and the folder name carries the
            # session id (base64url). Reading the model back from the file
            # that the call itself wrote beats guessing.
            if ($env:MINIMAX_MODEL) { $Model = $env:MINIMAX_MODEL }
            elseif ($env:MINIMAX_MODEL_NAME) { $Model = $env:MINIMAX_MODEL_NAME }
            elseif ($env:MAVIS_MODEL) { $Model = $env:MAVIS_MODEL }
            if (-not $Model) {
                $Model = Get-MiniMaxModelFromDisk -SessionId (Get-MiniMaxSessionId)
            }
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
    # the same approval page without touching code. the lookup itself lives
    # in mainframe-paths.psm1 - a literal '.config\mainframe' never matches
    # on linux, so the profile root has to be resolved the portable way.
    return Get-MainframeConfigValue -Key $Key
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

# topic-only auth: there is no ntfy credential in the design any more.
# the topic name in mainframe.config.json is the only credential - a
# request that knows it may publish and read, no header or token is ever
# sent. (an earlier design carried an ntfy access token / basic auth in
# the config and a relay credential on the worker; both were removed
# 2026-11-15 because every new machine needed a manual handover step.)
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

function ConvertTo-DerLength {
    param([int]$Length)

    # DER length: short form under 128, otherwise the long form with the
    # number of length bytes in the top bits.
    if ($Length -lt 0x80) { return ,([byte[]]@($Length)) }
    $bytes = New-Object System.Collections.Generic.List[byte]
    $value = $Length
    while ($value -gt 0) {
        $bytes.Insert(0, [byte]($value -band 0xFF))
        $value = $value -shr 8
    }
    $out = New-Object System.Collections.Generic.List[byte]
    $out.Add([byte](0x80 -bor $bytes.Count))
    $out.AddRange($bytes.ToArray())
    return ,$out.ToArray()
}

function ConvertTo-DerInteger {
    param([byte[]]$Value)

    # a DER INTEGER is signed, so a leading zero byte goes in front when the
    # top bit of the first content byte is set. leading zero bytes that are
    # already there are dropped.
    $start = 0
    while ($start -lt ($Value.Length - 1) -and $Value[$start] -eq 0) { $start++ }
    $body = New-Object System.Collections.Generic.List[byte]
    for ($i = $start; $i -lt $Value.Length; $i++) { $body.Add($Value[$i]) }
    if ($body.Count -gt 0 -and ($body[0] -band 0x80) -ne 0) { $body.Insert(0, [byte]0) }

    $length = ConvertTo-DerLength $body.Count
    $out = New-Object System.Collections.Generic.List[byte]
    $out.Add([byte]0x02)
    $out.AddRange($length)
    $out.AddRange($body.ToArray())
    return ,$out.ToArray()
}

function ConvertTo-DerSequence {
    param([byte[]]$Content)

    $length = ConvertTo-DerLength $Content.Length
    $out = New-Object System.Collections.Generic.List[byte]
    $out.Add([byte]0x30)
    $out.AddRange($length)
    $out.AddRange($Content)
    return ,$out.ToArray()
}

function ConvertTo-DerBitString {
    param([byte[]]$Content)

    # a BIT STRING carries the number of unused bits in the first content byte
    $length = ConvertTo-DerLength ($Content.Length + 1)
    $out = New-Object System.Collections.Generic.List[byte]
    $out.Add([byte]0x03)
    $out.AddRange($length)
    $out.Add([byte]0x00)
    $out.AddRange($Content)
    return ,$out.ToArray()
}

function ConvertTo-SubjectPublicKeyInfoManual {
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.RSA]$Rsa
    )

    # hand rolled SubjectPublicKeyInfo:
    #
    #   SEQUENCE {
    #     SEQUENCE { OID 1.2.840.113549.1.1.1, NULL },
    #     BIT STRING { SEQUENCE { modulus INTEGER, exponent INTEGER } }
    #   }
    #
    # this is the .NET framework path - see ConvertTo-SubjectPublicKeyInfo.
    $public = $Rsa.ExportParameters($false)

    $rsaPublicKey = ConvertTo-DerSequence (
        (ConvertTo-DerInteger $public.Modulus) + (ConvertTo-DerInteger $public.Exponent)
    )

    $algorithm = ConvertTo-DerSequence ([byte[]]@(
        0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01,
        0x05, 0x00
    ))

    return ,(ConvertTo-DerSequence ($algorithm + (ConvertTo-DerBitString $rsaPublicKey)))
}

function ConvertTo-SubjectPublicKeyInfo {
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.RSA]$Rsa
    )

    # The approval page imports this key with WebCrypto as 'spki', so it has
    # to be a real SubjectPublicKeyInfo DER structure.
    #
    # RSA.ExportSubjectPublicKeyInfo() is .NET Core only. windows powershell
    # 5.1 (.NET framework) has no such method and no RSAExtensions type at
    # all, and RSA.Create() there returns an RSACng - so calling the method
    # there dies with "does not contain a method named
    # 'ExportSubjectPublicKeyInfo'". that breaks the 1-tap unlock for every
    # helper invoked through `powershell -File`, because the unlock flow runs
    # inside windows powershell.
    #
    # so: use the native method when the runtime has it, and build the same
    # bytes by hand when it does not. the hand rolled encoder is byte for byte
    # identical to the native one - there is a test for that.
    if ([System.Security.Cryptography.RSA].GetMethod('ExportSubjectPublicKeyInfo')) {
        return ,($Rsa.ExportSubjectPublicKeyInfo())
    }
    return ,(ConvertTo-SubjectPublicKeyInfoManual -Rsa $Rsa)
}

# The approval descriptor: the exact set of facts the phone is asked to trust.
#
# The link fragment carries the RSA public key (k), the single-use topic (sid),
# the verification code, the expiry and where the answer may be posted - plus
# a signature (sig) over k/sid/code/exp/srv, made with ONE shared EC P-256 key
# for the whole ecosystem (approval-signing.key in the profile root, public
# half pinned in the page). The page verifies the signature before it offers
# the approve button: a link nobody signed warns loudly, and a link signed
# with the wrong key is refused outright. A missing key means an UNSIGNED
# link, which the page warns about but still allows - that only happens on
# existing machines during the transition (a new device gets key+topic
# together in the pack, so its first approval is already signed). The key
# self-heals from the vault whenever a live session exists (see
# Sync-VaultApprovalSigningKeyFromVault), so after the first unlock every
# approval is signed and the approval itself never fails for a missing key.
# (An earlier per-machine registration design was removed 2026-11-15 because
# every new machine needed a manual registration step; the shared key
# replaces it - see docs/approval-signing-bootstrap.md.)

# the query on the approval page URL. it busts the browser cache, so a phone
# that still has an OLD page cached fetches the new one instead of using it.
# bump it whenever the page changes in a way that matters for an already
# opened link.
$script:VaultApprovalPageVersion = 'topic1'

function Get-VaultApprovalSigningKeyPath {
    param([string]$Path = $null)

    if ($Path) { return $Path }
    if ($env:MAINFRAME_APPROVAL_SIGNING_KEY) { return $env:MAINFRAME_APPROVAL_SIGNING_KEY }
    $root = Get-MainframeCheckoutRoot
    if ($root) { return (Join-Path $root 'mainframe.approval-signing.key') }
    return $null
}

function New-VaultApprovalSigningKeyFile {
    <#
    .SYNOPSIS
        mint this machine's own approval signing key and write it to -Path.
    .DESCRIPTION
        RSA-2048, exported in the same JSON shape the loader reads
        (n/e/d/p/q/dp/dq/qi, base64). Returns the public half as base64url
        SubjectPublicKeyInfo - the string the approval page encrypts the
        master password to (RSA-OAEP), so only this machine can read it
        back.

        A machine generates its key exactly once, on its first approval
        request; after that the file just loads. The private half never
        leaves the machine.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    try {
        $p = $rsa.ExportParameters($true)
        $key = [ordered]@{
            n  = [Convert]::ToBase64String($p.Modulus)
            e  = [Convert]::ToBase64String($p.Exponent)
            d  = [Convert]::ToBase64String($p.D)
            p  = [Convert]::ToBase64String($p.P)
            q  = [Convert]::ToBase64String($p.Q)
            dp = [Convert]::ToBase64String($p.DP)
            dq = [Convert]::ToBase64String($p.DQ)
            qi = [Convert]::ToBase64String($p.InverseQ)
        }
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        [IO.File]::WriteAllText($Path, ($key | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
        try {
            if ([Environment]::OSVersion.Platform -eq [PlatformID]::Unix) { & chmod 600 $Path | Out-Null }
        } catch { }
        $spki = ConvertTo-SubjectPublicKeyInfo -Rsa $rsa
        return [Convert]::ToBase64String($spki).Replace('+', '-').Replace('/', '_').TrimEnd('=')
    } finally {
        $rsa.Dispose()
    }
}

function Get-VaultApprovalSigningKey {
    <#
    .SYNOPSIS
        this machine's RSA private key (the phone page encrypts the
        master password to its public half).
    .DESCRIPTION
        Each machine has its OWN key. When no key was provisioned for
        this machine and none is configured, the first call mints a pair
        (New-VaultApprovalSigningKeyFile) and uses it straight away -
        there is no registration list and no approval step for a new
        machine. The ntfy topic is the credential that gates who can ask
        for an approval; the key only carries the password back encrypted
        (RSA-OAEP), so the relay never sees it in the clear.

        An explicitly configured key (-Path, or
        $env:MAINFRAME_APPROVAL_SIGNING_KEY) that is missing still throws
        the restore message: that is a broken restore, not a first run.
    #>
    param([string]$Path = $null)

    $keyPath = Get-VaultApprovalSigningKeyPath -Path $Path
    if (-not $keyPath) {
        throw "no approval signing key path: set `$env:MAINFRAME_APPROVAL_SIGNING_KEY to the key file, or keep the mainframe checkout where mainframe.approval-signing.key sits next to mainframe.config.json. the key is kept in the bitwarden vault as github.com/FahadBinHussain/mainframe/mainframe.approval-signing.key and is restored by C:\Users\Admin\Downloads\automata-private\tools\env-sync.ps1 -Repo mainframe."
    }
    if (-not (Test-Path -LiteralPath $keyPath)) {
        if ($Path -or $env:MAINFRAME_APPROVAL_SIGNING_KEY) {
            throw "the approval signing key is missing: $keyPath. restore it from the bitwarden vault (github.com/FahadBinHussain/mainframe/mainframe.approval-signing.key) with C:\Users\Admin\Downloads\automata-private\tools\env-sync.ps1 -Repo mainframe. without it the phone page has no public key to encrypt the password to, so no approval can complete."
        }
        # first run on this machine: mint the key and use it. no
        # registration, no list - the topic is the credential.
        $null = New-VaultApprovalSigningKeyFile -Path $keyPath
    }
    $raw = Get-Content -LiteralPath $keyPath -Raw
    try {
        $key = $raw | ConvertFrom-Json
    } catch {
        throw "the approval signing key at $keyPath is not valid JSON: $($_.Exception.Message)"
    }
    foreach ($field in @('n', 'e', 'd', 'p', 'q', 'dp', 'dq', 'qi')) {
        if (-not $key.$field) {
            throw "the approval signing key at $keyPath has no '$field' field - it is not a mainframe approval key file"
        }
    }
    $rsa = [System.Security.Cryptography.RSA]::Create()
    try {
        $rsa.ImportParameters([System.Security.Cryptography.RSAParameters]@{
                Modulus  = [Convert]::FromBase64String($key.n)
                Exponent = [Convert]::FromBase64String($key.e)
                D        = [Convert]::FromBase64String($key.d)
                P        = [Convert]::FromBase64String($key.p)
                Q        = [Convert]::FromBase64String($key.q)
                DP       = [Convert]::FromBase64String($key.dp)
                DQ       = [Convert]::FromBase64String($key.dq)
                InverseQ = [Convert]::FromBase64String($key.qi)
            })
    } catch {
        $rsa.Dispose()
        throw "the approval signing key at $keyPath could not be loaded: $($_.Exception.Message)"
    }
    return $rsa
}

function Get-VaultApprovalPublicKey {
    <#
    .SYNOPSIS
        the signing public key as base64url SubjectPublicKeyInfo.
    .DESCRIPTION
        The same string travels in the approval link as `k`. It is public
        by design - it encrypts the password, it does not decrypt it.
    #>
    param([string]$Path = $null)

    $rsa = Get-VaultApprovalSigningKey -Path $Path
    try {
        $spki = ConvertTo-SubjectPublicKeyInfo -Rsa $rsa
        return [Convert]::ToBase64String($spki).Replace('+', '-').Replace('/', '_').TrimEnd('=')
    } finally {
        $rsa.Dispose()
    }
}

# --- link signing (C1): ONE shared EC P-256 key for the whole ecosystem -----
#
# This is deliberately NOT the per-machine registration design that was
# removed 2026-11-15 (it needed a manual registration step per machine, and
# the user rejected it): one key pair, private half in the profile root as
# approval-signing.key (SEC1 PEM, EC P-256, 0600), public half pinned in the
# approval page. The runner signs k/sid/code/exp/srv and the page verifies
# against the pinned key, so a link from anyone else fails closed.
#
# A new device needs ZERO setup: the key travels WITH the topic in the
# migration pack, so a device that can send an approval at all already has
# the key and its FIRST approval is signed. (A device without the topic
# cannot approve - the runner fails loudly with "no ntfy topic configured"
# - so there is no "new device, no key" case.) The unsigned link only
# occurs on EXISTING machines during the transition, when their vault
# session is dead at the moment of the first approval after the warn-mode
# page deploys: unsigned approval (page warns, allows) -> fingerprint ->
# unlock -> the runner fetches the key with the session the unlock just
# created -> all later approvals signed.
#
# Three heal points, one rule - the fetch runs ONLY when a live session
# already exists, never prompts, never blocks, never attempts against a
# locked vault:
#   1. flow-start-when-live (vault-flow.ps1, cached session): the session
#      is already live and no approval is needed at all - heal the key now.
#   2. request-time-if-live (Get-VaultApprovalLinkSigningKey): the approval
#      is being built and a live session happens to exist - heal, then sign.
#   3. after-unlock (vault-flow.ps1 + Ensure-VaultSession): the unlock just
#      proved a live session - heal, so the NEXT approval is signed.
# Signing never fails or delays an approval: any failure here degrades to
# an unsigned link.
#
# Scheme (interop-proven: pwsh ECDsa signs, Node WebCrypto verifies):
# ECDSA P-256 + SHA-256, signature = 64-byte raw R||S (P1363, which is what
# .NET ECDsa.SignData returns by default), base64url, no padding, carried as
# the fragment param `sig`. Payload, byte-exact on both sides:
# k LF sid LF code LF exp LF srv (UTF-8), where exp/srv are the exact strings
# placed in the URL ('' when the param is absent).
#
# This is a DIFFERENT key from the old RSA machine key above
# (mainframe.approval-signing.key + Get-VaultApprovalSigningKey): that one is
# dead code the user has not decided to remove, and nothing here touches it.
$script:VaultApprovalLinkSigningKeyFileName = 'approval-signing.key'
$script:VaultApprovalLinkSigningVaultItemName = 'github.com/FahadBinHussain/mainframe / approval-signing.key'

function Get-VaultApprovalLinkSigningKeyPath {
    <#
    .SYNOPSIS
        where the shared link-signing private key lives: the profile root,
        resolved through Get-MainframeProfileRoot, never a hardcoded path.
    #>
    param([string]$Path = $null)

    if ($Path) { return $Path }
    return (Join-Path (Get-MainframeProfileRoot) $script:VaultApprovalLinkSigningKeyFileName)
}

function Get-VaultApprovalLinkPayload {
    <#
    .SYNOPSIS
        the exact bytes the link signature covers: k LF sid LF code LF exp
        LF srv. exp/srv are the strings as serialized into the URL ('' when
        the param is absent) - sign the string, never re-format it.
    #>
    param(
        [string]$Key,
        [string]$Sid,
        [string]$Code,
        [string]$Exp = '',
        [string]$Server = ''
    )

    if ($null -eq $Key) { $Key = '' }
    if ($null -eq $Sid) { $Sid = '' }
    if ($null -eq $Code) { $Code = '' }
    if ($null -eq $Exp) { $Exp = '' }
    if ($null -eq $Server) { $Server = '' }
    return ($Key + "`n" + $Sid + "`n" + $Code + "`n" + $Exp + "`n" + $Server)
}

function Get-VaultApprovalLinkSignature {
    <#
    .SYNOPSIS
        sign a link payload with the shared EC key. returns the 64-byte raw
        R||S signature as base64url, no padding.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.ECDsa]$Key,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Payload
    )

    # SignData's default format is P1363 (raw R||S) - 64 bytes for P-256,
    # which is exactly what WebCrypto's ECDSA verify expects.
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Payload)
    $sig = $Key.SignData($bytes, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    return [Convert]::ToBase64String($sig).Replace('+', '-').Replace('/', '_').TrimEnd('=')
}

function Invoke-BwApprovalCommand {
    <#
    .SYNOPSIS
        run the bw CLI with a hard timeout. returns stdout on success, $null
        on any failure (bw missing, non-zero exit, timeout) - the signing
        path treats every failure as "no live session", never as an error.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [int]$TimeoutSeconds = 10
    )

    $bw = Get-Command bw -ErrorAction SilentlyContinue
    if (-not $bw) { return $null }
    try {
        # Arguments (not ArgumentList) so windows powershell 5.1 works too.
        $quoted = foreach ($a in $Arguments) { '"' + ($a -replace '"', '\"') + '"' }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $bw.Source
        $psi.Arguments = ($quoted -join ' ')
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            try { $proc.Kill() } catch {}
            return $null
        }
        $out = $proc.StandardOutput.ReadToEnd()
        if ($proc.ExitCode -ne 0) { return $null }
        return $out
    } catch {
        return $null
    }
}

function Test-VaultApprovalLiveSession {
    <#
    .SYNOPSIS
        true when the bw CLI reports unlocked - the only condition under
        which the signing key may be fetched from the vault without a user
        step. never prompts, never throws.
    #>
    param([string]$Session = $null)

    $args = @('status')
    if ($Session) { $args += @('--session', $Session) }
    $out = Invoke-BwApprovalCommand -Arguments $args -TimeoutSeconds 10
    if (-not $out) { return $false }
    try {
        $status = $out | ConvertFrom-Json
        return ($status.status -eq 'unlocked')
    } catch {
        return $false
    }
}

function Sync-VaultApprovalSigningKeyFromVault {
    <#
    .SYNOPSIS
        self-heal the shared link-signing key: if the profile-root key file
        is missing and a live bw session exists, fetch the PEM from the
        vault (item notes) and save it 0600. returns $true when the key file
        exists afterwards, $false otherwise. never throws, never prints the
        key, never prompts - a failure just means the next link is unsigned.
    .DESCRIPTION
        DEADLOCK EDGE (future enforcement): under unsigned-refused
        enforcement, "session dead + key file lost" at the same time is a
        deadlock - the runner cannot approve (unsigned refused) and cannot
        fetch the key (no session). recovery is re-delivering key+topic
        together via the migration pack. two simultaneous failures; noted
        honestly here, not engineered around.
    #>
    param(
        [string]$Session = $null,
        [string]$Path = $null
    )

    $keyPath = if ($Path) { $Path } else { Get-VaultApprovalLinkSigningKeyPath }
    if (Test-Path -LiteralPath $keyPath) { return $true }
    if (-not (Test-VaultApprovalLiveSession -Session $Session)) { return $false }
    $args = @('list', 'items', '--search', $script:VaultApprovalLinkSigningVaultItemName)
    if ($Session) { $args += @('--session', $Session) }
    $out = Invoke-BwApprovalCommand -Arguments $args -TimeoutSeconds 15
    if (-not $out) { return $false }
    try {
        $items = ConvertFrom-JsonArray -Json $out
    } catch {
        return $false
    }
    # --search is a substring match: only the exact item name is the key.
    $item = @($items | Where-Object { [string]$_.name -eq $script:VaultApprovalLinkSigningVaultItemName }) | Select-Object -First 1
    if (-not $item -or -not $item.notes) { return $false }
    $pem = ([string]$item.notes).Trim()
    if ($pem -notmatch 'BEGIN EC PRIVATE KEY') { return $false }
    try {
        Write-MainframePrivateFile -Path $keyPath -Content ($pem + "`n") | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Get-VaultApprovalLinkSigningKey {
    <#
    .SYNOPSIS
        the shared EC P-256 link-signing key, or $null when this machine has
        none (unsigned link). a missing file self-heals from the vault when
        a live session exists; otherwise the link just goes out unsigned.
        never throws - signing must never fail an approval.
    #>
    param([string]$Path = $null)

    $keyPath = if ($Path) { $Path } else { Get-VaultApprovalLinkSigningKeyPath }
    if (-not (Test-Path -LiteralPath $keyPath)) {
        $null = Sync-VaultApprovalSigningKeyFromVault -Path $keyPath
        if (-not (Test-Path -LiteralPath $keyPath)) { return $null }
    }
    try {
        $pem = [IO.File]::ReadAllText($keyPath)
        $ecdsa = [System.Security.Cryptography.ECDsa]::Create()
        try {
            # ImportFromPem is .NET Core only - windows powershell 5.1 has no
            # such method, so a 5.1 runner signs nothing (unsigned link).
            # the check is by NAME: the only overload takes a ReadOnlySpan,
            # and a GetMethod call naming [string] finds nothing even where
            # the method exists (powershell binds the string to the span
            # implicitly at the call below).
            $import = @([System.Security.Cryptography.ECDsa].GetMethods() | Where-Object { $_.Name -eq 'ImportFromPem' })
            if ($import.Count -eq 0) { $ecdsa.Dispose(); return $null }
            $ecdsa.ImportFromPem($pem)
        } catch {
            $ecdsa.Dispose()
            return $null
        }
        return $ecdsa
    } catch {
        return $null
    }
}

function Get-NtfyTopicFingerprint {
    <#
    .SYNOPSIS
        what the terminal is allowed to print about the ntfy topic: the
        first 4 chars + an ellipsis. the topic is the ONLY credential, so
        the full name never appears in output (H1).
    #>
    param([string]$Topic)

    if (-not $Topic) { return '?' }
    $head = $Topic.Substring(0, [Math]::Min(4, $Topic.Length))
    return "$head…"
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

    $identity = Get-CallerIdentity -Agent $Agent -Model $Model -PromptContext $PromptContext
    $resolvedAgent = $identity.Agent
    $resolvedModel = $identity.Model

    $derBytes = ConvertTo-SubjectPublicKeyInfo -Rsa $Rsa
    $k = [Convert]::ToBase64String($derBytes).Replace('+', '-').Replace('/', '_').TrimEnd('=')

    $sidBytes = New-Object byte[] 12
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($sidBytes)
    $sidHex = -join ($sidBytes | ForEach-Object { $_.ToString('x2') })
    $sid = "mf-vault-$sidHex"

    # Cryptographic random 4-digit verification code for Number Matching
    # (1000 + uniform 0..8999 from 2 random bytes - the modulo bias over a
    # 16-bit space is not worth mentioning). It stays a user-matching aid,
    # not a secret.
    $codeBytes = New-Object byte[] 2
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($codeBytes)
    $code = (1000 + ([BitConverter]::ToUInt16($codeBytes, 0) % 9000)).ToString()

    $escapedCtx = [Uri]::EscapeDataString($PromptContext)
    $escapedHost = [Uri]::EscapeDataString($HostName)
    $escapedAgent = [Uri]::EscapeDataString($resolvedAgent)
    $modelParam = if ($resolvedModel) { "&model=" + [Uri]::EscapeDataString($resolvedModel) } else { "" }
    $expUnix = if ($ExpiresInSeconds -gt 0) { [DateTimeOffset]::UtcNow.AddSeconds($ExpiresInSeconds).ToUnixTimeSeconds() } else { $null }
    $expParam = if ($null -ne $expUnix) { "&exp=$expUnix" } else { "" }

    $owner = ($ToolRepo -split '/')[0]
    $resolvedPages = Get-VaultPagesBase -PagesBase $PagesBase -ToolRepo $ToolRepo
    $resolvedRelay = Get-VaultNtfyServer -Server $Server
    # the relay hint rides in the link so the card posts the ciphertext back
    # to the same relay this runner reads. without it the page would
    # hardcode ntfy.sh and a machine behind a relay would never see the
    # approval land.
    $relayHint = if ($resolvedRelay -ne 'https://ntfy.sh') { $resolvedRelay } else { '' }

    $url = "$resolvedPages/docs/vault-tab.html?v=$script:VaultApprovalPageVersion#k=$k&sid=$sid&code=$code&host=$escapedHost&ctx=$escapedCtx&agent=$escapedAgent$modelParam$expParam"
    if ($resolvedRelay -ne 'https://ntfy.sh') {
        $url += "&srv=$([Uri]::EscapeDataString($resolvedRelay))"
    }

    # link signing (C1): sign the exact strings in the URL. exp/srv are ''
    # when the param is absent. k/sid/code/exp are URL-safe so raw ==
    # escaped; srv is signed UNescaped because the page URL-decodes the
    # fragment before verifying. a missing key means an unsigned link - the
    # page warns but allows it, and the approval never fails for it.
    $expString = if ($null -ne $expUnix) { "$expUnix" } else { '' }
    $srvString = $relayHint
    $signature = $null
    $signedPayload = $null
    $linkKey = Get-VaultApprovalLinkSigningKey
    if ($linkKey) {
        try {
            $signedPayload = Get-VaultApprovalLinkPayload -Key $k -Sid $sid -Code $code -Exp $expString -Server $srvString
            $signature = Get-VaultApprovalLinkSignature -Key $linkKey -Payload $signedPayload
            $url += "&sig=$signature"
        } catch {
            $signature = $null
            $signedPayload = $null
        } finally {
            $linkKey.Dispose()
        }
    }

    return [PSCustomObject]@{
        Url           = $url
        Sid           = $sid
        Code          = $code
        Key           = $k
        Agent         = $resolvedAgent
        Model         = $resolvedModel
        ExpiresAtUnix = $expUnix
        Server        = $relayHint
        Signature     = $signature
        SignedPayload = $signedPayload
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
    # topic-only auth: every publish is anonymous. knowing the topic name
    # is the credential - no header is ever sent.
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
            # explicit text/plain: a relay in front of ntfy must be able to
            # read the body back byte for byte.
            'Content-Type' = 'text/plain; charset=utf-8'
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
        $status = 0
        try { $status = [int]$_.Exception.Response.StatusCode } catch { $status = 0 }
        if ($status -eq 401 -or $status -eq 403) {
            # the relay answers 403 only when the topic or server is wrong -
            # there is no credential to set, the topic name in
            # mainframe.config.json is the credential. without this warning
            # the only symptom is a phone that never buzzes. the topic
            # itself is never printed - only its fingerprint (H1).
            Write-MainframeWarning "ntfy refused the push (HTTP $status, topic '$(Get-NtfyTopicFingerprint -Topic $Topic)'): the relay or topic is misconfigured. check ntfyTopic and ntfyServer in mainframe.config.json - there is no credential to set."
        } else {
            Write-MainframeWarning "ntfy push dispatch (topic '$(Get-NtfyTopicFingerprint -Topic $Topic)') failed: $_"
        }
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
            'Content-Type' = 'text/plain; charset=utf-8'
        }
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $null = Invoke-RestMethod -Uri "$resolvedServer/$Sid" -Method Post -Headers $headers -Body $bodyBytes -TimeoutSec 10 -ErrorAction Stop
        return $true
    } catch {
        Write-MainframeWarning "could not publish the expired marker to '$Sid': $_"
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

function Select-VaultApprovalCiphertext {
    <#
    .SYNOPSIS
        pick the FIRST valid ciphertext out of one raw relay poll. a fake
        posted after the real one must never win (M5), and a flood of fakes
        must not burn the whole poll on trial decryptions.
    .DESCRIPTION
        lines are tried in arrival order. shape is checked first (cheap);
        only a well-formed block costs a trial decrypt, at most
        MaxTrialsPerPoll of them per call. lines already trial-decrypted in
        an earlier poll are remembered in -Tested and skipped, so a flood
        is worked through poll by poll instead of re-tried forever - the
        real ciphertext is eventually reached even behind 200 fakes.
        returns the first valid ciphertext, or $null.
    #>
    param(
        [AllowEmptyString()]
        [string]$Body,
        [System.Security.Cryptography.RSA]$Rsa = $null,
        [System.Collections.Generic.HashSet[string]]$Tested = $null,
        [int]$MaxTrialsPerPoll = 10
    )

    if (-not $Body) { return $null }
    $trials = 0
    foreach ($rawLine in ($Body -split "`n")) {
        $line = $rawLine.Trim()
        if (-not $line) { continue }
        if ($Tested -and $Tested.Contains($line)) { continue }
        if (-not (Test-VaultApprovalCiphertext -Value $line)) { continue }
        if ($trials -ge $MaxTrialsPerPoll) { break }
        $trials++
        if ($Tested) { [void]$Tested.Add($line) }
        if (Test-VaultApprovalCiphertext -Value $line -Rsa $Rsa) { return $line }
    }
    return $null
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
    # two joins, not one: a 'Downloads\file' literal would look for a file
    # NAMED "Downloads\file" inside $HOME on linux, and the browser tab's
    # download would never be found.
    $downloadPath = Join-Path (Join-Path $HOME 'Downloads') $LocalFileName
    $sessionFile = Get-MainframeSessionKeyPath
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $pollDelay = 2
    # ciphertexts already trial-decrypted in an earlier poll: skipped, so a
    # flood of fakes is worked through instead of re-tried forever (M5).
    $testedCiphertexts = New-Object System.Collections.Generic.HashSet[string]

    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds $pollDelay

        # 1. Check if another agent completed the unlock while we were waiting
        if ($StartTimeUtc -ne [DateTime]::MinValue -and (Test-Path -LiteralPath $sessionFile)) {
            $fi = Get-Item -LiteralPath $sessionFile
            if ($fi.LastWriteTimeUtc -ge $StartTimeUtc) {
                return '__SESSION_ALREADY_UNLOCKED__'
            }
        }

        # 2. Poll relay topic
        try {
            # topic-only auth: the poll carries no credential - knowing the
            # sid topic name is what authorises the read.
            $pollHeaders = @{}
            # Invoke-RestMethod parses a JSON body into an object, which turns
            # an expired marker into something no regex can recognise. the
            # webrequest content stays text, so markers and ciphertext look
            # the way they were posted.
            $resp = Invoke-WebRequest -Uri "$resolvedServer/$Sid/raw?poll=1" -Method Get -Headers $pollHeaders -TimeoutSec 5 -ErrorAction Stop
            $body = [string]$resp.Content
            if ($body) {
                # raw returns every message on the topic, newline separated.
                # only a payload that is a valid RSA block for this request is
                # an approval; expired markers and spoofed bodies are skipped so
                # they cannot end the wait. the FIRST valid block wins - a fake
                # posted after the real one must never displace it (M5).
                $found = Select-VaultApprovalCiphertext -Body $body -Rsa $Rsa -Tested $testedCiphertexts -MaxTrialsPerPoll 10
                if ($found) {
                    return $found
                }
                # bound the memory: re-testing a thousand old lines costs one
                # slow poll, keeping them forever costs the whole wait.
                if ($testedCiphertexts.Count -gt 1000) { $testedCiphertexts.Clear() }
            }
            $pollDelay = 2
        } catch {
            # ntfy rate-limits per ip. polling every 2 seconds on top of
            # another pending approval is enough to trip it, and a tripped
            # limit also eats the *push* - the phone then never hears about
            # the request at all. back off hard.
            $status = $null
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
            if ($status -eq 429) {
                $pollDelay = 30
                Write-MainframeWarning "relay rate limit hit (429) - backing off to $pollDelay seconds"
            } else {
                $pollDelay = [Math]::Min($pollDelay * 2, 30)
            }
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
                    Write-MainframeWarning "ignoring $LocalFileName -- not a valid approval payload for this request"
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
    $plain = [System.Text.Encoding]::UTF8.GetString($plainBytes)

    $pw = $plain
    $ttlMinutes = 0
    if ($plain.StartsWith('{') -and $plain.EndsWith('}')) {
        try {
            $parsed = $plain | ConvertFrom-Json
            if ($parsed.pw) {
                $pw = [string]$parsed.pw
                if ($parsed.ttl) { $ttlMinutes = [int]$parsed.ttl }
                elseif ($parsed.ttlMinutes) { $ttlMinutes = [int]$parsed.ttlMinutes }
                # the TTL comes from the phone side: trust it, but clamp it -
                # a session longer than 12 hours is never what was asked for.
                if ($ttlMinutes -gt 720) { $ttlMinutes = 720 }
            }
        } catch {}
    }

    if ($ttlMinutes -gt 0) {
        $env:MAINFRAME_VAULT_APPROVED_TTL = [string]$ttlMinutes
        $script:LastApprovedTtlMinutes = $ttlMinutes
        Write-Host "mobile approval requested extended session: $ttlMinutes minutes ($([math]::Round($ttlMinutes / 60)) hours)" -ForegroundColor Green
    } else {
        Remove-Item Env:MAINFRAME_VAULT_APPROVED_TTL -ErrorAction SilentlyContinue
        $script:LastApprovedTtlMinutes = $null
    }

    return $pw
}

function Get-VaultApprovedTtlMinutes {
    if ($env:MAINFRAME_VAULT_APPROVED_TTL) {
        try { return [int]$env:MAINFRAME_VAULT_APPROVED_TTL } catch {}
    }
    if ($script:LastApprovedTtlMinutes) {
        return [int]$script:LastApprovedTtlMinutes
    }
    return 0
}

# --- single flight: one phone prompt at a time -------------------------------
#
# Every requester used to mint its own keypair + topic and push its own
# notification. Two agents that start together therefore produced two prompts
# on the phone, and both of them polled the relay every 2 seconds - which is
# exactly how the ntfy rate limit gets tripped, and a tripped limit also eats
# the push (see AGENTS.md). The phone must not be asked twice for one unlock.
#
# So the request that gets the phone is serialised through one small file next
# to session.key:
#
#   <profile root>/accounts/bitwarden/approval.lock
#
# - the first requester creates it (atomic create, never a truncate) and asks
#   the phone. it owns the turn until it either gets the password, times out,
#   or crashes.
# - everybody else reads it and WAITS. a waiter never pushes, never opens the
#   phone, and never polls the relay - it only watches session.key and the lock
#   file, so a queue of agents costs the relay nothing.
# - the turn has a deadline written into the file (its own wait window plus a
#   margin), so a crashed holder cannot wedge the queue: once it lapses, one
#   waiter takes over and asks the phone. that is the "wait until the request
#   is stale, then send the next one" rule.
# - a waiter returns __SESSION_ALREADY_UNLOCKED__ the moment any session is
#   unlocked while it waits, so a queue drains without a second tap.
#
# The lock always records who holds it (pid, host, agent, model, code), so a
# queue reads as "waiting on code [42] by opencode @ LAPTOP-MAIN", not silence.
$script:VaultApprovalLockMarginSeconds = 15   # how long past its own wait a request keeps the turn
$script:VaultApprovalLockGraceSeconds = 5     # how long past the deadline before a waiter takes over
$script:VaultApprovalLockSettleSeconds = 20   # keep the turn while the caller writes session.key

function Get-VaultApprovalLockPath {
    <#
    .SYNOPSIS
        the one lock file that serialises phone approval requests.
    #>
    $dir = Join-Path (Get-MainframeAccountsDir) 'bitwarden'
    if (-not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop
    }
    return (Join-Path $dir 'approval.lock')
}

function ConvertFrom-VaultApprovalLockJson {
    param([string]$Json, [string]$Path)

    if (-not $Json -or -not $Json.Trim()) { return $null }
    try {
        $data = $Json | ConvertFrom-Json
    } catch {
        return $null
    }
    if (-not $data.token) { return $null }

    $started = if ($data.startedAt) { [long]$data.startedAt } else { 0 }
    $expires = if ($data.expiresAt) { [long]$data.expiresAt } else { 0 }
    $startedLocal = if ($started -gt 0) {
        [DateTimeOffset]::FromUnixTimeSeconds($started).LocalDateTime.ToString('HH:mm:ss')
    } else {
        'unknown'
    }

    return [pscustomobject]@{
        Path           = $Path
        Token          = [string]$data.token
        Pid            = [int]$data.pid
        Host           = [string]$data.host
        Context        = [string]$data.context
        Agent          = [string]$data.agent
        Model          = [string]$data.model
        State          = [string]$data.state
        Code           = [string]$data.code
        Sid            = [string]$data.sid
        StartedAtUnix  = $started
        ExpiresAtUnix  = $expires
        StartedAtLocal = $startedLocal
        Data           = $data
    }
}

function Read-VaultApprovalLock {
    param([string]$Path = (Get-VaultApprovalLockPath))

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $json = $null
    try {
        $json = [IO.File]::ReadAllText($Path)
    } catch {
        # a holder rewriting the record (or a transient share violation) reads
        # as "no record yet"; the caller loops, it never treats this as owned.
        return $null
    }
    return (ConvertFrom-VaultApprovalLockJson -Json $json -Path $Path)
}

function Write-VaultApprovalLockFile {
    <#
    .SYNOPSIS
        create the lock record atomically. returns $false when somebody already
        holds the turn - the create either wins the whole file or loses it, so
        two requesters can never both believe they own the phone.
    #>
    param(
        [string]$Path,
        [System.Collections.IDictionary]$Data
    )

    $tmp = "$Path.$PID.$([guid]::NewGuid().ToString('N').Substring(0, 8)).tmp"
    $json = ConvertTo-Json -InputObject $Data -Compress
    try {
        [IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
        # the record carries the sid + code: 0600 before the move, so the
        # lock file is never created with default perms (L11).
        Set-MainframeFileOwnerOnly -Path $tmp
        [IO.File]::Move($tmp, $Path)
        return $true
    } catch [System.IO.IOException] {
        return $false
    } finally {
        if ([IO.File]::Exists($tmp)) {
            [IO.File]::Delete($tmp)
        }
    }
}

function Set-VaultApprovalRequestDetails {
    <#
    .SYNOPSIS
        stamp the verification code / relay topic onto our own lock record, so
        a queue can say which request it is waiting on.
    #>
    param(
        [string]$Path,
        [string]$Token,
        [string]$Code,
        [string]$Sid
    )

    $current = Read-VaultApprovalLock -Path $Path
    if (-not $current -or $current.Token -ne $Token) { return $false }
    $current.Data.code = $Code
    $current.Data.sid = $Sid
    try {
        [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $current.Data -Compress))
        return $true
    } catch {
        Write-MainframeWarning "could not record the approval code on $Path - the queue will show it without a code: $_"
        return $false
    }
}

function Remove-VaultApprovalLock {
    <#
    .SYNOPSIS
        delete the lock, but only while it still carries the expected token -
        a record that somebody took over is never deleted out from under them.
    #>
    param(
        [string]$Path,
        [string]$Token
    )

    $current = Read-VaultApprovalLock -Path $Path
    if (-not $current) { return $true }
    if ($Token -and $current.Token -ne $Token) { return $false }
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    return (-not (Test-Path -LiteralPath $Path))
}

function Test-VaultSessionKeyFresh {
    <#
    .SYNOPSIS
        true when a session key was written at or after the given moment - the
        same rule Wait-VaultApprovalCiphertext uses to notice another agent's
        unlock.
    #>
    param(
        [string]$SessionFile = (Get-MainframeSessionKeyPath),
        [DateTime]$SinceUtc = [DateTime]::MinValue
    )

    if ($SinceUtc -eq [DateTime]::MinValue) { return $false }
    if (-not (Test-Path -LiteralPath $SessionFile)) { return $false }
    try {
        $written = (Get-Item -LiteralPath $SessionFile).LastWriteTimeUtc
        return ($written -ge $SinceUtc.ToUniversalTime())
    } catch {
        return $false
    }
}

function Enter-VaultApprovalRequest {
    <#
    .SYNOPSIS
        take the phone turn, or wait quietly until the live request goes stale.

    .DESCRIPTION
        Returns an object with either:
            Acquired = $true   - this caller owns the prompt and must close the
                                 request when it is done (Close-VaultApprovalRequest)
            AlreadyUnlocked    - a session key appeared while waiting; nothing
                                 was pushed and nothing must be
        It throws when the queue itself cannot move (a dead holder that never
        releases, an unreadable lock path), so a stuck queue is never silent.
    #>
    param(
        [string]$PromptContext = 'vault access',
        [int]$TimeoutSeconds = 300,
        [string]$Agent = $null,
        [string]$Model = $null,
        [string]$HostName = $env:COMPUTERNAME,
        [DateTime]$SinceUtc = [DateTime]::MinValue,
        [int]$QueueTimeoutSeconds = 0
    )

    $path = Get-VaultApprovalLockPath
    $sessionFile = Get-MainframeSessionKeyPath
    if ($SinceUtc -eq [DateTime]::MinValue) { $SinceUtc = [DateTime]::UtcNow }
    if ($QueueTimeoutSeconds -le 0) {
        # enough turns for a stampede to drain, and never less than ten minutes
        # so a slow tap is not cut short by the queue itself.
        $QueueTimeoutSeconds = [Math]::Max(600, $TimeoutSeconds * 4)
    }
    $queueDeadline = [DateTime]::UtcNow.AddSeconds($QueueTimeoutSeconds)
    $waitingOn = ''
    $waited = $false

    while ($true) {
        if (Test-VaultSessionKeyFresh -SessionFile $sessionFile -SinceUtc $SinceUtc) {
            if ($waited) {
                Write-Host 'the vault was unlocked while this request waited - no phone prompt was sent' -ForegroundColor Green
            }
            return [pscustomobject]@{ Acquired = $false; AlreadyUnlocked = $true; Path = $path; Token = $null }
        }

        if ([DateTime]::UtcNow -gt $queueDeadline) {
            $owner = Read-VaultApprovalLock -Path $path
            $ownerText = if ($owner) {
                "code [$($owner.Code)] by $($owner.Agent) @ $($owner.Host), pid $($owner.Pid), expires $($owner.ExpiresAtUnix)"
            } else {
                'nobody - the lock file is gone'
            }
            throw "another agent's phone approval has been in flight for more than $QueueTimeoutSeconds seconds and this request gave up waiting. nothing was pushed to the phone from this request. lock: $path; holder: $ownerText"
        }

        $holder = Read-VaultApprovalLock -Path $path
        $nowUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

        if ($holder -and $holder.ExpiresAtUnix -gt $nowUnix) {
            $holderId = "$($holder.Pid)|$($holder.StartedAtUnix)"
            if ($holderId -ne $waitingOn) {
                $waitingOn = $holderId
                $waited = $true
                $codeText = if ($holder.Code) { "code [$($holder.Code)]" } else { 'no code yet' }
                $left = [int]($holder.ExpiresAtUnix - $nowUnix)
                Write-Host ("another request already has the phone ({0}, {1} @ {2}, started {3}, {4}s left) - waiting quietly, no second prompt" -f $codeText, $holder.Agent, $holder.Host, $holder.StartedAtLocal, $left) -ForegroundColor Yellow
            }
            Start-Sleep -Seconds 2
            continue
        }

        if ($holder) {
            # the deadline lapsed: either the holder crashed, or it is in its
            # last seconds (it still deletes its own record when it finishes).
            # the grace window keeps a live holder from losing its own turn.
            if ($holder.State -eq 'approved') {
                # the previous request succeeded and held the turn only while
                # its caller wrote session.key. that state is terminal, so it
                # is safe to reuse the slot right away.
                $null = Remove-VaultApprovalLock -Path $path -Token $holder.Token
            } elseif ($holder.ExpiresAtUnix -le ($nowUnix - $script:VaultApprovalLockGraceSeconds)) {
                if (Remove-VaultApprovalLock -Path $path -Token $holder.Token) {
                    Write-MainframeWarning ("taking over the expired phone approval ({0} from {1} @ {2}, started {3}) - this request is now the one asking" -f $(if ($holder.Code) { "code [$($holder.Code)]" } else { 'no code' }), $holder.Agent, $holder.Host, $holder.StartedAtLocal)
                }
            }
            Start-Sleep -Seconds 1
            continue
        }

        $token = [guid]::NewGuid().ToString('N')
        $startedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $expiresAt = $startedAt + [Math]::Max(30, $TimeoutSeconds) + $script:VaultApprovalLockMarginSeconds
        $record = [ordered]@{
            token     = $token
            pid       = $PID
            host      = $HostName
            context   = $PromptContext
            agent     = $Agent
            model     = $Model
            state     = 'pending'
            code      = ''
            sid       = ''
            startedAt = $startedAt
            expiresAt = $expiresAt
        }
        if (Write-VaultApprovalLockFile -Path $path -Data $record) {
            if ($waited) {
                Write-Host 'the earlier request is gone - this request now asks the phone' -ForegroundColor Cyan
            }
            return [pscustomobject]@{
                Acquired      = $true
                AlreadyUnlocked = $false
                Path          = $path
                Token         = $token
                StartedAtUnix = $startedAt
                ExpiresAtUnix = $expiresAt
            }
        }
        # somebody else created it first; loop and wait on them
        Start-Sleep -Milliseconds 200
    }
}

function Close-VaultApprovalRequest {
    <#
    .SYNOPSIS
        give the turn back. -Approved keeps it for a moment, because the caller
        still has to run `bw unlock` and write session.key - a waiter that
        grabbed the turn in that gap would push a second prompt.
    #>
    param(
        [string]$Path,
        [string]$Token,
        [switch]$Approved
    )

    if (-not $Path -or -not $Token) { return }
    $current = Read-VaultApprovalLock -Path $Path
    if (-not $current) { return }
    if ($current.Token -ne $Token) {
        # our record lapsed while we were still waiting; whoever took over owns
        # the file now, so leave it (and say so - this is not normal).
        Write-MainframeWarning "the approval lock at $Path was taken over by another request while this one was still running - leaving it alone"
        return
    }

    if ($Approved) {
        $current.Data.state = 'approved'
        $current.Data.expiresAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + $script:VaultApprovalLockSettleSeconds
        try {
            [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $current.Data -Compress))
            return
        } catch {
            Write-MainframeWarning "could not mark the approval lock as resolved - releasing it now: $_"
        }
    }
    $null = Remove-VaultApprovalLock -Path $Path -Token $Token
}

function Get-VaultMasterPassword {
    [CmdletBinding()]
    param(
        [string]$NtfyTopic = $null,
        [string]$PromptContext = "vault access",
        [int]$TimeoutSeconds = 300,
        [string]$Agent = $null,
        [string]$Model = $null,
        [string]$HostName = $env:COMPUTERNAME,
        [DateTime]$StartTimeUtc = [DateTime]::MinValue,
        [string]$Server = $null,
        [string]$PagesBase = $null,
        [int]$QueueTimeoutSeconds = 0
    )

    # Resolve ntfy topic
    if (-not $NtfyTopic) {
        $NtfyTopic = Get-VaultNtfyTopic
    }
    $resolvedServer = Get-VaultNtfyServer -Server $Server

    # A call means "the caller believes the vault is locked". Freshness is
    # measured from here, so a session another agent writes while we queue
    # reads as "already unlocked" instead of as a reason to ask again.
    if ($StartTimeUtc -eq [DateTime]::MinValue) {
        $StartTimeUtc = [DateTime]::UtcNow
    }

    # Single flight: one prompt on the phone, everybody else waits for it.
    $turn = Enter-VaultApprovalRequest -PromptContext $PromptContext -TimeoutSeconds $TimeoutSeconds `
        -Agent $Agent -Model $Model -HostName $HostName -SinceUtc $StartTimeUtc `
        -QueueTimeoutSeconds $QueueTimeoutSeconds
    if ($turn.AlreadyUnlocked) {
        return '__SESSION_ALREADY_UNLOCKED__'
    }

    $approved = $false
    $rsa = $null
    try {
        $rsa = [System.Security.Cryptography.RSA]::Create(2048)
        $session = Get-VaultApprovalUrl -Rsa $rsa -PromptContext $PromptContext -HostName $HostName -Agent $Agent -Model $Model -ExpiresInSeconds $TimeoutSeconds -Server $resolvedServer -PagesBase $PagesBase
        $url = $session.Url
        $sid = $session.Sid
        $code = $session.Code
        $resolvedAgent = $session.Agent
        $resolvedModel = $session.Model
        # The wake-up push goes to the topic the phone listens on, the answer
        # comes back to the single-use sid topic.
        $null = Set-VaultApprovalRequestDetails -Path $turn.Path -Token $turn.Token -Code $code -Sid $sid

        $callerDisplay = if ($resolvedModel) { "$resolvedAgent ($resolvedModel) @ $HostName" } else { "$resolvedAgent @ $HostName" }

        Write-Host "`n==> 1-tap mobile approval for $PromptContext" -ForegroundColor Cyan
        Write-Host "==================================================" -ForegroundColor Green
        Write-Host "  VERIFICATION CODE: [ $code ]" -ForegroundColor Green
        Write-Host "  Caller: $callerDisplay" -ForegroundColor White
        Write-Host "  Context: $PromptContext" -ForegroundColor Gray
        Write-Host "  (Ensure the number on your phone matches $code)" -ForegroundColor Yellow
        Write-Host "==================================================" -ForegroundColor Green
        # the full URL carries k/sid/code - it lands in transcripts and logs,
        # so it only prints with -Verbose (L19). the phone gets it via the
        # push, not the terminal.
        Write-Verbose "approval url: $url"

        if ($NtfyTopic) {
            $sent = Send-VaultApprovalNotification -Topic $NtfyTopic -Url $url -Code $code -PromptContext $PromptContext -HostName $HostName -Agent $resolvedAgent -Model $resolvedModel -Server $resolvedServer
            if ($sent) {
                Write-Host "push notification sent (ntfy topic $(Get-NtfyTopicFingerprint -Topic $NtfyTopic))" -ForegroundColor Green
            } else {
                # rule 8: no silent degradation. without the push the phone
                # never hears about this request, so waiting would burn the
                # whole timeout and fail for a reason nobody was told about.
                throw "phone approval push failed, so the phone was never notified. the request was NOT sent to the relay at $resolvedServer. check the relay (a 429 here means the ntfy rate limit is tripped - another pending approval polling every 2s is usually the cause). no approval can arrive now."
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
            # the caller runs `bw unlock` next; keep the turn a little longer so
            # no queued waiter beats it to a second prompt.
            $approved = $true
            # the runner only ever sees ciphertext: it cannot know whether the
            # phone side tapped fingerprint or typed the password, so the log
            # must not claim a method. (2026-11-15: this line used to say
            # "via 1-tap biometric approval" unconditionally, and two approvals
            # were misreported as fingerprint when the user had typed.)
            Write-Host "password decrypted successfully" -ForegroundColor Green
            try {
                $accountsDir = Join-Path (Get-MainframeAccountsDir) 'bitwarden'
                if (-not (Test-Path -LiteralPath $accountsDir)) {
                    $null = New-Item -ItemType Directory -Force -Path $accountsDir -ErrorAction SilentlyContinue
                }
                $lastApprovalFile = Join-Path $accountsDir 'last-approval.json'
                $lastApproval = [ordered]@{
                    at      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
                    agent   = $resolvedAgent
                    model   = $resolvedModel
                    context = $PromptContext
                    host    = $HostName
                    code    = $code
                    state   = 'approved'
                }
                # 0600 via the private-file write: the record carries the
                # approval code (L11).
                Write-MainframePrivateFile -Path $lastApprovalFile -Content ($lastApproval | ConvertTo-Json -Compress) | Out-Null
            } catch {}
            return $pw
        } else {
            $null = Send-VaultRequestExpired -Sid $sid -HostName $HostName -Code $code -Server $resolvedServer
            Write-MainframeWarning "phone approval timed out after $TimeoutSeconds seconds."
            return $null
        }
    } finally {
        if ($rsa) { $rsa.Dispose() }
        # the turn is always given back: on a password, on a timeout, on a
        # failed push, and on a throw. a queue never stalls behind a dead run.
        Close-VaultApprovalRequest -Path $turn.Path -Token $turn.Token -Approved:$approved
    }
}

Export-ModuleMember -Function `
    Get-CallerIdentity, `
    Get-MiniMaxSessionId, `
    Get-MiniMaxModelFromDisk, `
    Get-VaultConfigValue, `
    Get-VaultNtfyTopic, `
    Get-VaultNtfyServer, `
    Get-VaultPagesBase, `
    ConvertTo-SubjectPublicKeyInfo, `
    ConvertTo-SubjectPublicKeyInfoManual, `
    Get-VaultApprovalUrl, `
    Get-VaultApprovalSigningKey, `
    New-VaultApprovalSigningKeyFile, `
    Get-VaultApprovalSigningKeyPath, `
    Get-VaultApprovalPublicKey, `
    Get-VaultApprovalLinkSigningKeyPath, `
    Get-VaultApprovalLinkSigningKey, `
    Get-VaultApprovalLinkPayload, `
    Get-VaultApprovalLinkSignature, `
    Sync-VaultApprovalSigningKeyFromVault, `
    Get-NtfyTopicFingerprint, `
    Select-VaultApprovalCiphertext, `
    Send-VaultApprovalNotification, `
    Send-VaultRequestExpired, `
    Open-VaultApprovalOnPhone, `
    Test-VaultApprovalCiphertext, `
    Wait-VaultApprovalCiphertext, `
    Decrypt-VaultApprovalCiphertext, `
    Get-VaultApprovedTtlMinutes, `
    Get-VaultMasterPassword, `
    Get-VaultApprovalLockPath, `
    Read-VaultApprovalLock, `
    Enter-VaultApprovalRequest, `
    Close-VaultApprovalRequest, `
    Test-VaultSessionKeyFresh, `
    Get-MainframeProfileRoot, `
    Get-MainframeAccountsDir, `
    Get-MainframeAccountDir, `
    Get-MainframeSessionKeyPath, `
    Get-MainframeCheckoutRoot
