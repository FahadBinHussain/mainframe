# plan: mainframe cloud bootstrap (rmusb)

**goal:** restore any pc to "my pc" from a terminal one-liner + one password. no usb, no manual steps.

```
irm <url>/boot.ps1 | iex
# → bitwarden password prompt (the ONLY credential you type)
# → 15-30 min later: tools, repos, secrets, edge profile, tasks, vpn, tailscale
```

---

## architecture (two sources, one password)

```
boot.ps1 (public, tiny, reviewable)
   │
   ├─1─ clone mainframe repo (public, zero secrets by design)
   ├─2─ ask bitwarden master password → unlock vault
   │      └─ reads: github token (for step 4) + all account tokens + env secrets
   ├─3─ restore.ps1 -Mode full -ExcludeSecrets    (tools, repos, manifests, tasks)
   ├─4─ download latest mainframe-backup.zip from PRIVATE github release
   │      (auth = github token fetched from vault in step 2)
   │      └─ restore edge profile + accounts dirs + skills + native bits from it
   └─5─ tailscale provision + sanity check → print report
```

**why two sources:** vault = secrets only (never store bulk data there). zip = bulk
state (edge profile 425MB, account profile dirs, skills). the zip is private but
fetchable, and its key (github token) lives in the vault — so bitwarden password
is the single root of trust.

---

## components to build

### 1. `backup.ps1` addition — publish step (new)
- after zip build: upload `mainframe-backup.zip` to a **private repo release**
  (`FahadBinHussain/rmusb-store` or similar), tag = date (`2026-09-04`), asset =
  the zip. use `gh release create/upload` with the vault github token.
- keep last N=3 releases (prune older) so the store stays bounded (~1.3GB).
- mode: `backup.ps1 -Publish` (manual trigger) — auto-publish optional later.
- NOT auto by default: a bad backup shouldn't silently overwrite the good one.

### 2. `boot.ps1` (new, lives in mainframe repo root, surfaced at a stable url)
- ~80 lines, no secrets inside (it's public — reviewable, nothing to leak).
- steps:
  1. check admin → self-elevate (scoop + VSS need it)
  2. ensure git → clone `FahadBinHussain/mainframe` to `~\Downloads\mainframe`
  3. prompt bitwarden password (secure prompt, env-scoped, never written to disk)
  4. `bw unlock` → session key → export vault github token
  5. `restore.ps1 -Mode full -ExcludeSecrets` (already handles scoop, pnpm, uv,
     tasks, patches, vault env-secrets via env-sync)
  6. fetch latest release zip with the token → extract →
     `restore.ps1` edge-profile/accounts/skills paths from it
     (reuse existing restore path; the zip layout is already the backup layout)
  7. tailscale provision (authkey from vault) → desktop wake test optional
  8. final report: what restored / what needs 1-click (cws extensions) / next steps
- hosting the stable url: **raw.githubusercontent.com main branch** is enough
  (`https://raw.githubusercontent.com/FahadBinHussain/mainframe/main/boot.ps1`).
  optionally shorten later via a custom domain/redirect. keep the pinned-tag
  variant documented (`?ref=v1`) for paranoid boots.

### 3. `restore.ps1` small change
- accept `-BackupZip <path>` alternative to `-BackupRoot` (extract to temp, then
  current flow). today restore takes the extracted dir; boot.ps1 can also just
  extract itself and pass -BackupRoot. prefer the boot.ps1-side extract to keep
  restore.ps1 untouched.

### 4. vault requirements (verify + fill gaps)
- `github.com` item: needs a **classic PAT with `repo` scope** (release read on
  private repo). check existing token scopes; add if missing.
- `console.tailscale.com` item: already has auth keys (provision reads it). ok.
- `bitwarden.com` unlock flow: already handles stale-key heal + 2fa. ok.
- env-sync: already vault-native. ok.

### 5. edge cases the boot script must handle loudly (no fallbacks)
- no admin → elevate, don't degrade
- no bitwarden session → prompt, never cache to disk
- vault locked / wrong password → clear error, exit
- github token lacks `repo` scope → tell the user EXACTLY that, exit
- no network / github blocked (uni firewall?) → report the exact host blocked
- release asset missing (first ever run) → say "run backup.ps1 -Publish on the
  old machine first", exit
- partial failure mid-restore → leave a resume marker + rerun is idempotent
  (restore.ps1 already re-runnable)

---

## security model (honest)

- `irm | iex` = trusting main repo's main branch. mitigate: pin a tag in the
  documented command variant; review boot.ps1 diff on every pull. it's public
  so you can read every line anytime.
- the zip is private; token comes from the vault AT RUNTIME, never embedded.
- bitwarden password typed once per boot, session key env-scoped only.
- threat this does NOT solve: compromised github account serves a malicious zip.
  (mitigation if ever needed: checksum pinning in vault, verify before extract.)

---

## test plan

1. **desktop dry run**: publish current 425MB zip → wipe-restore on a fresh
   windows sandbox VM or the sandbox container (NOT the laptop).
2. boot.ps1 end-to-end on desktop (it's the disposable machine).
3. measure wall time; record which steps are slowest (probably scoop bulk apps).
4. write result into mainframe AGENTS.md.

## effort estimate

| piece | size |
|---|---|
| backup.ps1 -Publish | ~40 lines |
| boot.ps1 | ~100 lines |
| restore.ps1 | 0 lines (extract on boot side) |
| vault token scope check | 1 command |
| test on desktop | 1 evening |

## open questions (answer before build)

1. publish auto after every backup, or manual `-Publish`? (plan: manual first)
2. keep last N backups in the release store? (plan: 3)
3. repo name for the store: `rmusb-store` ok?
4. custom short domain later, or raw github url is fine? (plan: raw first)
