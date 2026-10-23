# Vercel on Linux: supported Node CLI, guarded dry plan

[Vercel supports `pnpm i -g vercel`](https://vercel.com/docs/cli). Linux support is not the blocker. This planner uses that ordinary Node-based CLI, not experimental native execution, npm fallback, or a script-suppressed substitute. It does not install or run anything.

## What is now pinned

`linux_packages.py --pnpm-plan-config /absolute/path/to/roots.json` leaves the allowlist unchanged and adds Vercel's detailed plan. `pnpm_global_plan.py` resolves the official npm registry's current `latest` version, then reads its exact-version endpoint. All recorded install-relevant metadata must agree, including integrity, hooks, dependencies, optional/peer dependencies, optional-peer metadata, both bundled-dependency spellings, the registry's implicit-install-script flag, engines, platform declarations and bin metadata. This binds the recorded inventory, not every possible package-manager extension or uninspected archive field. Inconsistent endpoints fail closed. A later change requires a new plan, not a floating install.

The root and every inspected exact direct/optional dependency have a version, official registry tarball URL and canonical SHA-512 SRI. Non-exact ranges remain explicit. This is **metadata inventory, not a dependency solver, verified tarball, or complete lockfile**. Transitive, peer, bundled and archive-only/implicit `binding.gyp` builds still need artifact/lockfile review. Optional dependencies override duplicate regular dependency names, as normal package-manager semantics require; optional binaries are not discarded.

Official pinned Node LTS and standalone pnpm release metadata are validated through the existing adapters. The Node version must satisfy Vercel, pnpm and every inspected dependency that declares a Node engine. Unknown engine grammar or an incompatible minimum fails closed. This contract is limited to pnpm 12 and Linux/glibc x86_64. Metadata compatibility is not an executed runtime probe. Standalone pnpm is used directly, without installing pnpm through npm or executing its npm-package lifecycle scripts.

## Explicit independent paths

The config contains only `roots`, with every key below. These are illustrative future paths; the planner creates none of them:

```json
{
  "roots": {
    "node": "/srv/restore-preview/node-runtime",
    "pnpm": "/srv/restore-preview/pnpm-runtime",
    "pnpm_home": "/srv/restore-preview/pnpm-home",
    "global": "/srv/restore-preview/global-packages",
    "bin": "/srv/restore-preview/global-bin",
    "store": "/srv/restore-preview/package-store",
    "cache": "/srv/restore-preview/cache",
    "config": "/srv/restore-preview/config",
    "state": "/srv/restore-preview/state",
    "data": "/srv/restore-preview/data",
    "home": "/srv/restore-preview/isolated-home",
    "temp": "/srv/restore-preview/temp",
    "work": "/srv/restore-preview/work"
  }
}
```

All roots must be absolute, distinct, non-overlapping, new, and free of symlink parents. Live HOME, repository, backup and protected system paths are rejected. Runtime roots are independent of package/bin/store roots. Expected Node and pnpm executables are `node/bin/node` and `pnpm/pnpm` beneath the corresponding roots.

[pnpm's global layout](https://pnpm.io/global-packages) normally derives global packages and bin paths from pnpm home. The draft explicitly overrides `globalDir` and `globalBinDir`, including the documented `PNPM_CONFIG_GLOBAL_DIR` and `PNPM_CONFIG_GLOBAL_BIN_DIR` environment overrides ([pnpm issue #14336](https://github.com/pnpm/pnpm/issues/14336)). `expected_global_install_base` is `v11` beneath the configured global root, **not** the pnpm runtime directory. Its `layout_contract` records the selected pnpm version, documentation source and `confirmed_by_probe=false`; this is not a guarantee for every pnpm 12 patch release. A mismatch must block before installation. The expected global bin is the independent `bin` root; the store root is independent too. Version/platform subdirectories managed by pnpm are allowed within the designated roots. `effective_paths.status` is **expected-not-probed**: a printed setting is not evidence that the installed binary honors it.

A future executor must compare pinned runtime identity/version, effective configuration, `pnpm bin -g`, `pnpm store path`, and install-group layout to these expectations before package installation. It must reject ancestor workspace/config discovery, automatic runtime/package-manager provisioning, and unexpected paths. No `pnpm setup`, shell-profile edit or live PATH change is appropriate.

The proposed environment is a fresh allowlisted child environment, **not an overlay on the user's environment**. HOME, PNPM_HOME, XDG config/cache/data/state, npm configuration, cache, temp and child PATH are explicit. The selected Node directory comes first; pnpm global runtime shims are disabled in the proposal. Tokens, `NODE_OPTIONS`, ambient npm/pnpm configuration, Vercel native-mode flags, and private state are not inherited. Parent HOME/PATH/environment remain unchanged. An isolated cwd alone does not prevent ancestor configuration discovery; validating that boundary is an executor gate, not a completed claim.

## esbuild is real work, not silently skipped

Vercel's resolved direct esbuild version is inspected dynamically, not hardcoded and not replaced with esbuild's unrelated latest. Its actual `postinstall: node install.js`, exact version, source and SRI are recorded in `script_policy.approval_requirements`, along with a hash of the recorded metadata. The metadata hash is a drift identifier, **not** a script-code hash or security approval.

There are **no `--allow-build` flags and no name-wide approvals** in the draft. [pnpm supports exact-version `allowBuilds` matchers](https://pnpm.io/settings/build), but `esbuild@<resolved-version>` is recorded as **review-required**, not granted. Each requirement has `approval: required-not-granted`. No approval file is written. The future reviewed policy must bind the exact graph/artifact integrity and actual script effects, not merely a familiar package name or a version string. Root hooks, if introduced, also require review; dependency approval settings are not assumed to contain root scripts.

The ordinary install must eventually run the required approved scripts. The proposal keeps `ignoreScripts=false`, `strictDepBuilds=true` and `dangerouslyAllowAllBuilds=false`. It disables inherited pnpmfile hooks and side-effects cache reuse; it does not suppress esbuild's install work. `strictDepBuilds` reports unreviewed builds, but **is not a transaction or pre-mutation gate**: pnpm can write/fetch, or run approved work, before reporting an unknown build. Consequently it cannot replace full preflight review before any selected action mutates.

Keep normal optional dependencies. Do not add `--no-optional`: that can remove esbuild's platform binary. pnpm applies OS/CPU/libc selection. Optional Vercel native packages may be present as ordinary package metadata; no native execution is enabled, no Vercel upgrade command is run, and no Vercel invocation is performed.

## Dependency integrity is pnpm's job, not a claim about metadata

[pnpm's store settings](https://pnpm.io/settings/store) distinguish cached-content verification from package identity checks. The draft explicitly sets `verifyStoreIntegrity=true`, `strictStorePkgContentCheck=true` and `engineStrict=true`. The future reviewed lockfile must pin every resolved registry artifact, including transitive, peer and optional packages, to identity, approved registry URL and SRI. pnpm validates fetched tarballs against resolution integrity; cached file verification and strict package-content checks must remain enabled.

Those checks do not authenticate publisher intent, approve lifecycle code, prove full-graph compatibility, or make a store writable by untrusted users safe. Use new private roots; do not reuse live caches or treat a root-package checksum as dependency verification. This dry plan downloads no package artifacts and makes no claim that any archive has been verified.

## The specific remaining blocker

**There is no reviewed pnpm-resolved full dependency/build closure.** Registry manifests alone cannot safely finalize the exact-version lifecycle policy or prove every transitive/peer/optional artifact and implicit build. Generating and validating that closure requires package-manager/artifact validation, which is deliberately outside this metadata-only, no-package-manager task. Substituting a home-grown partial resolver, granting all esbuild versions permission, or treating a failed strict build as rollback would be false assurance.

The result therefore remains `status: dry-only`, `executable: false`; the enclosing Vercel action remains blocked with one specific closure blocker. Separate `future_executor_gates` preserve the requirements for a reviewed executor, effective runtime/path probes, full failure-before-mutation preflight, script/network/toolchain trust review, and race-safe no-replace root publication. Path routing is **not an OS security sandbox**.

`--pnpm-plan-config` cannot be combined with `--execute`. Even a hand-built global action is rejected before earlier selected APT/native actions can run. Nothing here installs Node/pnpm/Vercel, invokes lifecycle scripts, authenticates, deploys, changes backup/secrets/profile state, removes allowlist entries, accepts terms, or claims operational restoration.
