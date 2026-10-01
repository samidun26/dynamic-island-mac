# Vendored: mediaremote-adapter

- Upstream: https://github.com/ungive/mediaremote-adapter
- Commit: 29718252613a5b0e210bdc64de0bd944ab379706 (2026-09-30)
- License: BSD 3-Clause (see `LICENSE` in this folder). Copyright (c) 2025 Jonas van den Berg and contributors.

Changes from upstream:
- Removed `src/test` (the optional `MediaRemoteAdapterTestClient`) and its CMake target; Notchy does not run the `test` command.
- Removed editor/CI config files and helper scripts.

`build.sh` compiles `src/**/*.m` with clang directly into `MediaRemoteAdapter.framework` (no CMake needed) and copies `bin/mediaremote-adapter.pl` into the app's Resources.
