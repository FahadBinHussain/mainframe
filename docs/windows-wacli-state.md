# Windows and WACLI state boundary

`NativeState/wacli/` denotes **captured Linux WACLI state** in this archive contract. A Windows restore may carry `NativeState/wacli/...` in either the embedded secrets tree or standalone `tool-secrets.zip`, but the Windows restore scripts only report that the payload was preserved. They do not extract, activate, or remap it into `%APPDATA%\mainframe\accounts` or any Windows WhatsApp account path. Existing Windows account paths remain unchanged.

## Windows WhatsApp capture safety

Both Windows backup routes (`backup.ps1` and the standalone `backup-secrets.ps1`) inspect only filenames and directory metadata in a WhatsApp account subtree before copying. If any SQLite database or sidecar is present (`*.db`, `*.sqlite`, `*.sqlite3`, or names ending `-wal`, `-shm`, or `-journal`), capture is explicitly blocked with the detected filenames. The whole live SQLite subtree is blocked, rather than silently omitting sidecars; this is the conservative boundary because a database without visible sidecars is not proven to be a consistent snapshot. No file contents are opened and no Windows-to-Linux/WACLI remapping is attempted.

This guard does not alter unrelated Windows backup behavior. It applies when the source itself is named `WhatsApp` or when an account-root source contains a direct `WhatsApp` child. A future implementation may permit this state only after it can prove a consistent snapshot.
