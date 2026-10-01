# QA results

| | |
|---|---|
| Date | 2026-10-01 14:13 UTC |
| macOS | 15.7.9 (24G830), arm64 |
| App | dc58985 QA: never block on the Gatekeeper dialog; time-limit UI-bound steps |

| ID | Case | Result | Evidence |
|---|---|---|---|
| QA-01 | Build from source and install to /Applications (FR-S5) | ✅ pass | build.sh in 37 s, signature valid |
| QA-02 | Downloaded build is blocked until un-quarantined (user guide §1) | ❌ fail | still not running after xattr -dr |
| QA-25 | Hidden from screen capture by default (FR-W8) | ✅ pass | timer running, island absent from capture ([shot](shots/qa25-hidden.png)) |
| QA-03 | Panel is top-centre, above the menu bar, fixed size (FR-W1, FR-W7) | ✅ pass | x=234 w=556 layer=27 (menu bar is 24) |
| QA-04 | Menu bar icon present (FR-S1) | ✅ pass | status item window found |
| QA-05 | Idle island is hidden on a display without a notch (FR-W5) | ❌ fail | state compact:timer 312x33, dark run 10 pt |
| QA-06 | Idle CPU and memory (NFR-1, NFR-2) | ✅ pass | 0.0% CPU, 12M |
| QA-07 | Now Playing is detected from another app (FR-N1) | ✅ pass | "QA Track One" via adapter |
| QA-08 | New track peeks, then settles to compact (FR-A5) | ✅ pass | peek then compact ([shot](shots/qa08-peek.png)) |
| QA-09 | Compact wings: artwork + equaliser (FR-N3) | ❌ fail | state compact:nowPlaying 274x33, 214 pt wide, expected 274 |
| QA-10 | Artwork arrives and is shown (FR-N6) | ✅ pass | artwork decoded |
| QA-11 | Resting the pointer opens it (FR-I1) | ✅ pass | expanded:nowPlaying 484x161; island box 0 0 1024 161 ([shot](shots/qa11-expanded.png)) |
| QA-12 | Expanded shows title and artist (FR-N4) | ❌ fail | AX texts:  |
| QA-13 | Play/pause button controls the player (FR-N4) | ❌ fail | no Pause button in the accessibility tree |
| QA-14 | Next button skips and the island follows (FR-N4) | ❌ fail | no next command |
| QA-15 | Dragging the progress bar seeks (FR-N4) | ❌ fail | no progress bar in the accessibility tree |
| QA-16 | Moving away closes it (FR-I2) | ✅ pass | compact:nowPlaying 274x33 |
| QA-17 | Sweeping across the notch does not open it (FR-I1) | ✅ pass | 800 pt in 90 ms: stayed closed |
| QA-18 | Clicks beside the island pass through (FR-W2) | ✅ pass | click at (722, 120), inside the panel frame, reached the window below |
| QA-19 | Click pins it open; a click elsewhere closes it (FR-I4) | ❌ fail | pinned=no, after leaving=compact:nowPlaying |
| QA-20 | Two-finger swipes on the island (FR-I5) | ❌ fail | got '' / 'SWIPE up' / 'SWIPE left' |
| QA-21 | notchy://timer starts a timer in the wings, music as a glyph (FR-T1, FR-A3) | ✅ pass | compact:timer 356x33 secondaries=["nowPlaying"] pages=3; 269 pt ([shot](shots/qa21-timer.png)) |
| QA-22 | Timer ends: peek, then clears itself (FR-T3) | ✅ pass | done → peek → back to music ([shot](shots/qa22-done.png)) |
| QA-23 | Timer page: +1 min, pause, cancel (FR-T2) | ❌ fail | no +1 min no pause no cancel paused=0 time=? state expanded:timer 484x161 |
| QA-24 | Settings window opens (FR-S2) | ✅ pass | window "Notchy Settings" ([shot](shots/qa24-settings.png)) |
| QA-26 | Menu bar menu opens (FR-S1) | ✅ pass | menu shown ([shot](shots/qa26-menu.png)) |
| QA-27 | Now Playing stream restarts after a crash (FR-N2) | ✅ pass | killed pid 2059, restarted as 4010 |
| QA-28 | Quitting stops the Now Playing helper (NFR-4) | ✅ pass | no adapter process left |
| QA-29 | "Never" on displays without a notch hides the island (FR-W5) | ✅ pass | no panel window on screen |

**19 passed, 10 failed, 0 skipped.** CPU while music plays and the equaliser animates: 0.4%.

Input synthesis: yes. Accessibility for the driver: yes. Screen: 1024 pt wide, menu bar 25 pt, no notch.
