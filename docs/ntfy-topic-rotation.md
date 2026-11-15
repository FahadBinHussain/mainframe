# ntfy topic rotation

how to rotate the ntfy approval topic: the one procedure that moves the
topic on every machine + the phone. read the whole thing before running
anything — the phone adds the new topic FIRST and drops the old one
LAST, and the order matters.

the topic lives in the vault (item
`github.com/FahadBinHussain/mainframe / mainframe.ntfy-topic`) and the
machines converge to it automatically: run the script ONCE from any one
machine and every other machine picks the new topic up at its next
vault flow, with no commands sent to it. per-machine `-Topic` is the
fallback now, not the procedure.

context: audit 2026-11-15, findings H1 + M8. the topic is the ONLY
credential for the approval channel — anyone with it can read approval
requests and push fake approval cards — and until this procedure
existed there was no rotation mechanism at all.

## when to rotate

- the topic is suspected leaked, in any way: a pasted transcript, a
  screenshot, a shared log, a notification-access grant to an app you
  no longer trust.
- rotate NOW: the runner printed the topic to the terminal on every
  approval until 2026-11-15 (audit H1), so it may already sit in agent
  transcripts, logs, scrollback or screenshots. rotation is the
  recovery for that.
- after a phone loss, or after any approval card that looked wrong.

## the rule that makes it work

the topic is ONE value shared by every machine + the phone. a rotation
only works if all of them land on the SAME new value — and the vault is
what keeps them on the same value:

- generate the value ONCE, without applying it to any machine: a
  32-char `[a-z0-9]` string from a cryptographic rng (python
  `secrets`, or the script's plain run — but a plain run applies to
  that machine immediately, so prefer generating offline).
- run the script ONCE from any ONE machine: it writes the new value to
  the vault item FIRST, then to that machine's local config. every
  other machine converges from the vault at its next vault flow.
- ONE machine rotates at a time. two machines rotating together can
  leave the vault and a local config split; if that happens, rotate
  once more from a single machine to settle.
- never run it plain on a second machine: each plain run generates a
  DIFFERENT topic, and the fleet splits — a machine on a different
  topic than the phone sends approvals the phone never hears.
- per-machine `-Topic <value>` is the fallback, for a machine that
  cannot converge from the vault (session dead, vault unreachable).
  it is not the procedure anymore.

## rollout order

phone FIRST (adds the new topic, keeps the old), then ONE machine runs
the script, the other machines converge on their own, then the phone
drops the old topic, then verify.

0. generate the new value WITHOUT applying it to any machine: a 32-char
   `[a-z0-9]` string from a cryptographic rng (e.g. python `secrets`).
   the script's plain run also generates, but it applies to that
   machine immediately — prefer generating offline.
1. phone: ntfy app → subscribe to the new topic. KEEP the old
   subscription for now — the phone listens on both topics during the
   rotation, so no approval is ever unheard (see "phone steps" below).
2. run the script ONCE from any ONE machine, with the new value
   (`-Topic <new-topic>`) or a plain run. it writes the vault item
   first, then that machine's local config. the script FAILS LOUDLY if
   the vault session on that machine is dead — unlock first, then run
   it; nothing is written until the vault write succeeds.
3. every other machine converges automatically at its next vault flow
   (with a live session): it reads the topic from the vault, updates
   its local config, and logs the convergence loudly (4-char
   fingerprint only). no commands to send.
4. phone: drop the old subscription — ONLY after every machine has
   converged (see "verification" below).
5. verify: trigger one approval from each machine and confirm the phone
   shows it (see "verification" below).

why the phone adds first: a machine on a topic the phone is not
subscribed to sends approvals the phone never hears. with the phone
subscribed to both topics, every machine keeps working through its own
switch, and the verify step immediately after catches a machine that
was missed. (the old order — machines first, phone last — left every
switched machine unheard until the phone moved; do not use it.)

if a machine is offline or unreachable during the rotation, leave it:
it stays on the old topic and converges at its next live vault flow
once it is back — no command needed. it does not break the other
machines. keep the new value somewhere safe until every machine has
converged, and do NOT let the phone drop the old topic until then: a
machine whose session dies AND whose next live flow happens after the
phone drops the old topic sends its next approval to the old topic,
unheard.

## exact commands

from the mainframe repo root, on ONE machine only.

when the value was generated offline (the preferred route), apply it
with `-Topic` — this writes the vault item first, then the local
config:

    pwsh windows/rotate-ntfy-topic.ps1 -Topic <new-topic>

generating via the script instead: generates the new topic and shows it
(your terminal only; the value will land in logs/transcripts if the
output is captured). note this applies the new topic to that machine
immediately:

    pwsh windows/rotate-ntfy-topic.ps1 -ShowTopic

on machines where pwsh is not on PATH (the muse VMs), use the full
path:

    ~/.local/share/mainframe/tools/pwsh/pwsh windows/rotate-ntfy-topic.ps1 -ShowTopic
    ~/.local/share/mainframe/tools/pwsh/pwsh windows/rotate-ntfy-topic.ps1 -Topic <new-topic>

lost the value after a plain run? do NOT re-run plain — that rotates
again and generates a different topic. show the value already in the
config instead (changes nothing):

    pwsh windows/rotate-ntfy-topic.ps1 -ShowCurrent

fallback — a machine that must switch NOW instead of waiting for its
next vault flow, or whose convergence did not happen: apply the SAME
value directly with `-Topic <new-topic>`. the script still writes the
vault first (idempotent when the vault already holds the value), so
the session must be live. a session-dead machine cannot be rotated
this way at all — unlock it first (its approval goes to the OLD topic,
which the phone still hears until step 4 of the rollout), and it
converges at its next live flow.

## what the script does

- generates a new 32-char `[a-z0-9]` topic from a cryptographic rng
  (rejection-sampled, no modulo bias) — or applies the `-Topic` value
  after checking its format.
- writes it to the vault item FIRST
  (`github.com/FahadBinHussain/mainframe / mainframe.ntfy-topic`,
  securenote, topic in the notes). if the vault session is dead the
  script FAILS LOUDLY and writes nothing — not the vault, not the
  local config. if the item already holds the value, the write is a
  no-op (crash recovery: a run that died after the vault write but
  before the local write can be re-run safely).
- then writes it as `ntfyTopic` in the profile config
  (`~/.config/mainframe/mainframe.config.json` on linux,
  `%APPDATA%\mainframe\mainframe.config.json` on windows), resolved
  through the repo's own `Get-MainframeProfileRoot` when importable.
- updates the checkout-root `mainframe.config.json` too, IF it carries
  an `ntfyTopic`. if it exists without one, the script warns and leaves
  it alone.
- writes atomically (temp file + move), keeps mode 0600 on non-windows.
- refuses loudly and writes nothing if the profile config is missing or
  unparseable, or if it carries no `ntfyTopic` at all.
- never prints the topic by default. `-ShowTopic` / `-ShowCurrent` print
  it, with a warning that the value will land in logs/transcripts.

## phone steps (first add, last drop)

1. open the ntfy app.
2. subscribe to the new topic — type it in by hand (there is no
   automation for this step). double-check every character: the topic
   is 32 lowercase letters/digits, and one wrong character means the
   phone hears nothing on it.
3. KEEP the old subscription until every machine has converged (step 4
   of the rollout order). the phone listens on both topics meanwhile.
4. once every machine is on the new topic, drop the old subscription.
   nothing else to clean up on the phone.

## verification

right after the phone moves, trigger one approval FROM EACH MACHINE
(any vault operation that asks for approval) and confirm the phone
shows every card. the user decides when to run this — but run it
immediately after the phone moves, while the rotation is still fresh:
a machine that was missed shows up as an approval the phone never
receives. only after every machine's approval lands does the phone
drop the old subscription (step 4).

if the phone shows nothing for one machine's approval: that machine is
on the wrong topic. if its session is live, run any vault flow on it
(it converges from the vault) or re-run the script with the same value
(`-Topic <new-topic>`), then verify again. to compare what a machine
holds against the known value, run the script there with
`-ShowCurrent` (read-only, changes nothing).

if the phone ALREADY dropped the old topic and a machine is still on
it with a dead session, that machine is stuck: its approvals go to the
old topic, unheard, and it cannot unlock to converge. recover it by
re-subscribing the phone to the old topic temporarily (the old value
is kept somewhere safe until every machine has converged), letting the
machine unlock and converge, then dropping the old topic again. this
is why step 4 waits for every machine.

## honest limits

- the OLD topic stays usable. there is no relay-side deny list and no
  revocation: anyone who already knows the old topic can still read its
  (12 h) history and push cards to it — but the phone is no longer
  subscribed to it, so those cards go nowhere. rotation limits future
  exposure; it does not revoke the old topic.
- the topic must be typed into the phone by hand. there is no
  automation for that step, and no way to push the new topic to the
  phone from a machine.
- the new topic is only as secret as its handling: `-ShowTopic` /
  `-ShowCurrent` print it into the terminal, which lands in
  logs/transcripts if the output is captured. show it on your own
  terminal, copy it, and clear scrollback if you care.
- convergence needs a live session: a machine whose session is dead
  cannot read the vault, so it keeps using its local (old) topic until
  its next live flow. if the phone drops the old topic before that
  flow, the machine's next approval goes unheard (see "verification"
  for the recovery). the phone drops the old topic only after every
  machine has converged.
