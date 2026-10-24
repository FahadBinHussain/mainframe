# WakaTime Desktop metadata review

## Exact release observation

On 2026-10-24, the [WinGet version directory listing](https://api.github.com/repos/microsoft/winget-pkgs/contents/manifests/w/Wakatime/DesktopWakatime) showed `3.0.0.1` as the highest numeric version directory. Its [installer manifest](https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/w/Wakatime/DesktopWakatime/3.0.0.1/Wakatime.DesktopWakatime.installer.yaml) identifies `Wakatime.DesktopWakatime` and explicitly points both supported Windows installer URLs at publisher tag `v3.0.0+1`. The manifest's version number and release tag are reported separately; no equivalence is inferred from their formatting.

The exact [publisher release metadata](https://api.github.com/repos/wakatime/desktop-wakatime/releases/tags/v3.0.0%2B1) confirms the tag and reports it as published, not draft or prerelease. Its Windows asset digests match the WinGet manifest values for x64 (`de91fffe387eecae0dfa28705470c20cccd538ea1c530b2bc111309e2a64cdb5`) and ARM64 (`884418eacf4a77906ef4bb92c87810ef0a2d9f2a0aa7062ee4d930eae224792c`). The current [latest-release endpoint](https://api.github.com/repos/wakatime/desktop-wakatime/releases/latest) returns the same tag. The same release lists these Linux candidates:

| Architecture | Linux candidate | Size | GitHub asset SHA-256 |
| --- | --- | ---: | --- |
| x86_64 | [wakatime-linux-x86_64.AppImage](https://github.com/wakatime/desktop-wakatime/releases/download/v3.0.0%2B1/wakatime-linux-x86_64.AppImage) | 122,812,052 bytes | `7130922c8dd06ea38832175470a0be3e03f6ce09553006d4b7c1b237a590d8b7` |
| ARM64 | [wakatime-linux-arm64.AppImage](https://github.com/wakatime/desktop-wakatime/releases/download/v3.0.0%2B1/wakatime-linux-arm64.AppImage) | 123,072,019 bytes | `31b8c69fc3080f65d5a685c9821009e17a98d2b5af6394e16358d286db297414` |

These are live upstream metadata observations, not a user's restore-version pin. GitHub asset digests are metadata, not an independently verified signature.

## Why it remains blocked

Only explicit `--wakatime-desktop-metadata-plan` reads the bounded WinGet version index, exact-version installer manifest, and release metadata for the tag explicitly named by that manifest. The default package plan does not look up WakaTime. No Windows installer, Linux AppImage, or checksum-file contents are fetched or executed.

WakaTime's [Linux setup page](https://wakatime.com/linux) says the desktop app prompts for an API key. The [backup coverage record](linux-restore-coverage.md#data-the-windows-backup-deliberately-does-not-include) explicitly excludes the WakaTime Desktop tree; this review neither reads nor imports any WakaTime config/API key, nor activates an account. AppImage contents, runtime compatibility, and desktop integration remain unreviewed. WakaTime CLI is not treated as a substitute for the desktop app.

The plan remains blocked; these observations do not authorize installation or state activation.
