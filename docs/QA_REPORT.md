# QA report

End-to-end QA of Notchy, installed from this repository the way the [user guide](USER_GUIDE.md) describes and then used on a real macOS session: a script moves the pointer, clicks, scrolls and swipes like a person would, plays music from a test app, and checks what happens on screen, in the accessibility tree, and in the music app.

- **Latest run:** [docs/qa/results.md](qa/results.md), with [screenshots](qa/shots/), Notchy's [test trace](qa/notchy-trace.log) and the [test player's log](qa/fakeplayer.log).
- **Result:** **36 of 36 cases pass** (macOS 15.7.9, commit `e1a7173`). Nine bugs and security issues were found along the way and fixed; each fix was re-tested by the next run.
- **Re-run it:** see [How to run it](#how-to-run-it). It runs on every push to a working branch, and on demand from the Actions tab.

## Environment

| | |
|---|---|
| Machine | GitHub Actions `macos-15` runner: a virtual Mac, Apple silicon (arm64), macOS 15.7.9 |
| Toolchain | Xcode 26.3, Swift 6 language mode |
| Display | 1024 × 768 pt, **no notch**, menu bar 25 pt. Notchy's synthetic notch is used ("show only when active", the default) |
| Audio | No audio device output to listen to; the test player still plays a near-silent tone so macOS treats it as playing |
| Permissions | Accessibility and input synthesis granted to the test driver; Notchy itself has no extra permissions (calendar, Accessibility for media keys and brightness stay off) |

## What was tested and how

| Step | How |
|---|---|
| Install | `git clone`, then `./build.sh` and copying `build/Notchy.app` to `/Applications`, exactly as the user guide says; the signature is verified |
| Downloaded build | The built app is zipped and given the quarantine flag a browser download gets. Opening it must be blocked by Gatekeeper; after the user guide's `xattr -dr com.apple.quarantine` step it must open |
| Music | `QA/FakePlayer` publishes three tracks with artwork to macOS Now Playing (the same system path Music, Spotify and browsers use) and logs every remote command it receives: play, pause, next, previous, seek |
| Input | `QA/Driver` posts real HID-level mouse moves, clicks, drags, key presses and two-finger trackpad scrolls (with gesture phases), so Notchy receives them exactly as from a person |
| Checks | Notchy's test trace (`NOTCHY_QA_LOG=1`: state changes with sizes, hover, clicks, swipes, Now Playing), the window list (position, size, layer), the accessibility tree (labels, values, button presses), screenshots measured pixel by pixel, the player's log, `top` for CPU and memory |

The trace is off unless the environment variable is set, and has no effect on behaviour.

## Results

Grouped by area. Every case's evidence (numbers, screenshots, trace excerpts) is in [results.md](qa/results.md).

| Area | Cases | What was checked |
|---|---|---|
| Install | QA-01, QA-02 | Builds from a clean clone and installs with a valid signature. A downloaded (quarantined) copy is blocked by Gatekeeper, and opens after the user guide's `xattr` step |
| Window | QA-03, QA-04, QA-05, QA-29 | One panel, top-centre, above the menu bar (layer 27 vs the menu bar's 24), fixed size; menu bar icon present; nothing drawn while idle on a display without a notch; "Never" mode hides it |
| Menu bar clearance | QA-35, QA-36 | With Finder's menus ending 23 pt before the notch, the compact island moves to the right of the notch and covers neither menus nor icons (checked against Finder's real menu frames and every menu bar icon). A wide icon added right next to the notch makes it get out of the way within seconds, and it comes back when the icon goes |
| Privacy | QA-25 | Hidden from screen capture by default, even with a timer running |
| Now Playing | QA-07, QA-08, QA-09, QA-10, QA-27, QA-30 | Another app's track is detected through the system Now Playing, peeks, settles into the compact wings at the expected width, shows its artwork; the helper restarts after being killed without the island flickering; pausing collapses the wings after the 2.5 s grace period |
| Hover and gestures | QA-11, QA-16, QA-17, QA-18, QA-19, QA-20 | Resting on the notch opens it (484 × 161 pt, checked in pixels); leaving closes it; an 800 pt sweep in 90 ms does not; clicks beside the island reach the window below; click pins, click elsewhere dismisses; two-finger swipes open, close and change page |
| Controls | QA-12, QA-13, QA-14, QA-15 | Title and artist readable by VoiceOver; play/pause, next and dragging the progress bar reach the player (seek landed at 140 s of 187, as aimed) |
| Timer | QA-21, QA-22, QA-23 | `notchy://timer` starts it in the wings with the music as a glyph; finishing peeks then clears; +1 min, pause and cancel work |
| Settings and menu | QA-24, QA-26, QA-32 | Settings opens focused and ⌘W closes it; the menu bar menu opens, and still opens after Settings was used |
| Shutdown | QA-28 | Quitting stops the Now Playing helper |
| Updates | QA-37, QA-38, QA-39 | A copy that thinks it is 1.0.0 is offered 9.9.9 by a local stand-in for GitHub's release API: it downloads, verifies, swaps itself in place and relaunches as 9.9.9. A download that doesn't match its checksum is refused, and so is an update signed by a different identity (with two throwaway signing identities in a temporary keychain), while the same identity installs. The installed copy is untouched whenever an update is refused. The main QA copy also asks the real GitHub API and correctly finds no release yet |
| Security | QA-33, QA-34 | Code injection through the launch environment is refused, both into Notchy and into its helper; see the [security review](SECURITY_REVIEW.md) |
| Performance | QA-06, QA-31 | CPU and memory, below |

### Performance (CI virtual machine, range over the last runs; expect lower on real hardware)

| Situation | Notchy CPU | Target |
|---|---|---|
| Idle, nothing playing, all services on | 0.0–0.2% | 0% (NFR-1) |
| Music playing, compact wings with the equaliser | 2.2–2.7% | low; the equaliser is the only continuous animation |
| Expanded Now Playing (progress bar and equaliser) | 2.9–3.5% | only while open |
| Music paused, wings collapsed | 0.0% | 0% (NFR-1) |
| Memory | 12 MB | small and stable (NFR-2) |
| Build from a clean clone | 27–58 s | |

## Bugs found and fixed

Each of these was found by the QA run, fixed, and re-tested by the next run.

| # | Found by | Problem | Fix |
|---|---|---|---|
| 1 | QA-19 | Clicking the island to pin it usually did nothing: the pointer arrives before the click, so hover had already opened the island, the click was ignored, and the island closed again when the pointer left. | A click on the notch band of an open island pins it. Clicks on the controls below it (play, next, scrubber) still leave a hover-opened island hover-managed, so using a control doesn't pin it by accident. |
| 2 | QA-24 | ⌘W, ⌘Q and ⌘M did nothing in the Settings window: a menu bar app has no main menu, so the shortcuts had nowhere to go. | A hidden standard main menu (Settings, Hide, Quit, Edit, Window) provides the shortcuts; copy and paste work in the text fields too. |
| 3 | QA-24 | The Settings window sometimes opened behind the frontmost app, unfocused (macOS 14+ cooperative activation lets the active app refuse). | If Notchy isn't active shortly after the window is shown, it asks again to be activated, and the trace records whether the window has focus. Verified focused on every run since. |
| 4 | QA-27 | When the Now Playing helper restarted after a crash, its first message was "nothing playing": the island flashed to idle and then peeked the same track again. | A "nothing playing" message is held for 1.5 s; if the track comes back within that time nothing changes on screen. This also smooths players that blank for an instant between tracks. |
| 5 | QA-12/15 (VoiceOver) | The progress bar and volume slider were invisible to VoiceOver and couldn't be adjusted with assistive technologies. | Both are labelled, adjustable accessibility elements ("Playback position", "Volume") with their value read out; the icon buttons have labels ("Pause", "Next track", "Cancel timer" and so on). |
| 6 | QA-31 (CPU) | The equaliser was four separately animated views refreshing at 30 fps. | One Canvas drawn at 20 fps, paused when the music pauses. |
| 7 | QA-26 (test) | The menu bar menu check passed and failed inconsistently. Two causes, both in the test: the menu's "will open" callback also fires when an accessibility client reads the menu, so it isn't proof the menu appeared; and on the CI machine only the first synthetic click on a menu bar item in a session opens its menu, for any Notchy process, even a fresh one that was never active. | The check looks for the menu's own window on screen. QA-26 uses the first click; QA-32 re-opens the menu through Accessibility after Settings was used. An experiment ruled out the app's hidden main menu and its activation as causes. |
| 8 | Security review | Two ways another program could borrow Notchy's permissions, and three smaller issues. | Fixed; see the [security review](SECURITY_REVIEW.md). QA-33 and QA-34 test the two injection attacks on every run. |
| 9 | Your screenshot; QA-35, QA-36 | The compact wings had a fixed width and covered whatever was next to the notch: the end of the app's menus (Help) and menu bar icons (Wi‑Fi), which then couldn't be seen or clicked. | Notchy measures the free menu bar each side of the notch (icons from the window list; menus through Accessibility when allowed) and fits the activity into it: both wings, everything on the free side, or a thin progress line under the notch. While building it, QA also caught a 0.3 s widen while an app was still activating, slow menu reads holding up the icon check, and icons under a fake notch on displays without one; all fixed. |

The QA harness itself needed several rounds (time limits around anything that can wait on a system dialog, hit-testing the accessibility tree because an overlay panel's windows can't be enumerated, measuring widths along the island's top edge so content doesn't interfere). Those changes are in `QA/` only.

## Not covered by this run

The runner is a virtual Mac without a notch, speakers, a trackpad or a person, so these need someone on real hardware. Each is something automated testing here can't show, not a known problem.

### Manual checklist (MacBook with a notch)

Install as in the [user guide](USER_GUIDE.md), then:

- [ ] **Alignment.** Idle with nothing playing, nothing shows around the notch: no black edge or gap at any of the notch's sides, in light and dark menu bars. (14" and 16" MacBook Pro, MacBook Air.)
- [ ] **Feel.** Resting on the notch opens it quickly; moving across the notch to reach a menu never opens it; opening and closing look smooth (no hitch, no flash of content outside the shape). Try changing direction halfway through an animation.
- [ ] **Haptics.** A light tap on the trackpad when the island opens (Settings → Motion); none when it's turned off.
- [ ] **Real players.** Music, Spotify, Safari (YouTube), Chrome, Firefox, VLC, Podcasts: title, artist, artwork, play/pause, next and previous, scrubbing. Also quitting the player while it plays.
- [ ] **Calendar.** Turn on Calendar in Settings → Activities, allow access when asked, and check the next event on the Home page; for a meeting with a Zoom/Meet/Teams link, the **Join** button opens it, and the island peeks before it starts.
- [ ] **Volume keys.** Turn on "Replace the volume HUD", grant Accessibility when asked: the volume keys show the level in the island and the system HUD doesn't appear; mute works. With Accessibility denied, macOS shows its own HUD and nothing breaks.
- [ ] **Brightness keys** (experimental switch): the level shows in the island; with it off, macOS handles the keys.
- [ ] **Battery.** Plug in and unplug: the charging banner appears briefly; below 20% the low battery banner appears once.
- [ ] **Displays.** Connect and disconnect an external display, change resolution, close the lid with an external display: the island stays on the chosen display and re-aligns.
- [ ] **Spaces and full screen.** Switch Spaces and use a full-screen app: the island stays above it and keeps working.
- [ ] **Screen sharing.** Share the screen in Zoom, Meet or QuickTime: the island is not in the shared image (Settings → General, on by default). Some capture tools ignore this; note which.
- [ ] **Launch at login.** Turn it on, log out and in: Notchy starts. Turn it off: it doesn't.
- [ ] **Reduce Motion** (System Settings → Accessibility → Display): opening and closing become short crossfades.
- [ ] **VoiceOver.** The expanded island's buttons and sliders are read with their names and values, and the sliders can be adjusted.
- [ ] **Menu bar icon.** Click it several times, including after opening and closing Settings: the menu opens every time. (CI can only check this once per session with a real click; see bug 7.)

## How it was installed, used and tested

1. The `qa` workflow ([.github/workflows/qa.yml](../.github/workflows/qa.yml)) starts a macOS 15 runner and clones this repository, as in the user guide.
2. [`QA/run-qa.sh`](../QA/run-qa.sh) builds the test driver and the test player, builds Notchy with `./build.sh`, installs it to `/Applications` and runs the cases above.
3. The report, screenshots and logs are committed to [`docs/qa/`](qa/) on the branch that was tested.

## How to run it

**On GitHub:** Actions → **qa** → Run workflow. Choose a branch, tag or commit in "Version of Notchy to install and test", and tick "Commit the report" to publish the results to `docs/qa/`. The full output is also attached to the run as the `qa-results` artifact.

**On your own Mac** (macOS 14+, Xcode 16 or later):

```sh
git clone https://github.com/samidun26/dynamic-island-mac.git
cd dynamic-island-mac
QA/run-qa.sh "$PWD" /tmp/notchy-qa
open /tmp/notchy-qa/results.md
```

It takes about four minutes. While it runs it moves the pointer and types, so leave the Mac alone. It installs Notchy to `/Applications`, quits a running Notchy, and changes Notchy's settings, which it restores at the end. The terminal you run it from needs **Accessibility** (to move the pointer and press buttons) and **Screen Recording** (for the screenshots) in System Settings → Privacy & Security. Without them the cases that need them are skipped, not failed.

Use the Light appearance and a light wallpaper while it runs: the width checks measure the black island against the menu bar. On a Mac with a notch, the expected widths come from the real notch size, and QA-05 checks that the idle island covers the notch exactly; anything beyond what the runner tests needs the manual checklist above.
