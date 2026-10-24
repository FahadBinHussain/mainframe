# Vercel pnpm plan: metadata only, still blocked

## What the dry plan records

The package allowlist continues to name `vercel` without a version. A default package plan does not query npm for Vercel. With explicit `--pnpm-plan-config` and new, distinct isolated roots, the dry planner reads npm JSON metadata for `vercel/latest`, verifies that the exact root-version endpoint agrees on recorded fields, and records the root version, registry SRI, Node engine, lifecycle-hook metadata, and exact direct dependencies. Exact-version Linux optional `@vercel/vc-native-*` entries also carry their registry version, SRI, and declared OS/CPU/libc fields. Non-exact dependency ranges remain unresolved rather than being guessed or resolved by running pnpm.

On 2026-10-24, the live npm [`vercel/latest` endpoint](https://registry.npmjs.org/vercel/latest) reported `65.2.0` with `engines.node >=20`; its [exact-version endpoint](https://registry.npmjs.org/vercel/65.2.0) matched the reviewed registry metadata. This is a dated observation, not a version pin or a change to `pnpm-allowed.json`.

## Native execution stays disabled

Vercel's [CLI documentation](https://vercel.com/docs/cli) says the standard CLI still requires Node and describes optional native binaries plus an explicit `vercel upgrade --enable-binary` opt-in. The plan records Linux x64/arm64 glibc and musl package metadata as unselected candidates; it does not determine which variant a host would use, install optional packages, or invoke native-mode activation. See the exact registry metadata for [Linux x64 glibc](https://registry.npmjs.org/@vercel%2Fvc-native-linux-x64/65.2.0), [Linux x64 musl](https://registry.npmjs.org/@vercel%2Fvc-native-linux-x64-musl/65.2.0), [Linux arm64 glibc](https://registry.npmjs.org/@vercel%2Fvc-native-linux-arm64/65.2.0), and [Linux arm64 musl](https://registry.npmjs.org/@vercel%2Fvc-native-linux-arm64-musl/65.2.0). The separate [experimental native-binary announcement](https://vercel.com/changelog/experimental-native-binaries-for-vercel-cli) is not an install route for this plan.

Registry requests are JSON metadata only: no npm tarball is downloaded, and an SRI string is not verification of package bytes. The package manager is not run, no lifecycle or build script executes, and no Vercel token/profile or account state is read or changed. Proposed isolated paths are only checked by the dry-plan validator; pnpm's effective global paths and runtime behavior are not probed. pnpm's [global package](https://pnpm.io/global-packages) and [configuration](https://pnpm.io/settings) documentation describe machine-level global/bin/config paths, but the plan does not activate them.

## Why the action remains blocked

The allowlist has no user/repository-selected Vercel version. npm registry metadata is not a pnpm lockfile: the complete transitive, peer, and optional dependency closure, range resolution, and version-scoped script/build policy remain incomplete. Package archive contents and implicit build behavior are unreviewed; the recorded SRI is metadata only. The Node/pnpm release metadata in the plan is not an installed or runtime-tested toolchain, and effective isolated destinations still need validation. Authentication and CLI profile/state setup are separate work and are not inferred.

Accordingly, the Vercel action remains `blocked` even when a metadata-only dry plan is produced. No install, activation, or operational-equivalence claim follows from this review.
