# Google Workspace CLI: install the official Linux binary, not its downloader

The `@googleworkspace/cli` declaration remains unchanged. On Linux it now maps to the same project's recommended [pre-built release archive](https://github.com/googleworkspace/cli#installation), rather than installing the npm wrapper. This removes the uncontrolled first-run downloader from this installation route. It does **not** make a standard global npm/pnpm installation safe by suppressing scripts.

## Why not just skip postinstall?

The reviewed upstream [`npm/run.js`](https://github.com/googleworkspace/cli/blob/v0.22.5/npm/run.js) checks for `bin/gws` next to the wrapper and starts `install.js` automatically if it is missing. [`install.js`](https://github.com/googleworkspace/cli/blob/v0.22.5/npm/install.js) downloads both the versioned archive and its checksum, extracts through an external `tar`/`unzip`, writes inside the npm package, and uses the host temporary directory. It has no documented binary-download/cache override. Skipping postinstall only postpones that work until the first invocation. There is no wrapper installation or lifecycle execution in the native adapter.

## Pin identity and integrity before use

The metadata-only resolver selects the npm declaration's exact stable version and records its registry source and SHA-512 integrity. It requires the corresponding published, non-draft, non-prerelease GitHub tag and exact `google-workspace-cli-x86_64-unknown-linux-gnu.tar.gz` asset. Missing or changed package identity, dependencies, wrapper contract, version, source, size or digest fails closed. It does not silently choose a different release or the musl/Windows/ARM variant.

The official [release workflow](https://github.com/googleworkspace/cli/blob/v0.22.5/.github/workflows/release.yml) publishes the archive and a `.sha256` companion. The adapter verifies the companion's size and GitHub asset SHA-256 before requiring its exact filename/hash to agree with the archive's asset digest. Future installation verifies the actual archive size and SHA-256 **before** parsing it. These hashes are publisher/GitHub integrity evidence, not an independently verified signature or an executed build-provenance attestation.

## Explicit isolated paths

A proposed new absolute root is supplied with `--gws-root`. Supplying it alone remains a dry plan:

```bash
python3 ./linux_packages.py --gws-root /absolute/new/gws-root
```

The detailed layout identifies `bin/gws`, an empty `home`, config/Google Workspace config, discovery cache, general cache, temporary, work, data and state paths under that root. Node and pnpm are explicitly **not required, installed, discovered or invoked**: this is the official native binary, not a Node package installation. No ambient Node/pnpm path or npm configuration participates.

The layout includes a fresh-environment proposal using only its explicit HOME, XDG, temporary, PATH and `GOOGLE_WORKSPACE_CLI_CONFIG_DIR` values. It is metadata, not a process launch or a persistent environment/configuration change. The installer does not invoke `gws`, even with `--version`, and does not inherit or probe credentials. Upstream stores discovery and token state under its [config directory](https://github.com/googleworkspace/cli/blob/v0.22.5/crates/google-workspace-cli/src/auth_commands.rs), and [loads `.env` files at startup](https://github.com/googleworkspace/cli/blob/v0.22.5/crates/google-workspace-cli/src/main.rs). Consequently future runtime activation still needs separate review of dotenv ancestor search, credentials, network behavior and actual library/ABI compatibility. Path routing is not an OS sandbox or a guarantee about later manually invoked commands.

## Fail before changing anything

A separately authorized future partial installation requires **both** `--execute --select @googleworkspace/cli` and a new `--gws-root`. No root is inferred from live HOME or PATH. Source, backup, live-home and system-path overlaps, existing destinations, symlink parents, unsafe writable ancestors, and overlap with other selected package roots are rejected before any selected installation. Publication is descriptor-relative, atomic and no-replace; a concurrent destination is never overwritten.

The bounded archive reader accepts only the upstream `gws`, `LICENSE`, `README.md` and `CHANGELOG.md` layout and its root directory. It rejects duplicate, extra, traversing, linked or special entries and verifies the binary's x86_64 ELF header without executing it. No external extractor, package manager, lifecycle script, login, profile/PATH edit, service, Windows-state import or terms acceptance is involved.

The conservative target is Debian/Ubuntu Linux x86_64 with glibc. Other architectures remain blocked. Synthetic offline tests prove source/size/hash checks, path guards, archive parsing and dispatch behavior; they do not prove the released binary runs on this host. `planned` means an installation route is ready for separate authorization, not that a package has been installed or an account restored. Vercel, Graphifyy and WACLI remain blocked and unchanged.
