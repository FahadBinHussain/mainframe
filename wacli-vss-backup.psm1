Set-StrictMode -Version Latest

function Add-WacliVssCandidate {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Candidates,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Role
    )

    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    if (-not [System.IO.Path]::IsPathRooted($expanded)) {
        throw "WACLI $Role path is not absolute; backup cannot prove its source root."
    }
    $full = [System.IO.Path]::GetFullPath($expanded)
    if (Test-Path -LiteralPath $full -PathType Leaf) {
        $full = Split-Path -Parent $full
    }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        throw "Required WACLI $Role root is missing or unavailable."
    }

    $Candidates.Add([pscustomobject]@{ Path = $full; Role = $Role })
}

function Find-WacliMetadataPathReferences {
    param(
        [AllowNull()][object]$Value,
        [string]$PropertyName = '',
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$References
    )

    if ($null -eq $Value) { return }
    if ($Value -is [string]) {
        if ($PropertyName -match '(?i)(media|config|store).*(path|root|dir)|(?:path|root|dir).*(media|config|store)') {
            if (-not [string]::IsNullOrWhiteSpace($Value)) {
                $role = if ($PropertyName -match '(?i)media') { 'referenced-media' }
                        elseif ($PropertyName -match '(?i)config') { 'config' }
                        else { 'metadata-store' }
                $References.Add([pscustomobject]@{ Path = $Value; Role = $role })
            }
        }
        return
    }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            Find-WacliMetadataPathReferences -Value $Value[$key] -PropertyName ([string]$key) -References $References
        }
        return
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        foreach ($property in $Value.PSObject.Properties) {
            Find-WacliMetadataPathReferences -Value $property.Value -PropertyName $property.Name -References $References
        }
        return
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($item in $Value) {
            Find-WacliMetadataPathReferences -Value $item -PropertyName $PropertyName -References $References
        }
    }
}

function Test-WacliPathWithin {
    param([string]$Parent, [string]$Child)
    $separator = [System.IO.Path]::DirectorySeparatorChar
    $parentPath = [System.IO.Path]::GetFullPath($Parent).TrimEnd([char[]]@('\', '/'))
    $childPath = [System.IO.Path]::GetFullPath($Child).TrimEnd([char[]]@('\', '/'))
    if ([string]::Equals($parentPath, $childPath, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $childPath.StartsWith($parentPath + $separator, [StringComparison]::OrdinalIgnoreCase)
}

function Get-WacliVssInputs {
    [CmdletBinding()]
    param(
        [string]$AppDataRoot = $env:APPDATA,
        [string]$UserProfileRoot = $env:USERPROFILE
    )

    $candidates = [System.Collections.Generic.List[object]]::new()
    $metadataFiles = [System.Collections.Generic.List[object]]::new()
    $profileRoot = if ($AppDataRoot) { Join-Path (Join-Path (Join-Path $AppDataRoot 'mainframe') 'accounts') 'whatsapp' } else { $null }

    if ($profileRoot -and (Test-Path -LiteralPath $profileRoot -PathType Container)) {
        Add-WacliVssCandidate -Candidates $candidates -Path $profileRoot -Role 'profiles-and-profile-config'
        $profiles = @(Get-ChildItem -LiteralPath $profileRoot -Directory -Force -ErrorAction Stop)
        foreach ($profile in $profiles) {
            $profileStore = Join-Path $profile.FullName 'store'
            $metadataPath = Join-Path $profile.FullName 'mainframe-whatsapp.json'
            $metadata = $null
            if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
                try {
                    $raw = Get-Content -LiteralPath $metadataPath -Raw -ErrorAction Stop
                    $metadata = ConvertFrom-Json -InputObject $raw -ErrorAction Stop
                } catch {
                    throw "WACLI profile metadata is unreadable or invalid; backup stopped."
                }
                $metadataFiles.Add([pscustomobject]@{ Path = $metadataPath; Sha256 = (Get-FileHash -LiteralPath $metadataPath -Algorithm SHA256 -ErrorAction Stop).Hash })
            }

            $storePath = $null
            if ($metadata -and $metadata.PSObject.Properties['storePath']) {
                $storePath = [string]$metadata.storePath
            }
            if (Test-Path -LiteralPath $profileStore -PathType Container) {
                Add-WacliVssCandidate -Candidates $candidates -Path $profileStore -Role 'profile-store'
            } elseif ($metadata -and $metadata.kind -eq 'wacli' -and [string]::IsNullOrWhiteSpace($storePath)) {
                throw 'Required WACLI profile store is missing or unavailable.'
            }
            if (-not [string]::IsNullOrWhiteSpace($storePath)) {
                Add-WacliVssCandidate -Candidates $candidates -Path $storePath -Role 'metadata-store'
            }

            if ($metadata) {
                $references = [System.Collections.Generic.List[object]]::new()
                Find-WacliMetadataPathReferences -Value $metadata -References $references
                foreach ($reference in $references) {
                    Add-WacliVssCandidate -Candidates $candidates -Path ([string]$reference.Path) -Role ([string]$reference.Role)
                }
            }
        }
    }

    $legacyStore = if ($UserProfileRoot) { Join-Path $UserProfileRoot '.wacli' } else { $null }
    if ($legacyStore -and (Test-Path -LiteralPath $legacyStore -PathType Container)) {
        Add-WacliVssCandidate -Candidates $candidates -Path $legacyStore -Role 'legacy-wacli-store'
    }

    if ($candidates.Count -eq 0) {
        return [pscustomobject]@{ HasState = $false; ProfileRoot = $profileRoot; Roots = @(); MetadataFiles = @(); MediaReferenceCoverage = 'not-applicable' }
    }

    # Collapse nested/duplicate roots only after all referenced roots have been
    # validated. A containing profile root still preserves its store and config.
    $ordered = @($candidates | Sort-Object { $_.Path.Length }, { $_.Path.ToUpperInvariant() })
    $roots = [System.Collections.Generic.List[object]]::new()
    foreach ($candidate in $ordered) {
        $existing = $null
        foreach ($root in $roots) {
            if (Test-WacliPathWithin -Parent $root.Path -Child $candidate.Path) { $existing = $root; break }
        }
        if ($existing) {
            if ($existing.Roles -notcontains $candidate.Role) { $existing.Roles += $candidate.Role }
            continue
        }
        $roles = @($candidate.Role)
        foreach ($root in @($roots)) {
            if (Test-WacliPathWithin -Parent $candidate.Path -Child $root.Path) {
                $roles += $root.Roles
                $null = $roots.Remove($root)
            }
        }
        $roots.Add([pscustomobject]@{ Path = $candidate.Path; Roles = @($roles | Sort-Object -Unique) })
    }

    $indexed = @()
    for ($i = 0; $i -lt $roots.Count; $i++) {
        $indexed += [pscustomobject]@{ Id = "root$i"; Path = $roots[$i].Path; Roles = @($roots[$i].Roles) }
    }
    return [pscustomobject]@{
        HasState = $true
        ProfileRoot = $profileRoot
        Roots = $indexed
        MetadataFiles = @($metadataFiles)
        # The supported metadata has no contract proving that SQLite-only media
        # references are fully represented by the enumerated roots.
        MediaReferenceCoverage = 'unproven'
    }
}

function Get-WacliVssBackupExecutable {
    [CmdletBinding()]
    param([string]$RepositoryRoot = $PSScriptRoot)

    $cmake = Get-Command cmake -ErrorAction SilentlyContinue
    if (-not $cmake) {
        throw 'WACLI state exists but CMake is unavailable; held-VSS copy cannot run and no live-copy fallback is allowed.'
    }
    $source = Join-Path $RepositoryRoot 'wacli-vss-client'
    $build = Join-Path $env:TEMP 'mainframe-wacli-vss-build'
    & $cmake.Source -S $source -B $build | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "WACLI native VSS helper configuration failed (exit $LASTEXITCODE)." }
    & $cmake.Source --build $build --config Release --target wacli_vss_backup --parallel 2 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "WACLI native VSS helper build failed (exit $LASTEXITCODE)." }
    foreach ($candidate in @(
        (Join-Path $build 'wacli_vss_backup.exe'),
        (Join-Path $build 'Release\wacli_vss_backup.exe')
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    throw 'WACLI native VSS helper build completed without its expected executable.'
}

function Invoke-WacliVssCopy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Inputs,
        [Parameter(Mandatory)][string]$DestinationRoot,
        [string]$RepositoryRoot = $PSScriptRoot
    )

    if (-not $Inputs.HasState -or @($Inputs.Roots).Count -eq 0) {
        throw 'WACLI VSS copy was requested without any enumerated source roots.'
    }
    $coverageProperty = $Inputs.PSObject.Properties['MediaReferenceCoverage']
    if (-not $coverageProperty -or [string]$coverageProperty.Value -ne 'proven-complete') {
        throw 'WACLI VSS backup is blocked: external-media completeness is unproven. Supported profile metadata cannot enumerate every media path referenced only inside SQLite, and database inspection is unsupported; no WACLI payload will be produced.'
    }
    if (Test-Path -LiteralPath $DestinationRoot) {
        throw 'WACLI VSS destination already exists; refusing to overwrite it.'
    }
    $exe = Get-WacliVssBackupExecutable -RepositoryRoot $RepositoryRoot
    $payload = Join-Path $DestinationRoot 'payload'
    $arguments = [System.Collections.Generic.List[string]]::new()
    $arguments.Add('--parent'); $arguments.Add($DestinationRoot)
    $arguments.Add('--destination'); $arguments.Add($payload)
    foreach ($root in $Inputs.Roots) {
        $arguments.Add('--root'); $arguments.Add([string]$root.Path)
    }

    $destinationCreated = $false
    try {
        New-Item -ItemType Directory -Path $DestinationRoot -ErrorAction Stop | Out-Null
        $destinationCreated = $true
        & $exe @($arguments.ToArray())
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            throw "Held-VSS WACLI copy failed (exit $exitCode); no live-copy fallback was attempted."
        }
        for ($i = 0; $i -lt @($Inputs.Roots).Count; $i++) {
            $stagedRoot = Join-Path $payload "root$i"
            if (-not (Test-Path -LiteralPath $stagedRoot -PathType Container)) {
                throw "Held-VSS WACLI copy omitted required root root$i."
            }
        }

        foreach ($metadata in $Inputs.MetadataFiles) {
            $containingRoot = @($Inputs.Roots | Where-Object { Test-WacliPathWithin -Parent $_.Path -Child $metadata.Path } | Sort-Object { $_.Path.Length } | Select-Object -First 1)
            if ($containingRoot.Count -ne 1) { throw 'WACLI metadata file is not covered by the enumerated VSS roots.' }
            $rootIndex = [array]::IndexOf(@($Inputs.Roots.Path), [string]$containingRoot[0].Path)
            $relative = [System.IO.Path]::GetRelativePath([string]$containingRoot[0].Path, [string]$metadata.Path)
            $copiedMetadata = Join-Path (Join-Path $payload "root$rootIndex") $relative
            if (-not (Test-Path -LiteralPath $copiedMetadata -PathType Leaf) -or
                (Get-FileHash -LiteralPath $copiedMetadata -Algorithm SHA256 -ErrorAction Stop).Hash -ne $metadata.Sha256) {
                throw 'WACLI profile metadata changed across VSS root discovery; copy is incomplete.'
            }
        }

        $manifest = [pscustomobject]@{
            format = 'mainframe-wacli-vss-roots-v1'
            consistency = 'crash-consistent'
            applicationConsistent = $false
            windowsRuntimeValidated = $false
            restoreActivation = 'not-performed'
            sourcePayloadsReadFrom = 'verified-held-vss-shadow-set'
            sqliteSidecars = 'included-byte-for-byte-no-filename-exclusions'
            roots = @($Inputs.Roots | ForEach-Object {
                [pscustomobject]@{ id = $_.Id; archivePath = "payload/$($_.Id)"; sourceRoot = $_.Path; roles = @($_.Roles) }
            })
        }
        $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $DestinationRoot 'root-map.json') -Encoding UTF8
        if (-not (Test-Path -LiteralPath (Join-Path $DestinationRoot 'root-map.json') -PathType Leaf)) {
            throw 'WACLI VSS root map could not be written.'
        }
        Write-Warning 'WACLI state was copied from one writerless VSS set; this is crash-consistent only, not application-consistent or a guarantee of usable state.'
        return $DestinationRoot
    } catch {
        $copyFailure = $_
        if ($destinationCreated -and (Test-Path -LiteralPath $DestinationRoot)) {
            try {
                Remove-Item -LiteralPath $DestinationRoot -Recurse -Force -ErrorAction Stop
            } catch {
                throw "Held-VSS WACLI copy failed and partial-output cleanup also failed: $($copyFailure.Exception.Message); cleanup: $($_.Exception.Message)"
            }
        }
        throw $copyFailure
    }
}

Export-ModuleMember -Function Get-WacliVssInputs, Get-WacliVssBackupExecutable, Invoke-WacliVssCopy, Test-WacliPathWithin
