# PowerShell on Linux: metadata-only release review

## What the public metadata shows

On 2026-10-24, the current [Scoop Main `pwsh` manifest](https://raw.githubusercontent.com/ScoopInstaller/Main/master/bucket/pwsh.json) declared version `7.6.8`. Its Windows x64 asset is `PowerShell-7.6.8-win-x64.zip` at `https://github.com/PowerShell/PowerShell/releases/download/v7.6.8/PowerShell-7.6.8-win-x64.zip`, with SHA-256 `b9f074f923c499b51ec99d313da8e9ae90d17a9f3adf00c73d6189f34d908528`.

The matching official [PowerShell `v7.6.8` release](https://github.com/PowerShell/PowerShell/releases/tag/v7.6.8) lists the Linux x64 asset `powershell-7.6.8-linux-x64.tar.gz` at `https://github.com/PowerShell/PowerShell/releases/download/v7.6.8/powershell-7.6.8-linux-x64.tar.gz`. The release's published SHA-256 list reports `59112E38AD83350E4F6DC0195953C66B5926792F300CA2E7691B8242E7A16E7F` for that Linux archive and `B9F074F923C499B51EC99D313DA8E9AE90D17A9F3ADF00C73D6189F34D908528` for the Windows x64 ZIP, matching the manifest after case normalization. The [GitHub release metadata](https://api.github.com/repos/PowerShell/PowerShell/releases/tags/v7.6.8) supplies the tag and asset records. These are dated upstream observations, not a backup pin or a hard-coded release constant.

## What remains blocked

The planner reads only the manifest version, Windows x64 URL/hash, release tag, exact Windows/Linux asset names and URLs, and their published checksum rows. Any other manifest fields—including pre/post-install scripts and persistence declarations—are treated as untrusted data and ignored. No script or archive is executed or downloaded; no Windows profile, module, registry, identity, or credential state is read or imported.

A metadata match does not establish a safe install. The [Microsoft Linux installation guidance](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-linux) and [alternate installation methods](https://learn.microsoft.com/en-us/powershell/scripting/install/alternate-install-methods?view=powershell-7.6) describe Linux tar.gz deployment but note that PowerShell and .NET dependencies vary by distribution and may be missing from manual archives. The archive layout, bounded extraction contract, executable/runtime dependencies, and isolated destination publication have not been validated. A version in the current Scoop manifest is not a user-selected restore pin. The Linux package action therefore remains blocked; no install, activation, PATH/profile edit, or operational-equivalence claim is made.

The published hashes are upstream checksum metadata, not locally verified archive digests or independent release signatures. The Windows allowlist and WACLI are unchanged.
