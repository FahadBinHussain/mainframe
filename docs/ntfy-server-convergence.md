# ntfy relay server convergence

how the fleet moves to a new approval relay: edit ONE vault item and
every machine converges to it on its next vault flow. no commands to
send, no rotation script, no phone step — the relay move is
machine-side only, and the old relay stays live as the fallback.

the server lives in the vault (item
`github.com/FahadBinHussain/mainframe / mainframe.ntfy-server`, a
secure note, the full relay `/ntfy` url in the notes — same shape as
the topic item `... / mainframe.ntfy-topic`). the sync mirrors the
topic convergence exactly (`Sync-VaultNtfyTopicFromVault` in
`windows/vault-approval.psm1`); the server version is
`Sync-VaultNtfyServerFromVault` in `windows/vault-ntfy-server.psm1`,
called from `windows/vault-flow.ps1` on both live-session paths
(cached session + fresh unlock). linux converges through the same
flow — there is no second, python copy.

## moving the relay

1. edit the vault item's notes to the new relay's `/ntfy` url. the
   value must be an https url whose path is exactly `/ntfy` (a
   trailing slash is trimmed). anything else is malformed: the sync
   warns loudly, ignores it, and the local config is unchanged.
2. every machine converges at its next vault flow with a live session:
   it reads the server from the vault, updates its local config
   (`ntfyServer` in the profile config and the checkout-root config,
   atomically, mode 0600), and logs the convergence loudly, naming the
   new relay in full. the server url is not a secret — the topic is
   the credential — so the log names it.
3. verify on a machine: run any vault flow and check the log line
   (`ntfy server converged from the vault (now <url>)`) and the
   config value. an already-converged machine stays silent and its
   config is not rewritten.

## what does not move

- a machine whose session is dead cannot read the vault: it keeps its
  local server until its next live flow. that is safe here — the old
  relay stays live, so the un-converged machine's approvals still go
  through. there is no phone-side deadline like the topic rotation
  has.
- a config that carries no `ntfyServer` at all is left alone: it keeps
  the `ntfy.sh` default. the sync only moves configs that already
  name a relay.
- no vault item yet → the local config is used, exactly as before.
  the item is created once, by hand, and the fleet converges from it.

## honest limits

- convergence needs a live session, same as the topic sync.
- the vault value is validated for SHAPE only (https + `/ntfy`
  path), not reachability: a well-formed url pointing at a dead host
  converges fine and the next approval fails loudly there. check the
  new relay answers before editing the item.
- the sync lives in its own module instead of next to the topic sync
  in `vault-approval.psm1` because that file was mid-edit when it
  landed; moving it in beside the topic sync is a clean-up for later,
  the behavior is identical either way.

tests: `tests/vault-approval-server-converge.Tests.ps1` (mock bw:
missing item, malformed values, trailing slash, both configs,
unparseable config, server-less config) +
`tests/test_linux_real_vault_server.py` (flow wiring).
