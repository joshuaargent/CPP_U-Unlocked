# Third-party notices

U Unlocked includes and builds on third-party software. The licence text distributed with each component is authoritative. Do not remove copyright notices, licence files, or attribution required by the applicable licence.

## Native runtime and recompilation components

The MIT licence notice for the incorporated native runtime and recompilation source is retained at [LICENSES/RECOMPILATION-MIT-LICENSE.txt](../LICENSES/RECOMPILATION-MIT-LICENSE.txt).

## Nintendo Network client components

The client implementation under `engine/third_party/cemu_nex/` is distributed under Mozilla Public License 2.0. Its complete licence is retained at `engine/third_party/cemu_nex/LICENSE.txt`. Changes to files covered by that licence must comply with its file-level source-distribution requirements.

## XML parsing

The controller-profile importer uses TinyXML-2, distributed under its zlib-style licence. The vendored source is under `engine/third_party/tinyxml2/`; its full notice is retained in `engine/third_party/tinyxml2/LICENSE.txt`. The imported version is pinned to commit `8224e427b655b83dae5e2298f1e6919523a78737`.

## Other dependencies

Build-time dependencies are declared in `engine/dependencies.lock.json` and acquired by the dependency build scripts. Their respective licence notices must be retained in the dependency/build output and must be reviewed whenever dependency versions change.

## Game data

No Nintendo game data, console keys, user saves, proprietary game assets, or generated game code may be committed or included in a public release.
