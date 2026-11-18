# Manager conventions

Single source of truth for the manager chat on EVERY Muse account.
Fahad runs 10-12 Muse accounts — this one file governs all of them, so a
convention never has to be re-typed per account.

## How it stays in sync

- **Update:** any agent that changes a convention edits THIS file, commits,
  and pushes to mainframe. Never edit a per-account copy as the source.
- **Pull:** every Muse account pulls this file into
  `~/workspace/manager/CONVENTIONS.md` with `muse/pull-conventions.sh` —
  at restore time and whenever conventions change.
- Per-account copies (`~/workspace/manager/CONVENTIONS.md`, MEMORY.md
  bullets, in-thread messages) are snapshots, never the source. If a copy
  disagrees with this file, this file wins.

## The conventions

Set by the user 2026-11-17, rule 8 added 2026-11-18.

1. **One manager chat per Muse account, named "manager".** The user gives tasks there. The manager delegates to project chats, tracks each delegation, and reports completion back in the manager chat.
2. **Side chats are named after their GitHub repo** (e.g. `bolo-key`, `bolo-key-windows`, `diit-ams`). Chats with no repo keep a short topic name. Rename when a chat's repo or purpose changes — never per task.
3. **Never give the user bare chat/thread IDs.** Always use the chat's real name plus what it's for (e.g. "reddit chat-e", "B-er manager chat-e").
4. **Same-type work goes to the same chat** so nothing gets dropped. The manager tracks every delegation until it lands.
5. **Never assume a delegation is done.** Always read the agent's replies and verify the result before reporting completion.
6. **Cross-account talk goes manager-to-manager.** The AGENTS.md-sync thread is sync-only (the Monitor pushes AGENTS.md deltas there) — never the cross-account talk channel.
7. **Two Muse accounts never share the same Muse name.** Each account's Muse has its own distinct name (e.g. A is Haru, B is Kangaroo) — same names caused the A/B swap confusion.
8. **Never change any Muse's avatar or name without the user's explicit approval.** This applies to the manager itself and to every Muse it delegates to — no name or avatar change, ever, unless the user explicitly approved that change.
