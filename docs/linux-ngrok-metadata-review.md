# ngrok Linux package: metadata matched, installation still blocked

## What the dry plan establishes

The tracked Scoop allowlist names `ngrok` without a version pin. The explicit `--ngrok-metadata-plan` option reads only the current official Scoop Main manifest and ngrok's stable archive-index page. It requires the Scoop Windows x64 version, URL, and SHA-256 to match the same-version Windows ZIP row in ngrok's index, then records the Linux x86_64 `.tar.gz` URL and publisher-listed SHA-256. The default package plan does not fetch these sources, and the metadata option cannot be combined with `--execute` or Vercel's separate review option.

On 2026-10-24, the current Scoop manifest and ngrok stable archive index both reported version **3.39.13**. The index's Linux 64-bit `.tar.gz` candidate was `ngrok-v3-3.39.13-linux-amd64.tar.gz` with SHA-256 `233e0647849913e6404150c1e9c5e4f31c1368aefee330958d038d7afecb8f2e`; the manifest's Windows x64 hash matched the index's Windows ZIP record. This is a dated upstream metadata observation, **not a version pinned by the user's backup or allowlist**. The publisher's digest has not been checked against downloaded artifact bytes and is not an independent signature.

## What it does not establish

ngrok's [Linux download guide](https://ngrok.com/download/linux) describes a standalone executable with no runtime dependencies and an extraction-based installation path. The actual archive was not downloaded or inspected, so the exact tar member list, file type/permissions, and a safe bounded extractor are not validated. No binary is downloaded, installed, run, or runtime-tested by this review.

Every ngrok action remains `blocked`. The dry plan does not select an install root, change PATH or services, read/create agent configuration, import a token, or access an account. Authentication and configuration for later use are separate from publishing a binary and are not inferred from Windows state. A future installer would require an explicit new destination, bounded download and SHA-256 verification, exact archive-layout validation, and safe no-replace publication; no operational-equivalence claim follows from this metadata review.

## Sources

- [Scoop Main `ngrok.json`](https://raw.githubusercontent.com/ScoopInstaller/Main/master/bucket/ngrok.json) — current Windows version, x64 asset URL, and SHA-256.
- [ngrok stable v3 archive index](https://ngrok.com/download/archive/ngrok/ngrok-v3/stable/ngrok_archive) — same-version platform artifacts and publisher-listed checksums.
- [ngrok Linux download guide](https://ngrok.com/download/linux) — standalone binary and installation guidance.
- [ngrok agent configuration](https://ngrok.com/docs/agent/config/) — configuration is separate from the metadata-only plan.
