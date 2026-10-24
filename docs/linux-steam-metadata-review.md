# Steam: no version-pinned Linux package mapping

## What the sources show

The tracked [`scoop-allowed.json`](../scoop-allowed.json) entry is the bare package name `steam`; it does not identify a Windows package version or manifest source. No private backup or live install state was inspected to infer one.

Valve's [official Steam Linux repository page](https://repo.steampowered.com/steam/) describes the current Ubuntu LTS download as `steam_latest.deb`. It calls this a launcher/bootstrapper containing `steam-devices` udev rules and a minimal Steam client that uses self-update to download the rest. The page does not publish a release version or top-level SHA-256 for that latest filename. It also describes a repository-based install path involving a signing key, APT source configuration, and i386 architecture; none of those steps were run. Valve notes that version-numbered historical releases exist under `archive/stable/`, but the tracked Windows allowlist does not select a corresponding version.

Valve's [Steam download page](https://store.steampowered.com/about/) is a general install page and does not supply a versioned Linux artifact/checksum mapping in its readable content.

## Why the package remains blocked

There is no pinned Windows version/source to compare with the Linux bootstrapper, and the current `steam_latest.deb` route is unversioned, self-updating, and lacks a published top-level checksum on the repository page. The available evidence does not establish a same-version integrity-pinned package or a bounded install path whose side effects have been reviewed for separate authorization. Keep Steam blocked; do not infer a release pin or make APT, signing-key, i386, udev, PATH, or client-state changes.

No `.deb`, package archive, APT `InRelease`/`Packages` metadata, signing key, or binary was downloaded or inspected. No installer, Steam client, account/login flow, library, profile, or live-host state was accessed or changed. This is a source metadata review only, not an installation or runtime claim.
