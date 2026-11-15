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

- run the script plain (or with `-ShowTopic`) on the FIRST machine
  only — that run generates the new topic.
- every other machine gets that SAME value with `-Topic <value>`.
- never run it plain on a second machine: each plain run generates a
  DIFFERENT topic, and the fleet splits — a machine on a different
  topic than the phone sends approvals the phone never hears.

## rollout order

A → B → laptop → desktop → phone LAST, then verify.

1. A (muse VM): generate + show the new topic, note the value.
2. B (muse VM): apply the SAME value with `-Topic`.
3. laptop, then desktop: apply the SAME value with `-Topic`.
4. phone LAST: ntfy app → subscription → change the topic to the new
   value (see "phone steps" below).
5. verify: trigger one approval and confirm the phone shows it (see
   "verification" below).

why the phone is last: any machine still on the old topic after the
phone moves sends approvals the phone never hears — its approval
requests go to a topic nothing is listening to. moving the phone last
keeps every not-yet-rotated machine working until its turn, and the
verify step immediately after catches a machine that was missed.

if a machine is offline or unreachable during the rotation, leave it:
it stays on the old topic and its approvals will not reach the phone
until it is rotated. it does not break the other machines. rotate it
the same way (`-Topic <value>`) as soon as it is back — keep the new
value somewhere safe until every machine has it.

## exact commands

from the mainframe repo root on each machine.

first machine — generates the new topic and shows it (your terminal
only; the value will land in logs/transcripts if the output is
captured):

    pwsh windows/rotate-ntfy-topic.ps1 -ShowTopic

every other machine — applies the SAME topic (no output value):

    pwsh windows/rotate-ntfy-topic.ps1 -Topic <new-topic>

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

## phone steps (last)

1. open the ntfy app.
2. open the subscription for the approval topic.
3. change the topic to the new value — type it in by hand (there is no
   automation for this step). double-check every character: the topic
   is 32 lowercase letters/digits, and one wrong character means the
   phone hears nothing. if your ntfy version has no edit action,
   unsubscribe from the old topic and subscribe to the new one —
   same result.
4. save. the old subscription is gone the moment the topic changes;
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
