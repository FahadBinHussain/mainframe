# Google Cloud CLI: current version metadata does not match

## What the sources show

On 2026-10-24, the current [Scoop Extras `gcloud` manifest](https://raw.githubusercontent.com/ScoopInstaller/Extras/master/bucket/gcloud.json) declared version `590.0.0`. Its Windows x86_64 bundled-Python archive is `google-cloud-sdk-590.0.0-windows-x86_64-bundled-python.zip` with SHA-256 `e6b97a6f4a084069daf5101e520f83ff950e9962eba505e9581141cf3590b999`.

Google's current [versioned-archives table](https://cloud.google.com/sdk/docs/downloads-versioned-archives) lists the Windows x86_64 bundled-Python archive for `590.0.1`, with SHA-256 `38dad2c60c8507a2042e419ac9293e66b9f96156226c6cda92dcb1c4e8c65cf2`. Its Linux x86_64 row is the unversioned filename `google-cloud-cli-linux-x86_64.tar.gz`, with SHA-256 `b0dc27650a82e50321aa7c9d068cdc01443aa348f15489af9e5dec0a94623ae6`; that row does not state a release version. Google's [release notes](https://cloud.google.com/sdk/docs/release-notes) identify `590.0.1` as the current release dated 2026-10-22.

## Why the Linux action remains blocked

The Windows manifest and Google's current Windows archive table differ by a patch release (`590.0.0` versus `590.0.1`), and the Linux checksum row does not identify its version. These sources therefore do not establish a same-version Linux x86_64 archive/checksum for the Windows selection. Do not replace the declared Windows version with `590.0.1`, infer a version from the unversioned Linux filename, or change the allowlist. Keep `gcloud` blocked until official metadata ties the requested version to an exact Linux x86_64 archive and checksum.

Google describes its versioned archives as self-contained `google-cloud-sdk` directories that can be copied to a chosen location. That does not authorize running the vendor `install.sh`: its documented role includes PATH/shell integration and usage-reporting setup. No archive was downloaded or inspected, and no install script, `gcloud`, `gcloud init`, authentication, account setup, component manager, profile edit, or credential/state migration was run. The general package action remains blocked; this note records metadata drift only.

The observed versions and checksums are dated source observations, not restore pins or local artifact verification. The Windows allowlist, WACLI, backup data, and live host were not changed.
