# QA results

| | |
|---|---|
| Date | 2026-10-01 17:34 UTC |
| macOS | 15.7.9 (24G830), arm64 |
| App | faa1ee1 Menu bar fit: keep the last menus while an app activates; never query Notchy itself |

| ID | Case | Result | Evidence |
|---|---|---|---|
| QA-01 | Build from source and install to /Applications (FR-S5) | ✅ pass | build.sh in 40 s, signature valid |
| QA-25 | Hidden from screen capture by default (FR-W8) | ✅ pass | timer running, island absent from capture ([shot](shots/qa25-hidden.png)) |
| QA-03 | Panel is top-centre, above the menu bar, fixed size (FR-W1, FR-W7) | ✅ pass | x=234 w=556 layer=27 (menu bar is 24) |
| QA-04 | Menu bar icon present (FR-S1) | ✅ pass | status item window found |
| QA-05 | Idle island is hidden on a display without a notch (FR-W5) | ✅ pass | state idle, nothing drawn over the menu bar ([shot](shots/qa05-idle.png)) |
| QA-06 | Idle CPU and memory (NFR-1, NFR-2) | ✅ pass | 0.0% CPU, 12M |
| QA-07 | Now Playing is detected from another app (FR-N1) | ✅ pass | "QA Track One" via adapter |
| QA-08 | New track peeks, then settles to compact (FR-A5) | ✅ pass | peek then compact ([shot](shots/qa08-peek.png)) |
| QA-09 | Compact wings: artwork + equaliser (FR-N3) | ✅ pass | 254 pt wide as drawn (fit=right:0/70) ([shot](shots/qa09-compact.png)) |
| QA-10 | Artwork arrives and is shown (FR-N6) | ✅ pass | artwork decoded |
| QA-11 | Resting the pointer opens it (FR-I1) | ✅ pass | expanded:nowPlaying 484x161; on screen 488 pt wide, bottom edge at 161 pt ([shot](shots/qa11-expanded.png)) |
| QA-12 | Expanded shows title and artist (FR-N4) | ✅ pass | AX texts: FakePlayer|QA Track One|The Testers|0:53|-2:40| |
| QA-13 | Play/pause button controls the player (FR-N4) | ✅ pass | player received pause then play |
| QA-14 | Next button skips and the island follows (FR-N4) | ✅ pass | player skipped, island shows "QA Track Two" |
| QA-15 | Dragging the progress bar seeks (FR-N4) | ✅ pass | player seeked to 140 s of 187 (expected ≈140) |
| QA-16 | Moving away closes it (FR-I2) | ✅ pass | compact:nowPlaying 254x33 |
| QA-17 | Sweeping across the notch does not open it (FR-I1) | ✅ pass | 800 pt in 90 ms: stayed closed |
| QA-18 | Clicks beside the island pass through (FR-W2) | ✅ pass | click at (722, 120), inside the panel frame, reached the window below |
| QA-19 | Click pins it open; a click elsewhere closes it (FR-I4) | ✅ pass | pinned, stayed open after leaving, dismissed by outside click |
| QA-20 | Two-finger swipes on the island (FR-I5) | ✅ pass | vertical: 'SWIPE down' then 'SWIPE up' (state after: compact:nowPlaying); horizontal: 'SWIPE left' (state: expanded:home) |
| QA-21 | notchy://timer starts a timer in the wings, music as a glyph (FR-T1, FR-A3) | ✅ pass | compact:timer 305x33 secondaries=["nowPlaying"] pages=3 fit=right:0/121 x=420; 305 pt ([shot](shots/qa21-timer.png)) |
| QA-22 | Timer ends: peek, then clears itself (FR-T3) | ✅ pass | done → peek → back to music ([shot](shots/qa22-done.png)) |
| QA-23 | Timer page: +1 min, pause, cancel (FR-T2) | ✅ pass | paused at 5:53 after +1 min, cancel removed the page ([shot](shots/qa23-timer-paused.png)) |
| QA-26 | Menu bar menu opens (FR-S1) | ✅ pass | menu window on screen, (front: Finder; MOUSEDOWN own window NSStatusBarWindow active=false ) ([shot](shots/qa26-menu-other-app.png)) |
| QA-24 | Settings window opens; ⌘W closes it (FR-S2) | ❌ fail | window shown, focused=true ([shot](shots/qa24-settings.png)), but ⌘W did not close it |
| QA-32 | Menu bar menu still opens after Settings was used (FR-S1) | ✅ pass | menu window on screen ([shot](shots/qa32-menu-after-settings.png)) |
| QA-27 | Now Playing stream restarts after a crash, without flicker (FR-N2) | ✅ pass | killed pid 2165, restarted as 4833; island stayed on the track |
| QA-30 | Pausing in the player: wings collapse after the grace period (FR-N3) | ✅ pass | collapsed 2.7 s after the pause (grace 2.5 s) |
| QA-31 | CPU with music paused and the island idle (NFR-1) | ✅ pass | 0.0% (music playing in the wings: 2.4% and 1.9%) |
| QA-35 | Compact island keeps clear of menus and menu bar icons (FR-W9) | ✅ pass | island 420–674 pt, app menus end at 397, first icon at 745, fit=right:0/70; Notchy measured left=23 right=141 ([shot](shots/qa35-clear.png)) |
| QA-36 | A crowded menu bar moves or folds the island instead of being covered (FR-W9) | ❌ fail | no re-fit after a 129 pt icon appeared; compact:nowPlaying 254x33; CROWD added width=129;CROWD placed x=600 w=145 visible=true; icons: FakePlayer 600 145,Notchy 745 38,Control_Center 783 33,Spotlight 816 31,Control_Center 847 34,Control_Center 881 143, ([shot](shots/qa36-crowded.png)) |
| QA-28 | Quitting stops the Now Playing helper (NFR-4) | ✅ pass | no adapter process left |
| QA-29 | "Never" on displays without a notch hides the island (FR-W5) | ✅ pass | no panel window on screen |
| QA-33 | Libraries injected at launch are refused (NFR-10) | ✅ pass | DYLD_INSERT_LIBRARIES ran in a plain program, not in Notchy (flags=0x10002(adhoc,runtime), __RESTRICT segment) |
| QA-34 | The Now Playing helper ignores Perl injection variables (NFR-10) | ✅ pass | PERL5OPT/PERL5LIB ran code in plain perl, not in the helper; Now Playing still works |
| QA-02 | Downloaded build: blocked while quarantined, opens after the guide's xattr step | ✅ pass | blocked as downloaded ([shot](shots/qa02-gatekeeper.png)); after xattr -dr it opens |

**34 passed, 2 failed, 0 skipped.**

CPU of Notchy (average of three 2 s samples, on a CI virtual machine; expect less on real hardware): idle 0.0% · music playing in the compact wings 2.4 / 1.9% · expanded Now Playing 2.3% · music paused, island idle 0.0%.

Input synthesis: yes. Accessibility for the driver: yes. Screen: 1024 pt wide, menu bar 25 pt, notch: none.
