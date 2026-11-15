# ntfy topic rotation

how to rotate the ntfy approval topic: the one procedure that moves the
topic on every machine + the phone. read the whole thing before running
anything — the phone moves LAST, and the order matters.

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
only works if all of them land on the SAME new value:

- generate the value ONCE, without applying it to any machine: a
  32-char `[a-z0-9]` string from a cryptographic rng (python
  `secrets`, or the script's plain run — but a plain run applies to
  that machine immediately, so prefer generating offline).
- every machine gets that SAME value with `-Topic <value>`.
- never run it plain on a second machine: each plain run generates a
  DIFFERENT topic, and the fleet splits — a machine on a different
  topic than the phone sends approvals the phone never hears.

## rollout order

phone FIRST (adds the new topic, keeps the old), then the machines,
then the phone drops the old topic, then verify.

0. generate the new value WITHOUT applying it to any machine: a 32-char
   `[a-z0-9]` string from a cryptographic rng (e.g. python `secrets`).
   the script's plain run also generates, but it applies to that
   machine immediately — prefer generating offline.
1. phone: ntfy app → subscribe to the new topic. KEEP the old
   subscription for now — the phone listens on both topics during the
   rotation, so no approval is ever unheard (see "phone steps" below).
2. A, then B, then laptop, then desktop: apply the SAME value with
   `-Topic <new-topic>`.
3. phone: drop the old subscription.
4. verify: trigger one approval and confirm the phone shows it (see
   "verification" below).

why the phone adds first: a machine on a topic the phone is not
subscribed to sends approvals the phone never hears. with the phone
subscribed to both topics, every machine keeps working through its own
switch, and the verify step immediately after catches a machine that
was missed. (the old order — machines first, phone last — left every
switched machine unheard until the phone moved; do not use it.)

if a machine is offline or unreachable during the rotation, leave it:
it stays on the old topic and its approvals will not reach the phone
until it is rotated. it does not break the other machines. rotate it
the same way (`-Topic <value>`) as soon as it is back — keep the new
value somewhere safe until every machine has it.

## exact commands

from the mainframe repo root on each machine.

when the value was generated offline (the preferred route), every
machine — including the first — applies it with `-Topic`:

    pwsh windows/rotate-ntfy-topic.ps1 -Topic <new-topic>

generating via the script instead — first machine only: generates the
new topic and shows it (your terminal only; the value will land in
logs/transcripts if the output is captured). note this applies the new
topic to that machine immediately:

    pwsh windows/rotate-ntfy-topic.ps1 -ShowTopic

on the muse VMs pwsh is not on PATH; use the full path there:

    ~/.local/share/mainframe/tools/pwsh/pwsh windows/rotate-ntfy-topic.ps1 -ShowTopic
    ~/.local/share/mainframe/tools/pwsh/pwsh windows/rotate-ntfy-topic.ps1 -Topic <new-topic>

lost the value after a plain run? do NOT re-run plain — that rotates
again and generates a different topic. show the value already in the
config instead (changes nothing):

    pwsh windows/rotate-ntfy-topic.ps1 -ShowCurrent

## what the script does per machine

- generates a new 32-char `[a-z0-9]` topic from a cryptographic rng
  (rejection-sampled, no modulo bias) — or applies the `-Topic` value
  after checking its format.
- writes it as `ntfyTopic` in the profile config
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
3. KEEP the old subscription until every machine has switched (step 2
   of the rollout order). the phone listens on both topics meanwhile.
4. once every machine is on the new topic, drop the old subscription.
   nothing else to clean up on the phone.

## verification

right after the phone moves, trigger one approval (any vault operation
that asks for approval) and confirm the phone shows the card. the user
decides when to run this — but run it immediately after the phone
moves, while the rotation is still fresh: a machine that was missed
shows up as an approval the phone never receives.

if the phone shows nothing for one machine's approval: that machine is
on the wrong topic. re-run the script on it with the same value
(`-Topic <new-topic>`) and verify again. to compare what a machine
holds against the known value, run the script there with
`-ShowCurrent` (read-only, changes nothing).

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
- a `mainframe.config.json` in the current working directory can still
  shadow the topic on reads (audit M7, fixed separately) — run the
  rotation from the repo root, and keep stray configs out of working
  directories.
