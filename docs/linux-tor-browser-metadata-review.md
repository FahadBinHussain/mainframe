# Tor Browser 15.0.26: metadata-only Linux candidate

## What the sources show

On 2026-10-24, the current [Scoop Extras `tor-browser` manifest](https://raw.githubusercontent.com/ScoopInstaller/Extras/master/bucket/tor-browser.json) declared package version `15.0.26`. Its Windows x86_64 portable URL points to the official Tor archive directory and its manifest SHA-256 is `37c2201f31f2fd9ea8470cf8f3cafc8dd3cd92d9ed9109b3913e1105b47d2af5`. Only the version, Windows x64 URL, and hash were used; script, persistence, and other manifest fields are untrusted and ignored.

Tor Project's [15.0.26 release announcement](https://blog.torproject.org/new-release-tor-browser-15026/) says that version is available from its download page and distribution directory. The official [versioned 15.0.26 directory](https://archive.torproject.org/tor-package-archive/torbrowser/15.0.26/) lists both `tor-browser-windows-x86_64-portable-15.0.26.exe` and `tor-browser-linux-x86_64-15.0.26.tar.xz`, each with a corresponding `.asc` signature file. It also lists `sha256sums-signed-build.txt` and its `.asc` sidecar.

The official [signed-build checksum text](https://archive.torproject.org/tor-package-archive/torbrowser/15.0.26/sha256sums-signed-build.txt) records the same Windows x86_64 portable SHA-256 as the Scoop manifest and Linux x86_64 tarball SHA-256 `327ac7443724b9eb6d3697506391b110ee159739bdc14bd731caa6fc16ffbf74`. These are metadata observations, not a local checksum verification or an authenticated trust decision.

Tor's [signature verification guidance](https://support.torproject.org/tor-browser/getting-started/verifying-tor-browser/) identifies the release signatures as OpenPGP and gives the Tor Browser Developers signing-key fingerprint `EF6E286DDA85EA2A4BA7DE684E2C6E8793298290`. The signer key and package signatures have not been fetched or verified. The generic download pages returned older version rows during this review; the exact `15.0.26` comparison relies on the versioned release announcement, directory, and checksum text, not a claim that a generic page's latest listing was current.

## Why installation remains blocked

The same-version Windows hash matches Tor's published checksum text, and the same-version Linux x86_64 archive/hash and signature sidecars are present. The checksum text's OpenPGP signature and Tor signing-key trust have not been verified, and no archive bytes or member layout were inspected. Extraction safety, runtime dependencies, a separate install destination/activation contract, and any profile/state migration remain unvalidated. Keep the package action blocked; do not download, extract, install, launch, or import Tor Browser state.

The opt-in planner is intended to fetch only bounded public metadata (manifest fields, release-directory listing, release announcement, and checksum text). It must never fetch the `.exe`, `.tar.xz`, or `.asc` contents, execute manifest fields, read private backup/profile data, or enable installation. The observed version is not a restore pin.
