# Vercel on Linux: standard Node CLI, dry planning only

Linux support is not the blocker. [Vercel documents `pnpm i -g vercel`](https://vercel.com/docs/cli), with Node available to run the CLI. This adapter plans that product, not experimental native Vercel execution, another CLI, or a script-suppressed substitute. It does not install anything.

## What the planner checks

`linux_packages.py --pnpm-plan-config /absolute/path/to/roots.json` uses the existing allowlist unchanged. Only the `vercel` entry gains the new detailed plan; other global tools are unchanged. The generic helper in `pnpm_global_plan.py`:

- Resolves the npm registry's current `latest` manifest and records its immutable version, exact registry tarball URL and SHA-512 integrity. Missing/invalid identity, version, source or integrity fails closed. Metadata is not downloaded archive verification or an independent signature.
- Requires the existing, pinned official Node LTS and standalone pnpm release metadata from the native actions. It validates their source contracts without installing or running either runtime. The proposed Node version must satisfy Vercel's engine, pnpm's registry engine and every engine declared by the inspected exact direct dependencies. Unknown engine syntax fails closed. These are metadata compatibility checks, not binary probes.
- Inspects installation hooks (`preinstall`, `install`, `postinstall`) on the root and exact direct dependencies. Other scripts such as `build` and `test` are not automatically treated as tarball installation hooks. Non-exact dependency ranges, transitive/peer/optional resolution and implicit node-gyp builds remain explicit execution prerequisites, not a pretend lockfile.
- Requires all isolated paths explicitly. It rejects existing roots, aliases, nested roots, relative/traversal paths, symlink parents and overlap with the live home, repository, backup or protected system paths. It creates none of them.

The current global/config/build-policy contract is reviewed for pnpm **12**. A different major blocks rather than guessing its behavior. [pnpm's installation documentation](https://pnpm.io/installation) distinguishes the Node requirement for an npm-installed pnpm from standalone pnpm: this plan uses the already-declared **standalone** native pnpm artifact, so it does not bootstrap npm/pnpm or run pnpm's npm-package installation hooks. Node is still necessary for the standard Vercel CLI.

## Required isolated paths

The JSON file contains only a `roots` object with all these keys. Paths below are illustrative future destinations, not created defaults:

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

Runtime roots refer to proposed future installs, not a claim that binaries already exist. Package roots are independent of both runtime roots and of one another. No root is inferred from the current user's home, PATH, profiles, or backed-up Windows pnpm configuration.

The output has a draft argument array with explicit pnpm machine-path settings, a pinned package version, an isolated working directory and a **fresh child environment proposal**. It routes HOME, PNPM_HOME, XDG config/cache/data/state, npm user/global configuration, cache, temporary directories and child PATH to explicit destinations. None of these values changes the current process environment. A future executor must verify effective paths/configuration with the selected pnpm binary before installing; merely printing these paths does not prove pnpm honored them. See [global package layout](https://pnpm.io/global-packages) and [machine settings](https://pnpm.io/settings).

## Install scripts are real work

Vercel's current root manifest has no install lifecycle hook, but its pinned dependency [esbuild](https://github.com/evanw/esbuild/blob/main/npm/esbuild/package.json) has `postinstall: node install.js`. The planner reads the **version Vercel declares**, not esbuild's unrelated latest release, and records the actual hook text and versioned registry source.

The draft plan does **not** assume `--ignore-scripts` is successful or safe. It proposes `ignoreScripts=false`, `strictDepBuilds=true`, `dangerouslyAllowAllBuilds=false` and targeted `--allow-build` entries for the inspected dependencies with installation hooks. This is a **proposal**, not an approval written to a configuration file and not authorization to execute it. Unknown transitive builds must remain strict failures. [pnpm's build settings](https://pnpm.io/settings/build) and [global build approval](https://pnpm.io/cli/approve-builds) explain that lifecycle approval is separate from fetching the package.

The documented `--allow-build=esbuild` flag is **name-wide**, not limited to the inspected version. Output therefore also records the required exact-version `allowBuilds` matchers. Replacing the draft name-wide entries with a reviewed version-scoped policy after full lockfile review is an explicit execution blocker; the draft flag is never permission to run arbitrary versions of that package.

Keep normal optional dependency behavior: do **not** add `--no-optional`, which can remove esbuild's platform binary. Let pnpm's resolver apply OS/CPU/libc compatibility. The optional native Vercel packages may be fetched as part of its standard package metadata, but this plan never enables experimental native execution, runs an upgrade command, or suppresses all optional dependencies to avoid them. Full optional/platform resolution still belongs to the future lockfile review.

## What remains blocked

A successful detailed result says `status: dry-only` and `executable: false`. The enclosing Vercel action remains `blocked` for installation and the planner exits nonzero while blockers exist. It intentionally has **no executable action command**; its draft command lives only inside `dry_plan.proposed_command`.

`--pnpm-plan-config` cannot be combined with `--execute`. Even a hand-built global action remains rejected by the existing executor before any earlier selected APT/native mutation. No Node/pnpm/Vercel process, npm lifecycle script, login, deployment, backup/secrets change, profile edit or vendor-terms acceptance is performed by this feature.

Before installation can be separately implemented/authorized, resolve and review the complete lockfile and every runtime/platform/integrity/build prerequisite, verify the runtimes and pnpm's effective path settings, and implement race-safe root creation/publication. Lifecycle scripts can launch processes, use native toolchains and access the network: path isolation alone is **not an OS sandbox**. This PR does not claim otherwise or unblock operational restoration.
