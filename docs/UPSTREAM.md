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


## Project-owned build overlay

The U Unlocked build wrapper mirrors the pinned submodule into the ignored `upstream-build/` directory before applying project-owned changes. The overlay is applied by `tools/windows/apply-u-unlocked-branding.ps1`; the original submodule remains clean.

Every replacement checks its expected occurrence count. If the pinned source changes and a patch no longer matches, the build stops instead of silently applying a partial rebrand. The overlay changes executable/window identity, launcher title, runtime dialogs, the HTTP user agent, the launcher background fallback, resource icon and upstream build-script output names. It also prevents the upstream game's launcher logo/background from being copied into the U Unlocked output.

The original upstream source is not modified or rewritten in Git. The icon is generated locally into the isolated build copy by `tools/windows/new-u-unlocked-icon.ps1`.
