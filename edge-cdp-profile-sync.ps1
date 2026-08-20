param(
    [Parameter(Mandatory=$true)]
    [string]$Email,
    [switch]$SkipVerify
)

$ErrorActionPreference = 'Stop'

# real Edge user-data-dir (the daily-driver, fully logged-in, all extensions)
$edgeUserData = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data'
if (-not (Test-Path -LiteralPath $edgeUserData -PathType Container)) {
    throw "Edge User Data not found: $edgeUserData"
}

# mainframe agent-browser profile dir (email-keyed dir IS the chromium --user-data-dir for spawn mode)
$accountRoot = Join-Path $env:APPDATA 'mainframe\accounts\agent-browser'
$profilePath = Join-Path $accountRoot $Email.ToLowerInvariant()
if ($Email -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') {
    throw "Email must look like an email: $Email"
}

# close any running agent-browser daemon first so it's not holding the profile dir open
# when we wipe it (otherwise the next `open` says "relaunched browser" and leaves
# inconsistent state that breaks subsequent runs).
try {
    $agentBrowserExe = (Get-Command agent-browser -ErrorAction SilentlyContinue).Source
    if (-not $agentBrowserExe) {
        $candidate = Join-Path $env:APPDATA 'npm\agent-browser.cmd'
        if (Test-Path $candidate) { $agentBrowserExe = $candidate }
    }
    if ($agentBrowserExe) { & $agentBrowserExe close --all 2>$null | Out-Null }
} catch {}

    # === VSS snapshot path: copy Edge User Data from a Volume Shadow Copy so we
    # DO NOT need to close real Edge and we DO NOT skip any locked files (Local State,
    # Cookies, Preferences, Session Storage, etc.). this is the only way to get a
    # 100% byte-consistent copy while Edge is alive — robocopy alone can't read files
    # that Edge holds with exclusive write handles (ERROR 32 / sharing violation).
    #
    # VSS is the only supported path. there is NO fallback — if the shadow cannot be
    # created or mounted, the sync aborts. closing the user's real Edge as a fallback
    # is intentionally removed; running with a non-VSS robocopy silently skips locked
    # files (Cookies, Local State, Preferences, Session Storage) and produces a
    # corrupt profile.
    $shadowDevice = $null
    $vssLink = $null
    try {
        $mc = New-Object System.Management.ManagementClass(
            [System.Management.ManagementScope]::new('\\.\root\cimv2'),
            [System.Management.ManagementPath]::new('Win32_ShadowCopy'),
            $null)
        $inParams = $mc.GetMethodParameters('Create')
        $inParams['Volume']  = 'C:\'
        $inParams['Context'] = 'ClientAccessible'
        $outParams = $mc.InvokeMethod('Create', $inParams, $null)
        if ($outParams.ReturnValue -ne 0) {
            throw "Win32_ShadowCopy.Create returned error code $($outParams.ReturnValue) (7=not supported, 8=volume not found, 12=max snapshots exceeded) — usually means this shell is not elevated"
        }
        $shadowId = $outParams.ShadowID
        $shadow = Get-CimInstance -ClassName Win32_ShadowCopy | Where-Object { $_.Id -eq $shadowId } | Select-Object -First 1
        if (-not $shadow) { throw "shadow created (ID=$shadowId) but not returned by Win32_ShadowCopy query" }
        $shadowDevice = $shadow.DeviceObject
        Write-Host "[edge-cdp-sync] VSS shadow created: $shadowDevice" -ForegroundColor Cyan
    } catch {
        throw "[edge-cdp-sync] VSS snapshot unavailable ($($_.Exception.Message)) — needs admin + VSS enabled (ClientAccessible shadow copy). no fallback."
    }

    # device path is \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopyN
    # robocopy can NOT read \\?\GLOBALROOT\... device paths directly — those are
    # kernel-object namespace paths only. the workaround that works on every Win10+:
    # create a directory symlink with `cmd /c mklink /d` pointing at the shadow root
    # (the trailing backslash on the target is what makes mklink accept it), then use
    # that normal Win32 symlink path as the robocopy source.
    $vssLink = Join-Path $env:TEMP "edge-cdp-vss-$([Guid]::NewGuid().ToString('N'))"
    try {
        $mkOut = cmd /c mklink /d "$vssLink" "$shadowDevice\" 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $vssLink -PathType Container)) {
            throw "mklink /d failed (exit=$LASTEXITCODE, output=$mkOut)"
        }
        $pathAfterDrive = $edgeUserData -replace '^[A-Za-z]:\\',''
        $edgeUserDataShadow = Join-Path $vssLink $pathAfterDrive
        if (-not (Test-Path -LiteralPath $edgeUserDataShadow -PathType Container)) {
            throw "VSS symlink created but couldn't resolve $edgeUserDataShadow"
        }
        $edgeUserData = $edgeUserDataShadow
        Write-Host "[edge-cdp-sync] using VSS shadow: $shadowDevice (real Edge left running)" -ForegroundColor Cyan
    } catch {
        # drop the shadow before aborting so we don't leak it
        try {
            $shadows = Get-CimInstance -ClassName Win32_ShadowCopy | Where-Object { $_.DeviceObject -eq $shadowDevice }
            $shadows | Remove-CimInstance -ErrorAction SilentlyContinue
        } catch {}
        if (Test-Path -LiteralPath $vssLink) { Remove-Item -LiteralPath $vssLink -Force -Recurse -ErrorAction SilentlyContinue }
        throw "[edge-cdp-sync] VSS shadow mounted but mklink/resolution failed: $($_.Exception.Message). no fallback."
    }

New-Item -ItemType Directory -Force -Path $profilePath | Out-Null

# preserve mainframe-profile.json across the fresh copy (it holds extensions list),
# and the agent-browser state/restore files (sessions/, persisted state).
$preservedFiles = @(
    'mainframe-profile.json'
)
$preservedDirs = @(
    'mainframe-sessions',
    'sessions'
)

# stage preserved items into a temp dir, then restore after robocopy
$stagingDir = Join-Path $env:TEMP "edge-cdp-sync-staging-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $stagingDir | Out-Null

foreach ($f in $preservedFiles) {
    $src = Join-Path $profilePath $f
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination (Join-Path $stagingDir $f) -Force
    }
}
foreach ($d in $preservedDirs) {
    $src = Join-Path $profilePath $d
    if (Test-Path -LiteralPath $src -PathType Container) {
        Copy-Item -LiteralPath $src -Destination (Join-Path $stagingDir $d) -Recurse -Force
    }
}

# DO NOT wipe the destination — let robocopy /MIR delta-sync against the existing
# copy so subsequent syncs only re-copy changed files (Cookies, Local State,
# Preferences, etc.) instead of re-copying ~370 MB every time. /MIR already
# deletes dest files that aren't in source (pruned extensions, session leftover
# state), so the wipe was redundant and only defeated the delta optimization.
New-Item -ItemType Directory -Force -Path $profilePath | Out-Null

# robocopy exclude list — mirrors backup.ps1's Edge profile workflow
# (caches, telemetry, edge component dirs, isolated leveldb blobs, history, db temps)
$excludeDirs = @(
    'Cache', 'Code Cache', 'GPUCache', 'Service Worker',
    'DawnGraphiteCache', 'DawnWebGPUCache', 'GrShaderCache', 'ShaderCache', 'GraphiteDawnCache',
    'blob_storage', 'Crashpad', 'component_crx_cache', 'ProvenanceData', 'Subresource Filter',
    'BrowserMetrics', 'Safe Browsing', 'Shared Dictionary', 'File System', 'logs', '*.blob',
    'Edge Entity Extraction', 'Edge Shopping', 'Edge Wallet', 'EdgeCoupons',
    'EdgeLanguageDetectionModel', 'Edge Sidebar', 'EdgeTravel', 'EdgeCDSScheduler',
    'EdgePushNotificationClient', 'EdgeDrop', 'EdgeCollections', 'EdgeTrackingPrevention',
    'EdgeFavoritesBackup',
    'https_photos.google.com_0.indexeddb.leveldb',
    'https_www.messenger.com_0.indexeddb.leveldb',
    'https_www.facebook.com_0.indexeddb.leveldb',
    'https_www.reddit.com_0.indexeddb.leveldb',
    # also exclude the staging dir if it somehow matches
    'edge-cdp-sync-staging-*'
)
$excludeFiles = @(
    'History', 'load_statistics.db',
    '*.db-journal', '*.db-wal', '*.db-shm'
)

# /MIR mirrors the source (deletes files in dest that aren't in source) — that's what we want for a fresh copy.
# /XJ excludes junction points (we don't want to follow / duplicate them into the copy).
$roboArgs = @(
    $edgeUserData, $profilePath,
    '/E', '/COPYALL', '/R:1', '/W:1', '/NP', '/NDL', '/NFL', '/XJ', '/MIR',
    '/XD') + $excludeDirs + @('/XF') + $excludeFiles

$roboLog = Join-Path $env:TEMP "edge-cdp-sync-robocopy-$(Get-Random).log"
$roboArgs += "/LOG:$roboLog"

Write-Host "[edge-cdp-sync] robocopy $edgeUserData -> $profilePath" -ForegroundColor Cyan
$null = robocopy @roboArgs
$rcExit = $LASTEXITCODE

$skipped = @()
if (Test-Path -LiteralPath $roboLog) {
    $logContent = Get-Content -LiteralPath $roboLog -Raw -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $roboLog -Force -ErrorAction SilentlyContinue
    if ($logContent) {
        foreach ($m in [regex]::Matches($logContent, 'ERROR \d+ \(0x[0-9A-Fa-f]+\) Copying File\s+([^\r\n]+)')) {
            $skipped += $m.Groups[1].Value.Trim()
        }
    }
}
# robocopy exit codes <=7 are success-ish (copied some files, possibly with skipped locked files)
if ($rcExit -ge 16) {
    if ($shadowDevice) {
        try {
            $shadows = Get-CimInstance -ClassName Win32_ShadowCopy | Where-Object { $_.DeviceObject -eq $shadowDevice }
            $shadows | Remove-CimInstance -ErrorAction SilentlyContinue
            Write-Host "[edge-cdp-sync] VSS shadow dropped (post-failure)" -ForegroundColor DarkGray
        } catch {}
    }
    if ($vssLink -and (Test-Path -LiteralPath $vssLink)) {
        Remove-Item -LiteralPath $vssLink -Force -Recurse -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
    throw "[edge-cdp-sync] robocopy failed (exit $rcExit). see log above."
}

# restore preserved items
foreach ($f in $preservedFiles) {
    $src = Join-Path $stagingDir $f
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination (Join-Path $profilePath $f) -Force
    }
}
foreach ($d in $preservedDirs) {
    $src = Join-Path $stagingDir $d
    if (Test-Path -LiteralPath $src -PathType Container) {
        Remove-Item -LiteralPath (Join-Path $profilePath $d) -Recurse -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath $src -Destination (Join-Path $profilePath $d) -Recurse -Force
    }
}
Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue

# === repair extension install-signature state in the copy ===
# Edge, when launched with --remote-debugging-port, runs in "dev mode" and re-verifies
# every extension's install signature. extensions installed from the Edge Add-ons
# store or sideloaded (from_webstore=false / location=1 in real Edge) don't pass that
# check, and Edge disables them with disable_reasons=1024 (DISABLE_NOT_VERIFIED),
# shown in the UI as "corrupted". over successive runs, Edge also writes partial
# stubs for those IDs into Default\Secure Preferences (an entry with only
# disable_reasons=[1024]+needs_sync and no manifest/path/version), which then look
# even more broken on the next launch.
#
# fix: while the VSS shadow of real Edge is still mounted, copy real Edge's
# Default\Preferences and Default\Secure Preferences verbatim over the copy (these
# are exactly what Edge signed at install time). then re-apply the post-robocopy
# invariants: drop corrupted_disable_count, drop the install_signature ID lists
# (so Edge's signature verifier has nothing to compare against - equivalent to a
# freshly-installed profile where every extension was added by the user), and
# strip any extensions.settings.<id> stub in Secure Preferences that lacks the
# full manifest/path/version fields a real install has.
#
# this MUST run before the VSS shadow is dropped, since we read the original files
# from the shadow path.
$repairErrors = @()
foreach ($file in 'Default\Preferences','Default\Secure Preferences') {
    $realFile = Join-Path $edgeUserData $file
    $copyFile = Join-Path $profilePath $file
    if (Test-Path -LiteralPath $realFile) {
        try {
            Copy-Item -LiteralPath $realFile -Destination $copyFile -Force
        } catch {
            $repairErrors += "copy $file : $($_.Exception.Message)"
        }
    }
}

try {
    $prefPath = Join-Path $profilePath 'Default\Preferences'
    if (Test-Path -LiteralPath $prefPath) {
        $pref = Get-Content -LiteralPath $prefPath -Raw | ConvertFrom-Json -AsHashtable
        if ($pref.extensions -is [hashtable]) {
            $pref.extensions.Remove('corrupted_disable_count') | Out-Null
            if ($pref.extensions.ContainsKey('install_signature') -and $pref.extensions.install_signature -is [hashtable]) {
                $pref.extensions.install_signature['ids'] = @()
                $pref.extensions.install_signature['invalid_ids'] = @()
            }
            if ($pref.extensions.ContainsKey('microsoft_install_signature') -and $pref.extensions.microsoft_install_signature -is [hashtable]) {
                $pref.extensions.microsoft_install_signature['ids'] = @()
                $pref.extensions.microsoft_install_signature['invalid_ids'] = @()
            }
        }
        ($pref | ConvertTo-Json -Depth 100) | Set-Content -LiteralPath $prefPath -Encoding UTF8
    }
} catch {
    $repairErrors += "patch Preferences: $($_.Exception.Message)"
}

try {
    $secPath = Join-Path $profilePath 'Default\Secure Preferences'
    if (Test-Path -LiteralPath $secPath) {
        $sec = Get-Content -LiteralPath $secPath -Raw | ConvertFrom-Json -AsHashtable
        if ($sec.ContainsKey('extensions') -and $sec.extensions.ContainsKey('settings') -and $sec.extensions.settings -is [hashtable]) {
            $settings = $sec.extensions.settings
            $removed = @()
            foreach ($id in @($settings.Keys)) {
                $entry = $settings[$id]
                if (-not ($entry -is [hashtable])) { continue }
                $hasManifest  = $entry.ContainsKey('manifest')  -and $entry.manifest
                $hasPath      = $entry.ContainsKey('path')      -and $entry.path
                $hasLocation  = $entry.ContainsKey('location')  -and $null -ne $entry.location
                if (-not $hasManifest -and -not $hasPath -and -not $hasLocation) {
                    $settings.Remove($id) | Out-Null
                    $removed += $id
                } elseif ($entry.ContainsKey('disable_reasons') -and $entry.disable_reasons) {
                    $entry['disable_reasons'] = @()
                }
            }
            if ($removed.Count -gt 0) {
                Write-Host "[edge-cdp-sync] dropped $($removed.Count) extension stub(s) from Secure Preferences" -ForegroundColor Cyan
            }
            ($sec | ConvertTo-Json -Depth 100) | Set-Content -LiteralPath $secPath -Encoding UTF8
        }
    }
} catch {
    $repairErrors += "patch Secure Preferences: $($_.Exception.Message)"
}

if ($repairErrors.Count -gt 0) {
    Write-Warning "[edge-cdp-sync] extension-signature repair partial: $($repairErrors -join '; ')"
}

if (-not $SkipVerify) {
    $localState = Test-Path -LiteralPath (Join-Path $profilePath 'Local State')
    $extensionsPath = Join-Path $profilePath 'Default\Extensions'
    $extCount = if (Test-Path -LiteralPath $extensionsPath) { (Get-ChildItem -LiteralPath $extensionsPath -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'Temp' } | Measure-Object).Count } else { 0 }
    $cookiesPath = Join-Path $profilePath 'Default\Network\Cookies'
    $hasCookies = Test-Path -LiteralPath $cookiesPath
    $cookiesSize = if ($hasCookies) { (Get-Item -LiteralPath $cookiesPath).Length } else { 0 }
    $sizeMB = [math]::Round((Get-ChildItem -LiteralPath $profilePath -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB, 2)

    Write-Host "[edge-cdp-sync] sync complete" -ForegroundColor Green
    Write-Host "  source: $edgeUserData"
    Write-Host "  dest:   $profilePath"
    Write-Host "  size:   $sizeMB MB"
    Write-Host "  Local State:        $localState"
    Write-Host "  Extensions dir:     $extCount"
    Write-Host "  Network\Cookies:    $hasCookies ($cookiesSize bytes)"
    if ($skipped.Count -gt 0) {
        Write-Warning "  skipped (locked): $($skipped.Count) files"
    }
}

if ($shadowDevice) {
    try {
        $shadows = Get-CimInstance -ClassName Win32_ShadowCopy | Where-Object { $_.DeviceObject -eq $shadowDevice }
        $shadows | Remove-CimInstance -ErrorAction SilentlyContinue
        Write-Host "[edge-cdp-sync] VSS shadow dropped (post-success)" -ForegroundColor DarkGray
    } catch {}
}
if ($vssLink -and (Test-Path -LiteralPath $vssLink)) {
    Remove-Item -LiteralPath $vssLink -Force -Recurse -ErrorAction SilentlyContinue
}

return $profilePath
