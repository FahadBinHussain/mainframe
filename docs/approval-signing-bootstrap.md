# approval signing key bootstrap

implemented - the module and the page landed together; this doc is the
record of the design and of the registration steps for a new machine.
the one companion piece outside this repo is the relay's key list,
covered under implementation status at the end.

## the problem

a brand-new machine cannot make its first vault approval request.

approval links are signed (`New-VaultApprovalDescriptorSignature`), and
the phone refuses an unsigned one - that part is right and stays. the
signing key is a stable RSA pair whose private half lives in exactly
two places:

- the bitwarden vault, as
  `github.com/FahadBinHussain/mainframe/mainframe.approval-signing.key`
- a checkout that `env-sync.ps1 -Repo mainframe` has already restored

on windows that is enough: setup is interactive, env-sync runs while a
human is unlocking things anyway, and the key is on disk before the
first approval is ever needed.

on an agent-driven linux box it circles: the restore asks the vault for
the release token, the vault asks the phone for approval, the approval
link has to be signed, and the signing key is inside the vault it is
trying to open. the run dies at the vault leg with "the approval
signing key is missing". found on a fresh vm restore on 2026-11-07 -
the machine had simply never been given the file.

## what also broke on the way there

`Get-MainframeCheckoutRoot` (mainframe-paths.psm1) built its candidate
list eagerly, so `Join-Path $env:USERPROFILE ...` threw a null bind
error on linux - USERPROFILE does not exist there - before the `$HOME`
candidates were tried. the signing-key lookup is the first linux caller
of that function, so the crash hid the real "key is missing" message
behind a cryptic one. fixed in this branch (the candidate is only added
when the variable is set) with a regression check in
`tests/mainframe-paths.Tests.ps1`.

## the fix: per-machine signing keys

stop moving one shared private key to every machine. a machine should
be born with its own key, and only public keys should ever travel.

1. **first run generates the key.** when
   `Get-VaultApprovalSigningKey` finds no key file, it generates an
   RSA-2048 pair in the same JSON shape, writes it to
   `mainframe.approval-signing.key` next to the config (mode 600 /
   gitignored, as now), and stops with a message that prints the
   PUBLIC half (base64url SubjectPublicKeyInfo - the same string
   `Get-VaultApprovalPublicKey` returns) plus the registration steps
   below. generating is not enough to approve anything: until the
   public half is registered, the phone and the relay still refuse
   this machine, which is the correct state for an unknown box.
2. **the page trusts a list.** `docs/vault-tab.html` currently bakes in
   one public key; it takes a list instead and accepts a descriptor
   signed by ANY key on it. bump the page version (`signed2`) so cached
   old pages are not used.
3. **the relay trusts the same list.** `MF_APPROVAL_PUBLIC_KEY` on the
   relay accepts several keys (comma-separated SPKI strings), and the
   relay checks a publish against all of them. the relay lives in the
   private automata-private repo - that part is a separate change
   there, with its `test/page-signature.test.mjs` extended to two keys.
4. **registration is the only per-machine step, and it is public.**
   adding a machine = add its public key to the page list (a commit
   here) and to the relay env, redeploy both. no secret moves, no vault
   access needed, and an agent can open that commit as a PR by itself -
   which is the whole point: the next vm sets itself up without a human
   carrying a private key to it.
5. **revocation is deleting a line.** a lost or retired machine loses
   the ability to get approvals signed the moment its key leaves both
   lists. today one leaked key file is every machine at once.

## migration

- the current shared key stays on both lists as entry one - the
  existing windows setup keeps working untouched.
- each other machine generates its own key on its next approval
  request and gets registered once.
- when every live machine has its own key, the shared key comes off
  the lists and the vault copy is retired. until then nothing about
  the current flow changes.

## the alternative, if the list change is too much

seal the existing shared key the way `bw-email.enc.json` is sealed
(PBKDF2-HMAC-SHA256, AES-256-CBC, HMAC over the lot, key derived from
the master password) and commit the sealed blob. a new machine
unseals it with one interactive master-password entry at first setup -
the same moment windows boot already asks for - and writes the key
file. smaller diff (no page or relay change), but the shared private
key still lives on every machine, a sealed copy sits in a public repo
resting entirely on the master password, and an agent-driven box still
needs a human to type that password once. it fixes the circle; it
keeps the blast radius.

## also, regardless of which design lands

- **fail before the run, not inside it.** `linux_real.py` / the boot
  flow should check for the signing key while it checks prerequisites
  and stop there with the one-line fix, instead of discovering it
  halfway through the vault leg.

## pieces to change

- `vault-approval.psm1` - generate-on-missing in
  `Get-VaultApprovalSigningKey`, with the public key and the
  registration steps in the stop message. the descriptor format and
  the signing itself do not change.
- `docs/vault-tab.html` - trusted key list, page version bump.
- the relay (automata-private) - `MF_APPROVAL_PUBLIC_KEY` as a list.
- `linux_real.py` / boot flow - the pre-flight key check.
- tests - `tests/vault-approval-descriptor.Tests.ps1`: the generated
  key signs and verifies, a second key on the list verifies, an
  unlisted key does not. relay tests in automata-private for the
  multi-key publish check.

## implementation status

- `vault-approval.psm1` - done. `Get-VaultApprovalSigningKey` mints the
  pair via `New-VaultApprovalSigningKeyFile` when nothing was
  provisioned or configured, writes it at the resolved key path (mode
  600 on unix), and stops with the public key and the registration
  steps in the message. An explicitly configured key that is missing
  still throws the vault-restore message. The approval page version
  bumped to `signed2`, because the page's verification changed.
- `docs/vault-tab.html` - done. `APPROVAL_PUBLIC_KEYS_B64URL` is a list
  and `verifyDescriptor` tries each key. The first entry is the
  original shared key (the windows machine); the second is the linux
  vm that found the bootstrap gap, registered by the same change that
  implemented all of this.
- tests - `tests/vault-approval-descriptor.Tests.ps1`: check 3 now
  asserts this machine's key is IN the page list (it fails on purpose
  on a generated-but-unregistered machine), and check 8 pins the
  mint-and-stop behaviour hermetically.
- the relay - companion change, in the relay's own repo and deploy
  flow: `MF_APPROVAL_PUBLIC_KEY` is read as a comma-separated list of
  SPKI strings, and `public/docs/vault-tab.html` is refreshed with
  `sync-page.ps1` before the redeploy, so the served page carries the
  same list as this repo. Until that redeploy lands, the relay still
  trusts only the original key - a new machine can be refused by the
  relay even though the page would accept it, so register and redeploy
  before a new machine's first real request.

registration for a new machine, end to end: run any vault request once
(it stops with the public key) -> add the key to the page list here and
to `MF_APPROVAL_PUBLIC_KEY` on the relay -> sync the page copy and
redeploy the relay -> run again. No private key ever moves.

## not changing

- the descriptor format, the single-flight queue, the relay credential
  rules - untouched.
- no unsigned mode, no skip-signing flag. a machine that cannot sign
  stops, exactly like today; it just stops with its own key half-made
  and a public string to register instead of a vault errand.
