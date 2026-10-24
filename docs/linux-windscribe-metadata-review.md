# Windscribe Linux metadata review

## What matches

The current Microsoft WinGet directory entry for `Windscribe.Windscribe` resolves to version `2.24.13`. Its x64 Windows installer SHA-256 matches the GitHub release API digest for the exact `Windscribe_2.24.13_amd64.exe` asset. The manifest's ARM64 Windows installer hash also matches that release's `Windscribe_2.24.13_arm64.exe` digest. The publisher's `v2.24.13` release lists same-version Linux desktop Debian packages for both architectures: [`windscribe_2.24.13_amd64.deb`](https://github.com/Windscribe/Desktop-App/releases/download/v2.24.13/windscribe_2.24.13_amd64.deb) with GitHub API digest `79a9f17fcf7c858e8d2b31ccdae9ab7da6e3840fbc90a9740104cb0acbce1991`, and [`windscribe_2.24.13_arm64.deb`](https://github.com/Windscribe/Desktop-App/releases/download/v2.24.13/windscribe_2.24.13_arm64.deb) with digest `a6f6dcb10e14cf9d5b0e676fa04ebd97713bfe2bdfece146581e4fb288bc165b`. These are metadata observations, not selected restore pins.

For the Windows installers, WinGet lists x64 SHA-256 `821FF217D87B4ACBD71408303D9A5BC35ABFEFDADA6761F7FD2944A92D5609D2` and ARM64 SHA-256 `1013E6B459D9F3F98D01BF62ED4F9463E3B7FD04448875210B56BACBA4E3E53E`; the corresponding release API digests match these values case-insensitively.

Sources: the [WinGet package directory](https://api.github.com/repos/microsoft/winget-pkgs/contents/manifests/w/Windscribe/Windscribe), the [exact WinGet installer manifest](https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/w/Windscribe/Windscribe/2.24.13/Windscribe.Windscribe.installer.yaml), the [official v2.24.13 release metadata](https://api.github.com/repos/Windscribe/Desktop-App/releases/tags/v2.24.13) and [release page](https://github.com/Windscribe/Desktop-App/releases/tag/v2.24.13), and Windscribe's [Linux desktop setup guidance](https://windscribe.com/knowledge-base/articles/how-to-set-up-windscribe-on-linux). The Linux GUI package is distinct from the separately named `windscribe-cli_*` assets.

## What the planner does

The default package plan performs no Windscribe metadata lookup. The explicit `--windscribe-metadata-plan` option reads only the public WinGet version directory listing, the selected installer manifest's identity/version/architecture/URL/hash fields, and the exact publisher release API record. It compares the selected Windows architecture's hash with the matching official release asset digest and reports the same-version Linux desktop `.deb` URL, size, and digest. The option is dry-only, mutually exclusive with other metadata-plan modes, and its action remains blocked; there is no package download or installation path in this change.

## What remains blocked

GitHub's asset digest is metadata, not independent GPG signature verification. Windscribe documents Linux package signing, but neither signature bytes nor key material were accessed or verified. Package contents and the privileged service, routing, firewall, and broader network effects have not been reviewed. No login, account, credential, Windows configuration, or VPN state is imported or activated. The source/version match therefore does not establish runtime compatibility or operational equivalence.

All tests use synthetic fixtures with network calls mocked. No `.exe`, `.deb`, signature, or private backup data was downloaded or inspected; no installation, service, network, or live-home changes were made.
