# Linux restore implementation plan

Goal: maximize safe automatic migration from the Windows backup to native Linux without confusing preserved bytes, converted settings, installed software, and working applications. Phase 1 landed in PR #10; subsequent items use descriptive feature branches from current `main` and focused PRs in this repository without reopening the merged PR. Use free, portable/native defaults; never substitute an unrelated application. Migration rules must use app/platform schemas, not production-release values, private identifiers, host paths, or one user’s preferences. User values are runtime inputs and tests use synthetic data only.

## Four separate outcomes

| Outcome | Meaning | Evidence required |
|---|---|---|
| A — Preserve | Keep original archives byte-for-byte, plus safe extracted originals. | Verified hashes; unsafe/encrypted members remain in the original ZIP. |
| B — Convert/stage | Produce a reviewed Linux-compatible subset in a new offline tree. | Explicit source/target semantics, deterministic fixture tests, per-setting decisions and output hashes. Not activation. |
| C — Install/activate | Install the requested native package and deliberately import reviewed state. | Separate opt-in, actual host/package preflight, version/dependency checks, conflict handling, and runtime smoke tests. Never inferred from B. |
| D — Impossible/excluded/unresolved | Preserve unsupported state without claiming it works, or identify data the backup omitted. | Specific blocker; no silent omission, replacement, secret decryption, or operational-parity claim. |

Default inventory remains metadata-only. Recovery and conversion require explicit switches and a fresh destination. No development test may run a real restore/bootstrap, modify host settings, inspect secret payloads, decrypt credentials, or change global agent instructions.

## Phase 1 — Explicit adapter contract and first safe conversion

**Scope:** add a small versioned migration module and an opt-in `--convert-portable` recovery switch. First adapter: the root `.gitconfig` exported by Windows backup. Parse Git's own config grammar with includes disabled; never execute configured helpers, editors, filters, hooks, or commands. Accept only six understood settings: `core.autocrlf`, `core.eol`, `core.safecrlf`, `diff.algorithm`, `merge.conflictstyle`, and `color.ui`. Convert Windows checkout defaults (`autocrlf=true` to `input`; `eol=crlf/native` to `lf`); retain other supported values. Do not migrate identity, credentials, signing, include files, paths, shell commands, URL rewrites, or unknown settings. Record sanitized blocked decisions without values or arbitrary private subsection names. Duplicates/invalid values are blocked, not guessed. Unknown-only input produces no native config.

Original bytes remain untouched in A. Generated `.gitconfig` belongs only to B, never C. Malformed input, missing Git parser, oversized config, and native-target collisions must be explicit conversion blockers independent of preservation success. Conversion must not read browser/account/secret entries. Default inventory/recovery and existing candidate staging behavior remain unchanged.

**Acceptance tests:** synthetic quick/full ZIPs and Git configs; deterministic output and decision counts; Windows line-ending conversion; native values; quoted/multiline Git grammar; malformed syntax; duplicate keys; unknown/credential/include/command settings; disabled includes pointing at a nonexistent file; sanitized errors/reports; size limits; missing parser; no output for unsupported-only input; default inventory never opens payloads; conversion requires recovery; fresh-output permissions; multiple-source collision leaves no generated winner; original hashes unchanged; operational status remains incomplete.

**Progress: complete for this bounded scope, with review fixes.** Added `linux_migrations.py` with the versioned Git map and `--convert-portable` integration, sanitized decisions, no-overwrite publication, private permissions, and cross-archive conflict refusal. Review fixes retain verified originals when staging fails, clean only owned partial outputs, preserve caller traps and forward cancellation, validate package IDs, support root without sudo, bound external commands, and reject an incompatible setup runtime. Synthetic tests cover arbitrary user values and sanitized blockers; no personal preferences or release inventory are migration constants. Full offline validation passes: 73 Python tests; Bash suites 52 / 3 / 17 checks; mocked PowerShell 33 checks; all six Bash syntax checks; Python compilation; and diff whitespace checks. No production payload, real restore/bootstrap, package installation, live-home change, or secret decryption was used. Windows-native execution remains untested here.

## Phase 2 — Per-application migration maps

**Scope:** replace broad candidate assumptions incrementally with exact source layouts, target versions/paths, allowlisted fields, path dependencies, and blocker rules. Prioritize mpv/yt-dlp and Flameshot preferences, then qBittorrent and OBS. Validate each against upstream format documentation and synthetic fixtures before enabling conversion. Browser profiles, rclone/account auth, scripts/plugins, caches, and database schemas are not portable merely because the app has a Linux build. Do not mass-copy unknown nested Windows layouts into a native profile and label them converted.

**Acceptance tests:** one fixture for each supported source layout/version, Windows-path and device references, unknown fields, malformed input, quick/full duplicates, sensitive-field exclusions, output conflicts, deterministic hashes, and preservation without activation. Coverage report names every implemented adapter and every remaining raw/candidate-only app. No guessed app substitutions.

**Progress: mpv portable-options v1 implemented for a bounded subset.** The adapter reads only the exact Scoop persist layout `persist/mpv/portable_config/mpv.conf`, emits five documented global booleans to `.config/mpv/mpv.conf`, and leaves profile-scoped settings, paths, devices, scripts, shader/font/plugin dependencies, other files, and `mpv-git` unresolved. Synthetic fixtures cover malformed/unknown/path-bearing input, duplicate settings and archive sources, output collisions, deterministic output, and byte preservation. This is offline conversion only; neither Windows nor Linux executable version compatibility or runtime behavior is established. yt-dlp, Flameshot, qBittorrent, and OBS remain unconverted/candidate-only.

## Phase 3 — Portable operating-system preferences

**Scope:** build explicit translators only for understood portable preferences (for example a reviewed environment-variable allowlist and file-association intent). Separate intent from desktop-specific activation. Never import Windows PATH, drive paths, registry shell commands, SIDs, service credentials, or task XML as Linux configuration. Leave unsupported desktop/session backends blocked; prefer native XDG mechanisms when verified.

**Acceptance tests:** registry encoding/escaping fixtures, known/unknown variables, unsafe commands, unavailable native handlers, desktop backend differences, deterministic intent output, no live settings changes. Tasks/services remain raw-only until their timing, commands, identity, and dependency semantics are understood.

## Phase 4 — Exact package and runtime reconciliation

**Scope:** extend explicit package mappings without variant drift; preserve requested versions and provenance. Keep `mpv-git`, `nodejs-lts`, unvalidated vendor sources, and Windows-only packages blocked until an exact supported route exists. Reconcile native requirements, architectures, package availability, Python wheels/ABI, Go/CGO, pnpm global paths, plugin dependencies, and intentional version differences. No paid services or unsolicited vendor account setup.

**Acceptance tests:** mocked APT/CLI availability, unavailable versions, exact variants, architecture/distro guards, Windows-only requirements, no network/install in default planning, and failure-before-execution for unselected blockers. Derive action counts from the public manifests; a planned action is not a successful installation.

## Phase 5 — Separately authorized activation and runtime checks

**Scope:** design reviewable per-app activation with backups, conflict refusal, private permissions, dependency checks, and rollback before any live import. Activation is a separate future operation, not authorized by development work. Test only inert fixture homes and mocked commands here; real Linux runtime checks require an explicitly authorized disposable target. Windows validation waits for an available Windows machine.

**Acceptance tests:** dry preview contains every intended change; existing settings cannot be overwritten silently; runtime/package success is tracked independently from file conversion; no service/browser/process starts by default. Re-authentication is explicit. Windows DPAPI/app-bound logins, Windows-only applications, and backup-excluded data never receive a promise of literal operational equivalence.

## Validation and delivery gate for this change

Run all Python restore/package/migration fixtures, all Bash fixture suites and syntax checks, and PowerShell dispatcher fixtures if the runtime is available. Review the diff and scan changed files for credentials, private identifiers, and disallowed adult content. Do not extract production payloads or inspect secret files. Keep `docs/linux-restore-coverage.md` schema-based; do not bake a production release inventory into the migration contract. Update repository instructions only for a real contract change; no global `AGENT.md` edits. Commit and push the descriptive feature branch, open a focused PR against this repository's `main`, and inspect all PR comments/reviews/checks before merging. PR #10 is already merged and must not be reopened. Merge only when checks pass and no unresolved security or data-loss blocker remains, under the user's prior authorization. Do not submit upstream-project PRs or contact maintainers. Verify the final merged state or report the exact blocker. Do not change the short link.
