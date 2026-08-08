# Release pipeline: tag-frozen workflow with dispatch escape hatch, single-file Setup.bat installer

`release.yml` triggers on `push: tags: v*` and on `workflow_dispatch` with a required `tag` input, because GitHub Actions freezes a tag-push-triggered run to the workflow file's content as it existed at the tagged commit — the dispatch path lets a pipeline bug fix be re-run against a tag that already exists without deleting/recreating it.

## Workflow hardening

- `RELEASE_TAG` is resolved from the dispatch input or `ref_name` and passed through the environment rather than interpolated into a `run:` block, since `${{ }}` substitutes textually before the shell sees it and both ref names and dispatch inputs permit shell metacharacters.
- Actions are pinned to commit SHAs for a different reason: a compromised or retagged upstream action would otherwise execute unreviewed in every job that follows.
- Release publish checks `gh release view` first and upserts with `--clobber` rather than create-only, since the common case is a maintainer publishing release notes (and thus creating the tag) from the GitHub UI before the tag-push run ever fires.
- `attest-build-provenance` is gated on `! github.event.repository.private`, since it errors outright on private user-owned repos and would otherwise skip the asset-upload step entirely.
- `SHA256SUMS.txt` is included as an attestation subject alongside the binaries it hashes, so a tampered checksums file can't vouch for a tampered download.

## The single-file installer

The distributed artifact is built by `build/make-dist.ps1`: it inlines `sync-configs.ps1` and `paths.example.txt` into `manager.ps1`'s payload markers to produce `dist/manager.ps1`, then wraps that byte-for-byte into a polyglot `StreamConfigProfiles-Setup.bat` (ASCII batch header ending in an unconditional `exit /b` before a unique marker line, followed by the verbatim payload) whose embedded extraction snippet byte-scans for the marker, writes everything after it to a `%TEMP%` file, and runs it with `-File` — never `iex`.

## Consequences

A parse-check alone can't verify the polyglot build: a build whose marker slots were never actually filled parses cleanly but throws "embedded payload is empty" only on the end user's machine. `make-dist.ps1` self-tests by independently re-implementing the extraction and asserting a byte-identical round trip, refusing to produce an artifact otherwise — the same assertion runs in `ci.yml`'s `build-dist` job on every PR, not just at tag time.
