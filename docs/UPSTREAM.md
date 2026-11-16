# Upstream source record

U Unlocked reuses the Smash4PC source as a pinned Git submodule at `upstream/`.

| Field | Value |
| --- | --- |
| Repository | https://github.com/josiahg2502-glitch/Smash4PC |
| Pinned commit | `f145e7fc14d0be2caf712cc4080f9deb3e7ab6aa` |
| Upstream release | `v0.1.2` |
| Upstream license | MIT (retain all third-party licenses separately) |
| Local submodule path | `upstream/` |

## Update procedure

1. Review the upstream release notes and full commit range since the current pin.
2. Inspect changed source, dependencies, licenses, build scripts and user-data compatibility.
3. Test the upstream baseline build before changing the pin.
4. Update the submodule pointer in a focused PR.
5. Re-run the U Unlocked build, launcher, input, settings and mod regression checks.
6. Record the new commit and compatibility notes in this file.

Do not track generated code or binaries from a user's game dump. Do not commit changes made inside the submodule as though they were U Unlocked source. Keep project-owned changes in this repository or in a deliberate fork with its own provenance and licensing record.
