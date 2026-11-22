# approval signing key bootstrap — RETIRED 2026-11-15

this doc records a design that no longer exists. it stays so nobody
re-adds it without knowing why it went away.

## what it was

every machine minted its own RSA-2048 approval signing key on first
use (`Get-VaultApprovalSigningKey` in `windows/mainframe.ps1`). the runner
signed each approval link's descriptor
(`New-VaultApprovalDescriptorSignature`), and two lists decided which
machines the phone and the relay trusted:

- `APPROVAL_PUBLIC_KEYS_B64URL` in `docs/vault-tab.html` (a commit here)
- `MF_APPROVAL_PUBLIC_KEY` on the relay (env var + redeploy)

a new machine's first approval run minted its key and then STOPPED with
the public half to register. until the key was on both lists, the phone
refused its links and the relay refused its publishes.

## why it was removed

every new machine needed a manual registration step: a commit to the
page list, a relay env change, and a redeploy — before it could get a
single approval. on 2026-11-15 a fresh Muse VM hit exactly that wall
during its mainframe restore (its first approval run died minting a key
nobody had registered), and the user ordered the whole registration
design out: the ntfy topic is the credential, and no per-machine list
is worth the friction.

## what stays

the per-machine RSA key pair itself — but as an ENCRYPTION key only,
not a signing key. the approval page encrypts the master password to
the runner's public half (`k` in the link, RSA-OAEP), so only the
runner can read it back; the relay never sees the password in the
clear. a fresh machine mints its pair on first use and proceeds —
no list, no registration, no stop. the function and file names still
say "signing" (`Get-VaultApprovalSigningKey`,
`mainframe.approval-signing.key`, `MAINFRAME_APPROVAL_SIGNING_KEY`);
renaming them would break every existing machine's key file and env
var for no behaviour change, so the names stay and this doc is the
record of what they mean now.

## what replaced the verification

nothing mechanical. the link only reaches the phone through the ntfy
topic, and the topic (a random 32-char name) is the credential:
whoever knows it can send a link. the phone card shows host, agent,
model and the verification code, so a link from an unrecognised machine
stands out — the human check is the forgery defence now. the relay
authorises publishes and sid-topic reads by topic knowledge (the phone
still presents `MF_RELAY_AUTH` to read the main topic).

## the original problem it solved (still solved, differently)

2026-11-07: a fresh agent-driven linux box could not make its first
approval because the signing key lived inside the vault it was trying
to open — the restore died at the vault leg with "the approval signing
key is missing". the per-machine mint fixed the circle (the key is born
on the machine, never fetched from the vault). that fix survives: the
mint-on-first-use behaviour is unchanged, only the registration stop
after it is gone.

## what was removed, for the record

- `windows/mainframe.ps1`: `Get-VaultApprovalDescriptor`,
  `New-VaultApprovalDescriptorSignature`, the descriptor/signature
  params and `X-MF-Desc`/`X-MF-Sig` headers on the publish/poll
  functions, the mint-and-stop throw, the `signed2` page version
  (now `topic1`).
- `docs/vault-tab.html`: `APPROVAL_PUBLIC_KEYS_B64URL`,
  `verifyDescriptor`, `buildDescriptor`, `descriptorHeaders`,
  `refuseUnsigned`, the `sig` link param.
- the relay (automata-private `cloudflare.com/mainframe-vault-relay`):
  `signatureVerifies`, the `signature` authorise path,
  `notificationIsSigned` / `filterSignedNotifications`,
  `MF_APPROVAL_PUBLIC_KEY` (the env var is no longer read; remove it
  from the worker's secrets when convenient).
- tests: `tests/vault-approval-descriptor.Tests.ps1` became
  `tests/vault-approval-key.Tests.ps1` (mint-and-proceed, OAEP
  round-trip, no-trust-list regression checks).
