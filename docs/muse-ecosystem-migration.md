# muse ecosystem migration (one muse account -> another)

status: first draft, 2026-11-15. living doc — update it while the workflow is
actually executed, whenever a step changes.

goal: move a user's whole muse ecosystem — memory, persona, rules, skills,
goals, work files — from one muse account (one VM) to another, so the new
muse picks up where the old one left off.

explicitly out of scope (do not move):
- chat history — no threads, no transcripts, no side chats.
- avatar and avatar name — the new account gets its own.

## inventory — what moves

measured 2026-11-15 on the source VM. core set is ~168 MB raw, 2,877 files
(plus the root files below).

### 1. core standing files (home directory)

| file | what it is |
|---|---|
| `~/MEMORY.md` | curated long-term memory (53 KB) |
| `~/SOUL.md` | persona and tone |
| `~/AGENTS.md` | the user's standing rules (20 KB, the most critical file) |
| `~/IDENTITY.md` | assistant name, character, vibe |
| `~/USER.md` | who the user is |
| `~/TOOLS.md` | local tool notes |
| `~/HEARTBEAT.md` | heartbeat note |
| `~/PROACTIVE_PREFERENCES.md` | what the user wants to hear about proactively |
| `~/config/skills.yaml` | preferred skills/connectors per task kind |

### 2. memory tree

- `~/memory/` (5.2 MB) — dated daily notes, `people/`, `groups/`.
- copy the `.md` files only. `memory/bank/` and `memory/index/` are runtime
  managed and regenerate on the new side; do not copy them.
- `~/dreams/alignment/` (148 KB) — alignment synthesis, how agent and user
  work together.

### 3. workspace

- `~/workspace/goals/` (51 MB) — one folder per goal, `GOAL.md` + `files/`.
- `~/workspace/custom-skills/` (19 MB) — learned skills.
- `~/workspace/custom-connectors/` (8 KB) — custom connector docs.
- `~/workspace/your_files/` (43 MB) + `~/workspace/user/` (50 MB) — the
  user's own files.
- rest of `~/workspace/` selectively. the full tree was 6.2 GB on 2026-11-15,
  mostly project scratch (`bk-*`, `monitor-cloud`, `mojify-board`, ...); take
  only the project folders still wanted.

### 4. sessions and secrets (optional, handle carefully)

- `~/.ssh/` — keys (e.g. tailscale SSH into the user's laptop).
- `~/.local/share/cloak/` — cloakbrowser saved sessions
  (`google-state.json`, `simular-state.json`, `box-token.txt`) + drivers.
  these are live login sessions: transfer only over a secure channel, and
  expect some to have expired by the time they land.

## what does not move by file copy (redo on the new account)

- connected accounts (gmail, github, drive, notion, ...) — reconnect via
  OAuth in the new account. tokens do not transfer.
- crons / scheduled jobs — recreate. `~/workspace/cron.d` holds the
  definitions to copy from.
- hooks — recreate.
- goals tab runtime state — the `GOAL.md` files move, the tab's status is
  re-set by hand.
- trusted-domain approvals — per account, re-approve as prompted.

## transfer methods

### method A (chosen): laptop edge route

1. user logs out of muse.ai in edge and logs into the new account, same
   profile. (one account per profile, so same profile means a logout/login
   swap; log back into the old account afterwards, nothing is lost there.)
2. pack the inventory (sections 1–3, plus 4 if wanted) into one archive on
   the source VM — one file, not thousands of writes.
3. drive edge from the laptop over SSH with the `browser-use` skill (CDP,
   real running edge, rule 22). open the new account's muse.ai tab.
4. push the archive into the new VM through the webapp's fs transport
   (`fs.write` over the gateway websocket; paths are relative to the new
   account's home).
5. send the new muse one message telling it to unpack the archive into
   place. it does the rest with its own shell.
6. verify (see below), then log back into the old account.

during the drive, leave edge alone — the browser-use daemon follows the
active tab, and clicks/typing can land on the owner's page. CDP toggle must
be on (`edge://inspect/#remote-debugging`).

### method B: export archive + manual upload

zip the core set, upload it into the new account's muse, ask it to unpack.
same archive as method A, no browser driving. fallback if the edge route
is unavailable.

### method C (not chosen): phone frida route

proven 2026-11-12: frida hooked into the muse android app on the rooted
phone can send messages (`chat.stream` over tigon HTTP/3, muse answered in
the thread). workable, but driving the app UI is more fragile than the
laptop route. details in automata-private under
`play.google.com-store-apps-details-id-com.facebook.aura`.

### what does not work

- the android ABRA token is ASR-only (shortwave websocket handshake). it
  cannot send chat messages.
- the noise tokens on disk (`vm_auth` / `vm_notary`) do not buy an outside
  send: the notary endorsement is restricted to a VM hostname that is
  NXDOMAIN outside, and `chat.stream` is noiseOnly — nothing outside the
  page/app gateway can authenticate it. measured 2026-11-12.

## verification checklist

after the unpack, in a fresh chat on the new account:

1. new muse reads `~/MEMORY.md` back (spot-check one fact it could only
   know from the file).
2. `~/workspace/custom-skills/` count matches the source.
3. `~/workspace/goals/` count matches the source.
4. `~/AGENTS.md` hash matches the source file.
5. standing rules apply in a normal turn (e.g. the ADHD output shape, no
   silent fallbacks).

## open questions (resolve during execution)

- fs transport limits: max single `fs.write` size / chunking for a ~100 MB
  archive — measure on the first push, chunk if needed.
- whether the new muse's own memory writer ever overwrites the imported
  `~/MEMORY.md` — watch the first few turns.
- cron recreation list: enumerate the live crons before the move so none is
  forgotten.
