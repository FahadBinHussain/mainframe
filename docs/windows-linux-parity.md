# Windows / Linux parity

every feature of this repo, compared side by side. `✅` means both platforms do the
same thing. `❌` names the gap and how to close it.

verdict basis: the code, not the docs. `✅` means the behaviour exists on both
sides today. where a row is `❌` the third column says the smallest change that
closes it.

the platform split is not a coin flip: windows is the **source** machine (it owns
the backup and the secrets archive), linux is the **target** (it restores,
converts and activates). so a few rows are linux-only on purpose - those are `✅`
with "n/a" in the windows column.

## entry points and modes

| feature | windows | linux | verdict |
|---|---|---|---|
| one-command live setup | `irm …/boot.ps1 \| iex` | `boot.sh --real` | ✅ |
| mode dispatch | `boot.ps1`, `bootstrap.ps1` | `boot.sh --restore/--packages/--setup-tools/--real` | ✅ |
| dry run / plan only | `bootstrap.ps1 -DryRun` | `bootstrap.sh --dry-run`, `linux_packages.py` without `--execute` | ✅ |
| offline inventory + staging, never live | `restore.ps1` | `restore.sh` / `linux_restore.py` | ✅ |
| prerequisites | winget + scoop | apt: git, curl, ca-certificates, python3 - **only when missing** | ✅ |
| writes the live home | yes | yes, and only with `--yes` | ✅ |

## vault and phone approval

the core of the 1-tap flow. there is ONE implementation now - `vault-flow.ps1`
and the two modules it uses - and both machines run it.

| feature | windows | linux | verdict |
|---|---|---|---|
| 1-tap phone approval | `vault-flow.ps1` → `vault-approval.psm1` | `vault-flow.ps1` → `vault-approval.psm1` | ✅ |
| 2-digit number matching | ✅ | ✅ (same module) | ✅ |
| agent / model / host provenance | `Get-CallerIdentity` | same module | ✅ |
| ADB auto-popup of the page | ✅ | ✅ (same module) | ✅ |
| stale marker (`mf:expired`) | ✅ | ✅ (same module) | ✅ |
| relay-configurable server + page | env + config | env + config + `--ntfy-server/--ntfy-topic/--pages-base` | ✅ |
| 1-hour session cache | `%APPDATA%\mainframe\accounts\bitwarden\session.key` | `$XDG_CONFIG_HOME/mainframe/accounts/bitwarden/session.key` (mode 600) | ✅ |
| TTL key + precedence | `vaultTtlMinutes` (env > config > 60) | same | ✅ |
| expired session locks and purges | ✅ | ✅ (same module) | ✅ |
| lock on demand | `vault-lock.ps1` | `--lock-vault` → `vault-flow.ps1 -Lock` | ✅ |
| lock only when the session is stale | `vault-lock.ps1` variant | `vault-flow.ps1 -LockIfStale` | ✅ |
| terminal password fallback | ✅ | ✅ (needs a tty) | ✅ |
| **live-proven no-tap second run** | 1334 items read, no tap | 0 codes pushed, 0 asks, `failures: []` | ✅ |
| one implementation of the flow | pwsh modules + `vault-flow.ps1` | the same pwsh modules + the same cli | ✅ **one codebase.** the python copy is gone; linux shells out to `vault-flow.ps1` and reads its json document |
| the powershell runtime | scoop | `pwsh_linux.py` - official tarball, pinned to two published digests, installed in isolation | ✅ |
| one contract fixture both sides pass | `tests/vault-flow.Tests.ps1` | `tests/test_linux_real_vault_relay.py` drives the same module through pwsh | ✅ |

## backup (windows is the source)

| feature | windows | linux | verdict |
|---|---|---|---|
| machine backup producer | `backup.ps1` / `backup.cmd` | none | ❌ **no linux backup producer.** close: a `backup_linux.py` that writes the same manifest layout, or state plainly in the README that linux is restore-only |
| secrets archive inside the backup | `backup-secrets.ps1` | none | ❌ close: same producer |
| publish + notify the backup | `publish-backup.ps1`, `daily-backup-publish.ps1`, `backup-notify.ps1` | none | ❌ close: a systemd timer + cron that publishes through the relay |
| WACLI snapshot producer | `wacli-vss-backup.psm1` (VSS) | `wacli_snapshot.py --source-root --destination` | ✅ |
| scheduled keep-alive | `cronjob-account.ps1` | none | ❌ **the helper itself is blocked:** it stores its profile under `%APPDATA%`. close: make the profile root XDG-aware and the same helper works under pwsh on linux |
| metered-connection check | `network-cost-check.ps1` (WinRT, powershell.exe only) | none | ❌ close: read NetworkManager's metered state |
| irreversible erase of a machine | `wipe.ps1` | none | ❌ close: a quarantine-and-confirm flow - never an irreversible shred wrapper |

## restore

| feature | windows | linux | verdict |
|---|---|---|---|
| quick mode | `-Mode quick` | hardcoded quick | ✅ |
| full mode | `-Mode full` | ❌ | ❌ **no full mode.** close: `--mode full\|quick` on `linux_real.py`, passed straight into `copy_recovery` |
| pinned release | `-Pinned` | always the latest | ❌ close: a `--pinned` flag that pins the release tag |
| secrets restore (manifest → decrypt → activate) | `restore-secrets.ps1` | password fetched, zip left raw in `recovered/` | ❌ **the documented next step.** close: implement the manifest mapping in `linux_restore.py` |
| repo selection | `-CloneRepos` hashtable | `--skip-private-repo` bool | ❌ close: repeatable `--clone-repo name=url`, so the same repo map drives both |
| `$HOME/AGENTS.md` | restored | `--restore-global-agents` opt-in | ✅ (linux is stricter on purpose) |
| `.agents/skills` | restored | blocked | ❌ close: map the skills tree the way `AGENTS.md` is mapped, same allowlist rules |
| activate into live home | always (after the F/Q mode prompt) | `--yes` | ✅ (linux is safer) |
| overwritten files | **per-item and mixed**: some persist files are kept (fresh-box-only rule, warn loud), Edge's User Data is removed and replaced with no copy | **one rule**: the existing file is copied to `<work_root>/restore-backup/` before it is replaced | ❌ **two different policies for the same event.** close: adopt linux's rule on windows - copy the existing file aside before replacing it - so both sides keep a rollback copy instead of one keeping and one deleting |
| portable conversion maps | n/a (source) | git, mpv, yt-dlp, flameshot, qbittorrent, obs, user-env | ✅ (linux-only by nature) |

## packages and tools

| feature | windows | linux | verdict |
|---|---|---|---|
| allow-listed catalogue | 78 entries (69 scoop, 6 winget, 2 pnpm, 1 go) | 16 validated linux adapters | ❌ **a 78-vs-16 gap.** close: an adapter per missing tool, or keep the gap explicit in the plan output so nobody expects parity |
| version-pinned restore semantics | pins to exact versions, most stay blocked | same | ✅ |
| live install of current native builds | winget | direct native installs | ✅ |

## multi-account helpers

| feature | windows | linux | verdict |
|---|---|---|---|
| 17 `*-account.ps1` helpers | ✅ | ✅ **after the profile-root change** - all of them resolve their profile through `mainframe-paths.psm1` now | ✅ (the 12 helpers in `automata-private` still hardcode windows paths - see below) |
| `account-contract.ps1` checker | ✅ | ✅ path-agnostic | ✅ |
| the 12 helpers in `automata-private` | ✅ | ❌ they import `vault-secret.psm1` from an absolute windows path | ❌ close: resolve the mainframe checkout through `Get-MainframeCheckoutRoot` instead of `C:\Users\Admin\Downloads\...` |

## maintenance

| feature | windows | linux | verdict |
|---|---|---|---|
| seal the bw email | `seal-bw-email.ps1` | same file under pwsh | ✅ |
| edge CDP profile sync | `edge-cdp-profile-sync.ps1` | none | ❌ close: sync the profile directory out of the backup on linux |
| coverage documentation | `docs/linux-restore-coverage.md` | same file | ✅ |
| this parity table | `docs/windows-linux-parity.md` | same file | ✅ |

## summary

| area | verdict |
|---|---|
| vault + phone approval | ✅ fully symmetric, live-proven on both (1 gap: two implementations of the flow) |
| entry points, staging, activation | ✅ symmetric |
| restore options (full mode, pinned, secrets, repo map, skills, overwrite policy) | ❌ 6 gaps |
| backup direction (producer, secrets in backup, publish, keep-alive, metered check, erase) | ❌ 6 gaps |
| tool catalogue | ❌ 1 gap (78 vs 16) |
| multi-account helpers | ❌ 1 gap (the whole `%APPDATA%` root) |
| maintenance (edge CDP profile sync) | ❌ 1 gap |

**16 open gaps.** the two that matter most: the linux **secrets restore** (the
vault password is already there, only the mapping is missing) and the
**`%APPDATA%` profile root** (that single change unlocks all 17 account helpers
on linux at once).

the **overwrite policy** is the one that can bite: linux keeps a rollback copy
of every file it replaces, windows keeps some existing files and deletes
others (Edge's User Data) without a copy. one rule, both sides.
