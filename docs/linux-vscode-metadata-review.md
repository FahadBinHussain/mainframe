# VS Code Linux metadata review

## Finding

The current Scoop Extras declaration for VS Code reports version **1.143.1** for the Windows x64 archive. Microsoft's version API reports the same product version for both the Windows x64 archive and Linux x64 release, and both identify build commit `e646868227c3e3a9e3f24277c8c7220be42c0be7`. The Windows SHA-256 from Scoop matches Microsoft's version metadata exactly. Microsoft's API also lists an x64 Linux `.tar.gz` candidate with a SHA-256.

This establishes a same-version, same-build metadata match—not a restore pin, artifact verification, or operational-equivalence claim.

| Item | Observed metadata |
| --- | --- |
| Scoop version | `1.143.1` |
| Scoop Windows x64 SHA-256 | `b4f9643b8a549ca2c85a1bbc9063fc76f1e08fc0036a7f6a1a181cdc05235eca` |
| Microsoft build commit | `e646868227c3e3a9e3f24277c8c7220be42c0be7` |
| Linux x64 candidate | [`code-stable-x64-1792691793.tar.gz`](https://vscode.download.prss.microsoft.com/dbazure/download/stable/e646868227c3e3a9e3f24277c8c7220be42c0be7/code-stable-x64-1792691793.tar.gz) |
| Linux x64 SHA-256 | `48f658052e54e020a1c1be7b37ac0f9ae39f07e8ccda805c63f053cfda72b2be` |

The version endpoints were [`win32-x64-archive`](https://update.code.visualstudio.com/api/versions/1.143.1/win32-x64-archive/stable) and [`linux-x64`](https://update.code.visualstudio.com/api/versions/1.143.1/linux-x64/stable). The Windows version/hash declaration came from the [Scoop Extras manifest](https://raw.githubusercontent.com/ScoopInstaller/Extras/master/bucket/vscode.json). These values were observed on 2026-10-24.

## Bounded planner behavior

The package planner now accepts `--vscode-metadata-plan` as an explicit, dry-only review mode. The default plan makes no VS Code metadata request. The resolver reads only the fixed Scoop manifest and the two version-pinned Microsoft JSON endpoints, rejects redirects and duplicate JSON keys, caps response sizes, validates the Windows x64 version/URL/hash and the Linux x64 version/build/URL/hash, and records the Linux archive URL without requesting it. It supports Linux x86_64 metadata only. The VS Code action remains blocked and has no executable command or install archive attached.

No Windows manifest scripts or persistence instructions are executed or translated. No archive or installer bytes were downloaded, opened, or inspected. No package was installed, no live home was changed, and no WACLI or allowlist entry was modified.

## Why it remains blocked

The observed upstream release is not a version selected from a user restore pin. The hash match is publisher metadata agreement; the Linux archive itself has not been independently verified or reviewed. Safe extraction, archive contents, runtime dependencies, desktop integration, update/telemetry behavior, and any settings/extensions/profile migration remain unvalidated. The [official Linux setup guide](https://code.visualstudio.com/docs/setup/linux) notes that its `.deb` package prompts to add Microsoft's APT repository and signing key; this review does not choose that package or authorize repository changes. Microsoft's [download page](https://code.visualstudio.com/download) says downloading and using VS Code is subject to its license terms and privacy statement. No download/use or terms acceptance occurred here.

The planner therefore reports this candidate as metadata-only and blocked. It makes no installation, activation, account, or state-migration claim.
