# Linux restore implementation plan

Goal: maximize safe automatic migration from the Windows backup to native Linux without confusing preserved bytes, converted settings, installed software, and working applications. Work stays on `native-platform-bootstrap` / PR #10. Use free, portable/native defaults; never substitute an unrelated application.

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

**Progress: complete for this bounded scope.** Added `linux_migrations.py` with the versioned Git map and `--convert-portable` integration, separate sanitized conversion decisions, verified no-overwrite publication, private permissions, and cross-archive conflict refusal. Added 24 migration tests. All 63 Python restore/package/migration tests passed. Bash fixtures passed (43 dispatch checks, 3 forwarding checks, 12 offline boot checks); mocked PowerShell fixtures passed 33 checks. Bash syntax checks on all six shell entry/test files, Python compilation, and `git diff --check` passed. No production payload, real restore/bootstrap, package installation, live-home change, or secret decryption was used. Coverage and local repository workflow instructions now distinguish subset conversion from candidate copying and activation. Publication/security scan status is reported with the commit/PR delivery rather than implying full runtime validation here.

## Phase 2 — Per-application migration maps

**Scope:** replace broad candidate assumptions incrementally with exact source layouts, target versions/paths, allowlisted fields, path dependencies, and blocker rules. Prioritize mpv/yt-dlp and Flameshot preferences, then qBittorrent and OBS. Validate each against upstream format documentation and synthetic fixtures before enabling conversion. Browser profiles, rclone/account auth, scripts/plugins, caches, and database schemas are not portable merely because the app has a Linux build. Do not mass-copy unknown nested Windows layouts into a native profile and label them converted.

**Acceptance tests:** one fixture for each supported source layout/version, Windows-path and device references, unknown fields, malformed input, quick/full duplicates, sensitive-field exclusions, output conflicts, deterministic hashes, and preservation without activation. Coverage report names every implemented adapter and every remaining raw/candidate-only app. No guessed app substitutions.

## Phase 3 — Portable operating-system preferences

**Scope:** build explicit translators only for understood portable preferences (for example a reviewed environment-variable allowlist and file-association intent). Separate intent from desktop-specific activation. Never import Windows PATH, drive paths, registry shell commands, SIDs, service credentials, or task XML as Linux configuration. Leave unsupported desktop/session backends blocked; prefer native XDG mechanisms when verified.

**Acceptance tests:** registry encoding/escaping fixtures, known/unknown variables, unsafe commands, unavailable native handlers, desktop backend differences, deterministic intent output, no live settings changes. Tasks/services remain raw-only until their timing, commands, identity, and dependency semantics are understood.

## Phase 4 — Exact package and runtime reconciliation

**Scope:** extend explicit package mappings without variant drift; preserve requested versions and provenance. Keep `mpv-git`, `nodejs-lts`, unvalidated vendor sources, and Windows-only packages blocked until an exact supported route exists. Reconcile native requirements, architectures, package availability, Python wheels/ABI, Go/CGO, pnpm global paths, plugin dependencies, and intentional version differences. No paid services or unsolicited vendor account setup.

**Acceptance tests:** mocked APT/CLI availability, unavailable versions, exact variants, architecture/distro guards, Windows-only requirements, no network/install in default planning, and failure-before-execution for unselected blockers. Recompute the 82-action baseline only if mappings actually change; 40 planned / 42 blocked is not 40 installed.

## Phase 5 — Separately authorized activation and runtime checks

**Scope:** design reviewable per-app activation with backups, conflict refusal, private permissions, dependency checks, and rollback before any live import. Activation is a separate future operation, not authorized by development work. Test only inert fixture homes and mocked commands here; real Linux runtime checks require an explicitly authorized disposable target. Windows validation waits for an available Windows machine.

**Acceptance tests:** dry preview contains every intended change; existing settings cannot be overwritten silently; runtime/package success is tracked independently from file conversion; no service/browser/process starts by default. Re-authentication is explicit. Windows DPAPI/app-bound logins, Windows-only applications, and backup-excluded data never receive a promise of literal operational equivalence.

## Validation and delivery gate for this change

Run all Python restore/package/migration fixtures, all Bash fixture suites and syntax checks, and PowerShell dispatcher fixtures if the runtime is available. Review the diff and scan changed files for credentials, private identifiers, and disallowed adult content. Do not extract production payloads or inspect secret files. Update `docs/linux-restore-coverage.md` to distinguish new conversion evidence from the previous metadata-only production baseline. Update repository instructions only for a real contract change; no global `AGENT.md` edits. Commit and push this branch, verify PR #10 remains open, and report exact tests and blockers. Do not merge.
