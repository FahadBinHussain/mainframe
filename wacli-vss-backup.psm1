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
        # Profile metadata alone cannot list media referenced only from SQLite rows,
        # so coverage is established after the copy, from the held-VSS payload.
        MediaReferenceCoverage = 'enumerated-after-copy'
    }
}

function Resolve-WacliSqliteTool {
    [CmdletBinding()]
    param()

    $sqlite = Get-Command sqlite3 -ErrorAction SilentlyContinue
    if (-not $sqlite) {
        throw 'WACLI media-reference enumeration requires sqlite3 on PATH; the WACLI payload was not produced and no live-copy fallback exists.'
    }
    return $sqlite.Source
}

function Get-WacliMediaReferences {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PayloadRoot)

    $sqlite = Resolve-WacliSqliteTool
    $databases = @(Get-ChildItem -LiteralPath $PayloadRoot -File -Recurse -Force -ErrorAction Stop |
        Where-Object { $_.Extension -in @('.db', '.sqlite', '.sqlite3') })
    if ($databases.Count -eq 0) {
        throw 'WACLI payload holds no SQLite database, so media coverage cannot be established; nothing was exported.'
    }

    $paths = [System.Collections.Generic.List[string]]::new()
    $tableCount = 0
    $supportedTables = [System.Collections.Generic.List[string]]::new()
    foreach ($database in $databases) {
        # Enumerate path-bearing columns from the schema itself instead of a
        # hardcoded table list: local_path is the only supported local media
        # column, direct_path is a WhatsApp CDN route, anything else is schema
        # drift that would silently drop coverage.
        #
        # Per-table PRAGMA is deliberate: a single pragma_table_info join walks
        # every table including FTS5 virtual tables, and a sqlite3 build without
        # the fts5 module then dies with "no such module: fts5" even though the
        # ordinary tables are perfectly readable.
        $tableList = @(& $sqlite '-readonly' $database.FullName "SELECT name FROM sqlite_master WHERE type = 'table' AND (sql IS NULL OR sql NOT LIKE 'CREATE VIRTUAL TABLE%') ORDER BY 1;" 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "WACLI database '$($database.Name)' could not be read for media references (exit $LASTEXITCODE); no payload is exported from an unproven database set."
        }
        foreach ($table in $tableList) {
            if ([string]::IsNullOrWhiteSpace($table)) { continue }
            $escapedTable = $table -replace "'", "''"
            $columns = @(& $sqlite '-readonly' $database.FullName "PRAGMA table_info('$escapedTable');" 2>&1)
            if ($LASTEXITCODE -ne 0) {
                throw "WACLI database '$($database.Name)' table '$table' could not be inspected for media references (exit $LASTEXITCODE); media coverage cannot be proven and no payload is exported."
            }
            $pathColumns = @($columns | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { ($_ -split '\|')[1] } | Where-Object { $_ -like '*path*' })
            $unsupported = @($pathColumns | Where-Object { $_ -ne 'local_path' -and $_ -ne 'direct_path' })
            if ($unsupported.Count -gt 0) {
                throw "WACLI database '$($database.Name)' table '$table' exposes unsupported media path column(s): $($unsupported -join ', '). The supported schema is local_path + direct_path only, so media coverage cannot be proven and no payload is exported."
            }
            if ($pathColumns -notcontains 'local_path') { continue }
            $tableCount++
            $supportedTables.Add("$($database.Name).$table")
            $rows = @(& $sqlite '-readonly' $database.FullName "SELECT DISTINCT local_path FROM '$escapedTable' WHERE local_path IS NOT NULL AND local_path <> '';" 2>&1)
            if ($LASTEXITCODE -ne 0) {
                throw "WACLI media reference query failed on '$($database.Name)'.$table (exit $LASTEXITCODE)."
            }
            foreach ($row in $rows) {
                if (-not [string]::IsNullOrWhiteSpace($row)) { $paths.Add($row.Trim()) }
            }
        }
    }
    if ($tableCount -eq 0) {
        throw "WACLI payload exposes no local_path media column in $($databases.Count) SQLite database(s); the schema is not the supported shape, so coverage cannot be proven and no payload is exported."
    }

    return [pscustomobject]@{
        Databases = $databases.Count
        Tables = $tableCount
        TablesScanned = @($supportedTables)
        References = @($paths | Sort-Object -Unique)
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

    # This machine has no MSVC; the supported toolchain is MinGW Makefiles with
    # g++ and make. Fail loudly instead of letting CMake pick the Visual Studio
    # generator and die with a confusing "no usable generator" error.
    $generator = 'MinGW Makefiles'
    $make = Get-Command make -ErrorAction SilentlyContinue
    $compiler = Get-Command g++ -ErrorAction SilentlyContinue
    if (-not $make -or -not $compiler) {
        throw 'WACLI state exists but the native build toolchain is incomplete: the MinGW Makefiles generator needs both make and g++ on PATH (MSVC is not installed on this machine). Held-VSS copy cannot run and no live-copy fallback is allowed.'
    }

    $cacheFile = Join-Path $build 'CMakeCache.txt'
    if (Test-Path -LiteralPath $cacheFile -PathType Leaf) {
        $cachedGenerator = (Select-String -LiteralPath $cacheFile -Pattern '^CMAKE_GENERATOR:INTERNAL=(.+)$' | Select-Object -First 1)
        if ($cachedGenerator -and $cachedGenerator.Matches[0].Groups[1].Value -ne $generator) {
            Write-Warning "WACLI native VSS helper build cache used generator '$($cachedGenerator.Matches[0].Groups[1].Value)'; recreating it with '$generator'."
            Remove-Item -LiteralPath $build -Recurse -Force -ErrorAction Stop
        }
    }

    & $cmake.Source -S $source -B $build -G $generator "-DCMAKE_MAKE_PROGRAM=$($make.Source)" | Out-Host
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
    # Media coverage is no longer assumed from profile metadata: it is resolved
    # from the held-VSS payload right after the copy (see below), where every
    # SQLite media reference is either inside an enumerated root, copied into
    # the payload, or recorded as already missing on this machine.
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

        $media = Get-WacliMediaReferences -PayloadRoot $payload
        $mediaRoot = Join-Path $DestinationRoot 'media'
        $mediaMap = [System.Collections.Generic.List[object]]::new()
        $externalCount = 0
        foreach ($reference in $media.References) {
            $fullReference = [System.IO.Path]::GetFullPath($reference)
            $coveringRoot = @($Inputs.Roots | Where-Object { Test-WacliPathWithin -Parent $_.Path -Child $fullReference } | Sort-Object { $_.Path.Length } | Select-Object -First 1)
            if ($coveringRoot.Count -eq 1) {
                $mediaMap.Add([pscustomobject]@{
                    sourcePath = $fullReference
                    status = 'inside-root'
                    rootId = [string]$coveringRoot[0].Id
                    relativePath = [System.IO.Path]::GetRelativePath([string]$coveringRoot[0].Path, $fullReference)
                })
                continue
            }
            if (-not (Test-Path -LiteralPath $fullReference -PathType Leaf)) {
                $mediaMap.Add([pscustomobject]@{ sourcePath = $fullReference; status = 'missing-at-backup-time' })
                continue
            }
            if (-not (Test-Path -LiteralPath $mediaRoot -PathType Container)) {
                New-Item -ItemType Directory -Path $mediaRoot -Force -ErrorAction Stop | Out-Null
            }
            $externalCount++
            $mediaName = '{0:D3}-{1}' -f $externalCount, [System.IO.Path]::GetFileName($fullReference)
            $mediaTarget = Join-Path $mediaRoot $mediaName
            $sourceHash = (Get-FileHash -LiteralPath $fullReference -Algorithm SHA256 -ErrorAction Stop).Hash
            Copy-Item -LiteralPath $fullReference -Destination $mediaTarget -Force -ErrorAction Stop
            $copiedHash = (Get-FileHash -LiteralPath $mediaTarget -Algorithm SHA256 -ErrorAction Stop).Hash
            if ($sourceHash -ne $copiedHash) {
                throw "External WACLI media copy failed verification for '$fullReference'."
            }
            $mediaMap.Add([pscustomobject]@{
                sourcePath = $fullReference
                status = 'copied-external'
                payloadPath = "media/$mediaName"
                sha256 = $sourceHash
                length = (Get-Item -LiteralPath $fullReference -ErrorAction Stop).Length
            })
        }

        $mediaSummary = [pscustomobject]@{
            databases = $media.Databases
            tables = $media.Tables
            references = @($media.References).Count
            insideRoots = @($mediaMap | Where-Object { $_.status -eq 'inside-root' }).Count
            copiedExternal = @($mediaMap | Where-Object { $_.status -eq 'copied-external' }).Count
            missingAtBackupTime = @($mediaMap | Where-Object { $_.status -eq 'missing-at-backup-time' }).Count
        }
        if (@($media.References).Count -gt 0) {
            $mediaMap | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $DestinationRoot 'media-map.json') -Encoding UTF8
            if (-not (Test-Path -LiteralPath (Join-Path $DestinationRoot 'media-map.json') -PathType Leaf)) {
                throw 'WACLI media map could not be written.'
            }
        }
        if ($mediaSummary.missingAtBackupTime -gt 0) {
            $missingList = ($mediaMap | Where-Object { $_.status -eq 'missing-at-backup-time' } | Select-Object -First 5 -ExpandProperty sourcePath) -join '; '
            Write-Warning "WACLI media map: $($mediaSummary.missingAtBackupTime) referenced file(s) no longer exist on this machine (recorded as missing-at-backup-time): $missingList"
        }
        if ($mediaSummary.copiedExternal -gt 0) {
            Write-Host "WACLI media: copied $($mediaSummary.copiedExternal) external referenced file(s) into payload\media with SHA256 verification."
        }

        $manifest = [pscustomobject]@{
            format = 'mainframe-wacli-vss-roots-v2'
            consistency = 'crash-consistent'
            applicationConsistent = $false
            windowsRuntimeValidated = $false
            restoreActivation = 'not-performed'
            sourcePayloadsReadFrom = 'verified-held-vss-shadow-set'
            sqliteSidecars = 'included-byte-for-byte-no-filename-exclusions'
            mediaReferenceCoverage = 'proven-complete'
            mediaReferenceSource = 'held-vss-payload-sqlite-enumeration'
            externalMediaSource = 'live-file-copy-sha256-verified'
            mediaReferences = $mediaSummary
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

Export-ModuleMember -Function Get-WacliVssInputs, Get-WacliVssBackupExecutable, Get-WacliMediaReferences, Resolve-WacliSqliteTool, Invoke-WacliVssCopy, Test-WacliPathWithin
