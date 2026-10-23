# Windows and WACLI state boundary

`NativeState/wacli/` denotes **captured Linux WACLI state** in this archive contract. A Windows restore may carry `NativeState/wacli/...` in either the embedded secrets tree or standalone `tool-secrets.zip`, but the Windows restore scripts only report that the payload was preserved. They do not extract, activate, or remap it into `%APPDATA%\mainframe\accounts` or any Windows WhatsApp account path. Existing Windows account paths remain unchanged.

For the standalone route, `restore-secrets.ps1` first uses `Expand-Archive` to extract the entire `tool-secrets.zip` into a private temporary directory. It then selectively copies only manifest-selected Windows secret paths and removes that temporary directory. A custom manifest item whose source is `NativeState/wacli`, a descendant, or a parent containing that reserved tree is warned and skipped, so extraction never causes native payload to be copied into a Windows restore target. The native payload remains preserved in the archive.

## Windows WhatsApp capture safety

Both Windows backup routes (`backup.ps1` and the standalone `backup-secrets.ps1`) inspect only filenames and directory metadata in a WhatsApp account subtree before copying. If any SQLite database or sidecar is present (`*.db`, `*.sqlite`, `*.sqlite3`, or names ending `-wal`, `-shm`, or `-journal`), capture is explicitly blocked with the detected filenames. The whole live SQLite subtree is blocked, rather than silently omitting sidecars; this is the conservative boundary because a database without visible sidecars is not proven to be a consistent snapshot. No file contents are opened and no Windows-to-Linux/WACLI remapping is attempted.

This guard does not alter unrelated Windows backup behavior. It applies when the source itself is named `WhatsApp` or when an account-root source contains a direct `WhatsApp` child. A future implementation may permit this state only after it can prove a consistent snapshot.

Windows restore applies the same fail-closed boundary to embedded `secrets/` entries and standalone archive entries, including custom manifests: any source path that is the reserved tree, below it, or contains it is skipped rather than partially merged.
