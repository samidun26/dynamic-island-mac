# QA results

| | |
|---|---|
| Date | 2026-10-01 16:40 UTC |
| macOS | 15.7.9 (24G830), arm64 |
| App | 4d95038 Security hardening: hardened runtime, clean helper environment, safer fallback |

| ID | Case | Result | Evidence |
|---|---|---|---|
| QA-01 | Build from source and install to /Applications (FR-S5) | ❌ fail | build.sh failed, see build.log |
