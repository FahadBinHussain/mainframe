# Discord: no verified same-variant Linux package mapping

## What the sources show

On 2026-10-24, the current [Scoop Extras `discord` manifest](https://raw.githubusercontent.com/ScoopInstaller/Extras/master/bucket/discord.json) declared package version `1.0.9259-28` and pointed to the [Portapps Discord portable Windows x64 release](https://github.com/portapps/discord-portable/releases/download/1.0.9259-28/discord-portable-win64-1.0.9259-28.7z), with manifest SHA-256 `b6dd79ea0a99c87366e43bbef73eb139eae36459ade233288404fa8e0488cd84`. This is the current Windows package declaration, not a Linux version or user-selected restore pin.

Discord's [official download page](https://discord.com/download) lists Linux as an available platform, but its readable public content does not expose an exact Linux package version, direct artifact URL, or SHA-256/signature. It therefore does not establish an integrity-checked Linux counterpart for the Portapps Windows package.

## Why the action remains blocked

The Windows selection is a third-party portable Windows build, while the official Discord page only establishes Linux availability. There is no evidence here that maps the Windows package version/variant to an exact Linux artifact with a published integrity value. Keep `discord` blocked; do not infer parity, install a Snap/Flatpak instead, or change the Windows allowlist.

No package archive was downloaded or inspected, and no install, update, login, profile/state import, or live-host action was run. This is a source metadata review only; Windows and Linux application state equivalence remains unvalidated.
