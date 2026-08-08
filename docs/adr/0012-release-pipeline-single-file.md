# Release pipeline: tag-frozen workflow with dispatch escape hatch, single-file Setup.bat installer

`release.yml` triggers on `push: tags: v*` and on `workflow_dispatch` with a required `tag` input, because GitHub Actions freezes a tag-triggered run to the workflow file's content as of the tagged commit — dispatch lets a pipeline bug be fixed and re-run against an existing tag without deleting it. The distributed artifact is a polyglot `StreamConfigProfiles-Setup.bat`: `manager.ps1` with the engine and template inlined, wrapped in a batch header whose embedded snippet extracts the verbatim `.ps1` payload and runs it with `-File`, never `iex`.

## Consequences

- A parse-check alone can't verify the polyglot build: a build whose marker slots were never filled parses cleanly but fails only on the end user's machine. `make-dist.ps1` self-tests by re-implementing the extraction and asserting a byte-identical round-trip, in CI on every PR, not just at tag time.
- `RELEASE_TAG` is passed through the environment rather than interpolated into a `run:` block, since `${{ }}` substitutes textually and ref names/dispatch inputs can contain shell metacharacters.
