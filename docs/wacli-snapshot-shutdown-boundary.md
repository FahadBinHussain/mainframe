# Shutdown alone cannot certify a WACLI snapshot

**Capture remains disabled. Usable Linux restoration is still not implemented.** On the audited WACLI and whatsmeow versions, stopping the delegate listener and closing the client/databases does not establish a lossless application boundary. New synthetic tests reproduce rejected accepted work, an unfinished cross-store continuation, and an independent offline media writer. This change adds diagnostics and documentation only; it does not enable capture, change dependencies or alter runtime shutdown.

The source versions remain WACLI [`5578d1b6892f50a8f2329b11a6b6e27a1a81f88b`](https://github.com/openclaw/wacli/tree/5578d1b6892f50a8f2329b11a6b6e27a1a81f88b) and whatsmeow `v0.0.0-20261017175727-b2b1e71d45e2`. Earlier [producer lifecycle evidence](wacli-snapshot-producer-lifecycle.md) and [delegate counterexamples](wacli-snapshot-writer-boundary.md) still apply.

## Closing SQLite can hide unfinished work

The [shutdown diagnostic patch](../patches/wacli/0004-synthetic-shutdown-boundary-probes.patch) drives the pinned SDK's real detached key-share worker through WACLI's real key guard. It pauses a synthetic session-store adapter before or after a generic SQLite effect. It then runs actual wrapper/container close and closes a disposable WACLI app database in the same relative order as `App.Close`, before releasing the worker.

Both cases leave SQLite files that pass `PRAGMA integrity_check`, but neither completes the accepted logical operation:

- **Paused before the session effect:** wrapper close returns and closes the SQL handle. After release, the accepted worker's SQL effect fails with `database is closed`; no effect is committed and the app recovery marker remains.
- **Paused after the session effect:** that generic session-domain effect is committed before close. The accepted worker then returns through the real guard, whose app-metadata continuation fails against the closed app database. The committed first effect remains, as does the uncleared app recovery marker.

These are controlled interleavings, not probabilistic sleeps. They extend the previous in-memory counterexample with real SQLite effects and close errors. They **do not** use a real WhatsApp session schema, store actual key material, open a socket, run a full `App.Close` integration, or reproduce a particular real-account failure. Already-synced fake app-state versions prevent network fetches. Passing tests demonstrate an unresolved drain contract, not successful capture.

The relevant ordering is visible in [`App.Close`](https://github.com/openclaw/wacli/blob/5578d1b6892f50a8f2329b11a6b6e27a1a81f88b/internal/app/app.go#L222-L253), [wrapper close](https://github.com/openclaw/wacli/blob/5578d1b6892f50a8f2329b11a6b6e27a1a81f88b/internal/wa/client.go#L64-L75) and [the key guard's two persistence calls](https://github.com/openclaw/wacli/blob/5578d1b6892f50a8f2329b11a6b6e27a1a81f88b/internal/wa/app_state_keys.go#L40-L69). Ignored close errors are an additional reason these void-returning close APIs cannot serve as a successful capture receipt. Waiting for SQL calls alone also misses a producer paused outside SQL between the two calls.

## The store lock does not fence approved media roots

The second diagnostic creates synthetic WACLI message/media metadata and verified cache bytes, closes its setup database, and holds the real store `LOCK`. In a separate helper process it runs the real CLI's offline `--read-only media download --output` path. A new file is published outside the store, from cache, while the lock is held. A competing lock acquisition fails both before and after the CLI runs; merely checking that a `LOCK` file exists would not prove this.

This is a supported cache-output path, not an authentication attempt or a claim that read-only mode forbids all filesystem output. It proves a snapshot holder cannot infer “no media writers” from this store lock, even after the daemon and its setup database are closed. Giving the output directory an approval label would not change its lock behavior. No unrelated program, hardlink or symlink race is needed for the counterexample.

See [read-only explicit output](https://github.com/openclaw/wacli/blob/5578d1b6892f50a8f2329b11a6b6e27a1a81f88b/cmd/wacli/media_download.go#L37-L79) and [media publication](https://github.com/openclaw/wacli/blob/5578d1b6892f50a8f2329b11a6b6e27a1a81f88b/internal/wa/media.go#L63-L137). Deletion/purge and output from other stores sharing an external root also need an ownership contract; these additional cases are source-audit requirements, not claims exercised by the new fixture.

## What a complete implementation must own

A shutdown-based implementation is possible in principle, but **not as a wrapper around the pinned close APIs and existing shared media roots**. It needs all of the following together:

1. **One admission owner.** Atomically reject new CLI/delegate/root operations and lazy session opens before waiting. Track every accepted handler, reader, callback, delayed task and reconnect/pairing producer. A delegate WaitGroup fixes only one family.
2. **A dependency-supported causal drain.** Keep stores open until all accepted producers and their descendants reach a defined completed application frontier. Descendants of accepted work need scoped admission; blanket rejection after the first persistence call splits the operation. Registration must prevent an untracked child or timer appearing after a zero-worker observation. The dependency's detached `WithoutCancel` workers and node children currently have no exhaustive join API. Implementing this requires a reviewed maintained dependency change, not a SQL-only gate or blind replacement of selected `go` statements.
3. **An enforceable media ownership boundary.** All participating WACLI processes must fence create, replace, rename, delete and database path publication, including read-only explicit outputs. Approved roots need a defined policy for other processes, shared-store roots, aliases, writable open handles and path replacement. An advisory root lock cannot exclude nonparticipants; chmod or a read-only bind view does not revoke existing descriptors or freeze the underlying source. Unsupported roots must block, not silently lose their references or bytes.
4. **A held capture state.** After a successful drain, retain exclusive ownership without lazy reopen while enumerating current paths/aliases and approved output-root membership, capturing both databases and verified media, then validating the result. Preserve remote-only and missing/invalid-local distinctions and relocation information. Release only after successful validation or cleanup. A timeout, canceled accepted operation, failed persistence, close error or ambiguous ownership must abort without publishing.

There is no such exhaustive dependency lifecycle or root-ownership contract in the audited version. A stop acknowledgment, empty queue, successful database close, exited process, filesystem snapshot or stable hashes cannot substitute for these requirements. Process exit removes that process's future writes, but neither proves its accepted work completed nor excludes another offline output writer.

## Safety and test limits

The diagnostics use only disposable synthetic SQL, fake store endpoints, fake metadata and synthetic media bytes. No real account, database, credentials, chats or personal media is accessed. Mainframe never applies or executes these patches automatically. The existing producer `create` and Mainframe capture paths remain fail-closed before source I/O, with no shutdown/force/receipt override.

**Windows was not run.** The user's offline Windows machine was not accessed. Linux tests, race detection and any standard Windows cross-compilation are not Windows-origin validation. Even after a future capture boundary is implemented, version/schema acceptance, account/config mapping, media relocation, non-overwriting activation, message/search/media checks and linked-device usability validation remain necessary. Byte preservation cannot guarantee credentials remain accepted by the server.
