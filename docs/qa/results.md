# QA results

| | |
|---|---|
| Date | 2026-10-01 14:31 UTC |
| macOS | 15.7.9 (24G830), arm64 |
| App | 7ca9597 Hold brief 'nothing playing' gaps; QA: menu trace, controlled CPU probes |

| ID | Case | Result | Evidence |
|---|---|---|---|
| QA-01 | Build from source and install to /Applications (FR-S5) | ✅ pass | build.sh in 47 s, signature valid |
| QA-25 | Hidden from screen capture by default (FR-W8) | ✅ pass | timer running, island absent from capture ([shot](shots/qa25-hidden.png)) |
| QA-03 | Panel is top-centre, above the menu bar, fixed size (FR-W1, FR-W7) | ✅ pass | x=234 w=556 layer=27 (menu bar is 24) |
| QA-04 | Menu bar icon present (FR-S1) | ✅ pass | status item window found |
| QA-05 | Idle island is hidden on a display without a notch (FR-W5) | ✅ pass | state idle, nothing drawn over the menu bar ([shot](shots/qa05-idle.png)) |
| QA-06 | Idle CPU and memory (NFR-1, NFR-2) | ✅ pass | 0.6% CPU, 12M |
| QA-07 | Now Playing is detected from another app (FR-N1) | ✅ pass | "QA Track One" via adapter |
| QA-08 | New track peeks, then settles to compact (FR-A5) | ✅ pass | peek then compact ([shot](shots/qa08-peek.png)) |
| QA-09 | Compact wings: artwork + equaliser (FR-N3) | ✅ pass | 274 pt wide, expected 274 ([shot](shots/qa09-compact.png)) |
| QA-10 | Artwork arrives and is shown (FR-N6) | ✅ pass | artwork decoded |
| QA-11 | Resting the pointer opens it (FR-I1) | ✅ pass | expanded:nowPlaying 484x161; on screen 488 pt wide, bottom edge at 161 pt ([shot](shots/qa11-expanded.png)) |
| QA-12 | Expanded shows title and artist (FR-N4) | ✅ pass | AX texts: FakePlayer|QA Track One|The Testers|0:53|-2:40|0:54|-2:39| |
| QA-13 | Play/pause button controls the player (FR-N4) | ✅ pass | player received pause then play |
| QA-14 | Next button skips and the island follows (FR-N4) | ✅ pass | player skipped, island shows "QA Track Two" |
| QA-15 | Dragging the progress bar seeks (FR-N4) | ✅ pass | player seeked to 140 s of 187 (expected ≈140) |
| QA-16 | Moving away closes it (FR-I2) | ✅ pass | compact:nowPlaying 274x33 |
| QA-17 | Sweeping across the notch does not open it (FR-I1) | ✅ pass | 800 pt in 90 ms: stayed closed |
| QA-18 | Clicks beside the island pass through (FR-W2) | ✅ pass | click at (722, 120), inside the panel frame, reached the window below |
| QA-19 | Click pins it open; a click elsewhere closes it (FR-I4) | ✅ pass | pinned, stayed open after leaving, dismissed by outside click |
| QA-20 | Two-finger swipes on the island (FR-I5) | ✅ pass | vertical: 'SWIPE down' then 'SWIPE up' (state after: compact:nowPlaying); horizontal: 'SWIPE left' (state: expanded:home) |
| QA-21 | notchy://timer starts a timer in the wings, music as a glyph (FR-T1, FR-A3) | ✅ pass | compact:timer 356x33 secondaries=["nowPlaying"] pages=3; 356 pt ([shot](shots/qa21-timer.png)) |
| QA-22 | Timer ends: peek, then clears itself (FR-T3) | ✅ pass | done → peek → back to music ([shot](shots/qa22-done.png)) |
| QA-23 | Timer page: +1 min, pause, cancel (FR-T2) | ✅ pass | paused at 5:52 after +1 min, cancel removed the page ([shot](shots/qa23-timer-paused.png)) |
| QA-24 | Settings window opens; ⌘W closes it (FR-S2) | ❌ fail | window shown ([shot](shots/qa24-settings.png)) but ⌘W did not close it |
| QA-26 | Menu bar menu opens (FR-S1) | ✅ pass | menu shown ([shot](shots/qa26-menu.png)) |
| QA-27 | Now Playing stream restarts after a crash, without flicker (FR-N2) | ✅ pass | killed pid 2396, restarted as 4445; island stayed on the track |
| QA-28 | Quitting stops the Now Playing helper (NFR-4) | ✅ pass | no adapter process left |
| QA-29 | "Never" on displays without a notch hides the island (FR-W5) | ✅ pass | no panel window on screen |
| QA-02 | Downloaded build: blocked while quarantined, opens after the guide's xattr step | ✅ pass | blocked as downloaded ([shot](shots/qa02-gatekeeper.png)); after xattr -dr it opens |

**28 passed, 1 failed, 0 skipped.**

CPU (average of 3 × 2 s samples): idle 0.6% · compact with music and equaliser ?% · expanded Now Playing ?%.

Input synthesis: yes. Accessibility for the driver: yes. Screen: 1024 pt wide, menu bar 25 pt, no notch.
