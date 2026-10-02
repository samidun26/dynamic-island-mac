# Notchy: Product Requirements Document

| | |
|---|---|
| Product | Notchy, a Dynamic Island for the Mac notch |
| Version | 1.0 |
| Platform | macOS 14 Sonoma and later, Apple silicon and Intel |
| Status | v1.0 built, verified on CI and QA-tested end to end on a macOS session ([QA report](QA_REPORT.md)); hands-on testing on a notched MacBook still pending (see §12) |
| Last updated | 1 October 2026 |
| Related | [Requirements](REQUIREMENTS.md) · [Install and user guide](USER_GUIDE.md) · [QA report](QA_REPORT.md) · [Security review](SECURITY_REVIEW.md) · [README](../README.md) |

## 1. Summary

MacBooks since 2021 have a camera notch that sits in the menu bar and does nothing. Notchy turns it into a live, glanceable surface, like the iPhone's Dynamic Island: music, timers, meetings, charging and volume appear around the notch, and a hover or click expands it into small controls. The reference for quality is Alcove (tryalcove.com). It has to feel like part of macOS: no visible window, no stray clicks, no lag, near-zero idle CPU.

## 2. Problem

- The notch is dead space, and everything glanceable on a Mac (now playing, a running timer, the next meeting) lives in separate apps, menus or Control Center, all at least one click away.
- Existing notch apps often feel like a window pretending to be a notch: visible edges, jerky resizing, clicks that land on the overlay instead of the menu bar, and constant background CPU.
- Since macOS 15.4, Apple has restricted the private MediaRemote framework, so most third-party apps lost "Now Playing" for anything except Music and Spotify.

## 3. Goals and non-goals

### Goals

| ID | Goal |
|---|---|
| G1 | **Seamless.** Idle, the island is indistinguishable from the notch. Opening and closing look and feel like iOS: one fluid shape, springy, interruptible. |
| G2 | **Glanceable.** The most important live thing is visible beside the notch without any action. |
| G3 | **One gesture to control.** Hover, click or swipe gives play/pause/skip/seek, timer controls and a Join button. |
| G4 | **Never in the way.** It never takes focus, never blocks the menu bar or other apps, and does not open by accident. |
| G5 | **Light and private.** 0% CPU when idle; no account, no telemetry, no network use of its own. |
| G6 | **Honest.** Anything that needs a private API is opt-in and labelled, and anything that is not possible is documented rather than faked. |

### Non-goals (v1)

- Showing notifications from other apps, lock-screen widgets, a file tray or AirDrop shelf.
- Cloud sync, accounts, analytics or crash reporting.
- Mac App Store distribution (the Now Playing bridge and event tap are not sandbox-compatible).
- Copying Alcove's (or any GPL project's) code, assets, name or copy.

## 4. Users

| Persona | Needs |
|---|---|
| **Listener** (music or podcasts while working) | See what's playing, skip or pause without switching apps, works with Spotify, Music and browsers. |
| **Meeting-heavy professional** | Know the next meeting is coming, one click to join the call. |
| **Focused maker** (Pomodoro, cooking, builds) | Start a timer in one click, see the countdown at a glance, be told clearly when it ends. |
| **Detail-oriented Mac user** | Wants the notch to feel native; will uninstall anything janky, battery-hungry or in the way. |

## 5. Design principles

1. **Invisible until needed.** Idle equals the exact notch: same size, same position, pure black `#000`.
2. **The shape is the interface.** One continuous outline (flat top, concave "ears" into the bezel, round bottom corners) that grows and shrinks; content lives inside it and never spills out.
3. **Motion like iOS.** Springs, not easing curves. Content fades in with a blur a beat after the shape moves and leaves before it shrinks. Reversing mid-way never snaps.
4. **Respect the menu bar.** Only the visible island takes clicks; menu bar items next to the notch must stay clickable.
5. **Push, don't poll.** Everything is event-driven; nothing ticks when nothing is shown.

## 6. User stories

| ID | As a… | I want… | So that… |
|---|---|---|---|
| US-1 | listener | album art and a moving equaliser beside the notch while music plays | I know what's on without looking away |
| US-2 | listener | to hover the notch and get play/pause, skip, a scrubber and volume | I can control playback in one gesture |
| US-3 | listener | a brief pop-up when the track changes | I see the new song's name |
| US-4 | listener | it to work with YouTube in Safari/Chrome, not just Spotify | it covers everything I listen to |
| US-5 | maker | to start a 5/10/25-minute timer from the island, menu bar or a Shortcut | it's always one click away |
| US-6 | maker | a clear, audible "done" that then gets out of the way | I notice it without it nagging |
| US-7 | professional | a countdown before my next meeting and an alert at 5 minutes | I'm not late |
| US-8 | professional | a Join button for Zoom/Meet/Teams links | I join in one click |
| US-9 | anyone | a short "Charging 76%" when I plug in, and a warning at 20% and 10% | I don't need to check the menu bar |
| US-10 | anyone | volume changes shown in the island instead of the system HUD | it matches the rest of the island (optional) |
| US-11 | anyone | to move the pointer across the notch to the menu bar without it opening | it never gets in my way |
| US-12 | anyone | it hidden from screen sharing | my notch stays private in calls |
| US-13 | external-monitor user | a pill on displays without a notch, or nothing at all | it works with my setup |
| US-14 | anyone | to tune hover delay, haptics and animation | it feels right to me |

## 7. Functional requirements

Priority: **P0** must have, **P1** should have, **P2** nice to have.
Status: ✅ done · 🧪 done, experimental and opt-in · ⛔ not possible or not done (see §9).
Verified: **T** unit-tested · **R** rendered and inspected on CI · **L** running app checked on CI · **Q** passed the end-to-end QA run (installed per the user guide, driven with real input events and a test music app; [report](QA_REPORT.md)) · **H** needs a person on real hardware.

### 7.1 Window and shape

| ID | Requirement | Pri | Status | Verified |
|---|---|---|---|---|
| FR-W1 | One transparent, borderless, non-activating panel, sized once for the largest state and pinned top-centre. It never moves or resizes during animation. | P0 | ✅ | L, Q |
| FR-W2 | Click-through: only the visible island takes mouse events; the rest of the panel passes clicks to the menu bar and apps. | P0 | ✅ | T, Q |
| FR-W3 | Shape: flat top flush with the screen edge, concave ears at the top corners, continuous convex bottom corners. Width, height and both radii animate as one value. | P0 | ✅ | R |
| FR-W4 | Idle size and position come from `NSScreen.safeAreaInsets` and `auxiliaryTopLeftArea/RightArea`; pure black. | P0 | ✅ | T, R, H (alignment) |
| FR-W5 | Displays without a notch: a synthetic notch. Setting: show only when active (default), always, or never. | P1 | ✅ | T, R, Q |
| FR-W6 | Display choice: built-in (notch), main display, or the display with the pointer. Re-measure on hot-plug, resolution change, Space change and wake. | P1 | ✅ | H |
| FR-W7 | Above the menu bar and full-screen apps, on all Spaces; never key, never main; first click works. | P0 | ✅ | L, Q, H (full screen) |
| FR-W8 | Hidden from screen sharing and recordings (`sharingType = .none`), on by default, toggle in Settings. | P1 | ✅ | Q (`screencapture`), H (Zoom, Meet) |
| FR-W9 | Compact activities never cover app menus or menu bar icons beside the notch: they fit the free space (icons measured from the window list; menus via Accessibility when allowed), move to the free side, or fold into a thin progress line under the notch. On by default, toggle in Settings. | P0 | ✅ | T, Q |

### 7.2 Motion

| ID | Requirement | Pri | Status | Verified |
|---|---|---|---|---|
| FR-M1 | Springs: open 0.42 s / damping 0.80, close 0.36 s / 0.90, tunable in Settings with a Preview button. | P0 | ✅ | R |
| FR-M2 | Content transition: blur (10 pt) + scale (0.92) + fade; enters 60 ms after the shape starts moving, leaves in 130 ms. Content is clipped to the animated shape. | P0 | ✅ | R (filmstrip) |
| FR-M3 | Interruptible: a single `IslandState` (`idle`, `compact`, `expanded`, `peek`); reversing mid-animation retargets the spring. | P0 | ✅ | H |
| FR-M4 | Respects Reduce Motion: short crossfades instead of springs, blur and slides. | P1 | ✅ | H |
| FR-M5 | Haptic "alignment" tap on open, toggle in Settings. | P2 | ✅ | H |

### 7.3 Interaction

| ID | Requirement | Pri | Status | Verified |
|---|---|---|---|---|
| FR-I1 | Hover opens after a dwell (default 120 ms, adjustable 50–500 ms); fast sweeps (> 900 pt/s) never open it. | P0 | ✅ | T, Q, H (feel) |
| FR-I2 | Leaving closes it after 250 ms, with a 12 pt grace margin; never closes during a drag (scrubbing, volume). | P0 | ✅ | T, Q |
| FR-I3 | No hover-open while a modifier key or mouse button is held, or right after the island closed under the pointer. | P1 | ✅ | T, H |
| FR-I4 | Click opens and pins it; a click anywhere else dismisses it. | P0 | ✅ | Q |
| FR-I5 | Two-finger swipe: down opens, up closes, left/right switches page (open) or activity (compact). | P1 | ✅ | Q, H (real trackpad) |
| FR-I6 | Click-only mode: hovering only nudges the island (grows slightly) as an affordance. | P2 | ✅ | R |

### 7.4 Activity system

| ID | Requirement | Pri | Status | Verified |
|---|---|---|---|---|
| FR-A1 | Each activity has compact leading, compact trailing, minimal and expanded presentations. | P0 | ✅ | R |
| FR-A2 | A priority queue picks the activity in the wings: transient banners (HUD, charging) first, then the user's swipe choice, then priority, then recency. | P0 | ✅ | T |
| FR-A3 | Up to two other activities show as minimal glyphs next to the primary. | P1 | ✅ | R, Q |
| FR-A4 | Expanded pages: one per activity, plus Home (clock, next event, quick timers); page dots in the header. | P1 | ✅ | R |
| FR-A5 | Peek: auto-expand briefly on a track change (3 s), timer end (6 s) or meeting alert (6 s). | P1 | ✅ | R, Q |

Priority values: HUD 100, timer done 90, meeting within 5 min 80, battery banner 70, timer running 60, now playing 50, meeting in 5–15 min 30.

### 7.5 Now Playing

| ID | Requirement | Pri | Status | Verified |
|---|---|---|---|---|
| FR-N1 | Any app that reports to macOS Now Playing, browsers included, through the bundled mediaremote-adapter (one long-lived `perl` stream, JSON diffs). | P0 | ✅ | Q (test player through the system Now Playing), H (real players) |
| FR-N2 | Restart the stream with backoff (1, 2, 4… 30 s, at most 5 tries); after a fatal error fall back to Music and Spotify (their own notifications plus AppleScript). | P0 | ✅ | Q (restart), H (fallback) |
| FR-N3 | Compact: artwork left, equaliser tinted with the artwork's dominant colour right; stays 2.5 s after a pause so skipping does not flicker. | P0 | ✅ | R, Q |
| FR-N4 | Expanded: artwork, title, artist, source app, draggable scrubber (seek), elapsed/remaining, previous/play-pause/next, volume slider. | P0 | ✅ | R, Q |
| FR-N5 | Playhead interpolated locally from elapsed time, timestamp and playback rate; never polled. | P0 | ✅ | T |
| FR-N6 | Artwork decoded off the main thread, cached by track (24 entries); falls back to the source app's icon. | P1 | ✅ | R, Q |

### 7.6 Timer

| ID | Requirement | Pri | Status | Verified |
|---|---|---|---|---|
| FR-T1 | Start from Home (1/5/10 min), the menu bar (1/5/10/15/25/60 min) or `notchy://timer?minutes=N` / `?seconds=N`. | P0 | ✅ | T (URLs), R, Q |
| FR-T2 | Compact countdown; expanded ring, big countdown, +1 min, pause/resume, cancel. | P0 | ✅ | R, Q |
| FR-T3 | On completion: "Glass" sound (toggle), peek, then dismiss itself after 8 s. | P0 | ✅ | Q, H (sound) |
| FR-T4 | App Intent for Shortcuts and Spotlight. | P2 | ⛔ | (see §9) |
| FR-T5 | Pomodoro: focus and breaks in turn (25/5 min by default, a 15 min long break after every 4th focus; lengths in Settings), each phase starting the next with a sound and a peek. Started from Home ("Focus"), the menu bar or `notchy://pomodoro`; Skip moves to the next phase. Focus and break have their own colours and icons. | P1 | ✅ | T, R, Q |

### 7.7 Battery

| ID | Requirement | Pri | Status | Verified |
|---|---|---|---|---|
| FR-B1 | IOKit power-source notifications, never polled. | P0 | ✅ | H |
| FR-B2 | On plug-in: "Charging" (or "Connected" when full) with a bolt animation and percentage, for 3.5 s. | P1 | ✅ | R, H |
| FR-B3 | On battery: "Low Battery" at 20% and 10%, once each, for 5 s. | P1 | ✅ | H |
| FR-B4 | Battery percentage in the expanded header. | P2 | ✅ | R |

### 7.8 Calendar

| ID | Requirement | Pri | Status | Verified |
|---|---|---|---|---|
| FR-C1 | EventKit with the macOS 14 full-access permission flow; declined and all-day events ignored. | P0 | ✅ | H |
| FR-C2 | Quiet compact countdown from 15 min before; high-priority from 5 min before until 5 min after the start, with a one-time peek alert. | P1 | ✅ | R, H |
| FR-C3 | Join button for Zoom, Google Meet, Teams, Webex, Whereby, Jitsi and FaceTime links found in the URL, location or notes. | P1 | ✅ | T |
| FR-C4 | No polling: sleep until the next event boundary; refresh on calendar changes and wake. | P0 | ✅ | H |

### 7.9 HUD replacement (opt-in)

| ID | Requirement | Pri | Status | Verified |
|---|---|---|---|---|
| FR-H1 | Volume up/down/mute shown in the island instead of the system HUD (needs Accessibility; consumes the key and applies the change via CoreAudio). Option+Shift for quarter steps. | P1 | ✅ | H |
| FR-H2 | Devices without software volume, or no permission: pass the key through untouched. | P0 | ✅ | H |
| FR-H3 | While the island is open, show the level in the header. | P2 | ✅ | H |
| FR-H4 | Brightness like volume: keys shown in the island instead of the system HUD, and a slider under the volume slider in Now Playing. Built-in display, private DisplayServices; on by default, its own switch; keys pass through when unavailable. | P1 | ✅ | H |
| FR-H5 | Keyboard backlight keys. | P2 | ⛔ | — |

### 7.10 App, settings and distribution

| ID | Requirement | Pri | Status | Verified |
|---|---|---|---|---|
| FR-S1 | Menu bar icon (can be hidden; reopening the app shows Settings). | P1 | ✅ | L, Q |
| FR-S2 | Settings window with General, Activities, Motion and About tabs (see the user guide). | P0 | ✅ | Q |
| FR-S3 | Launch at login (`SMAppService`). | P1 | ✅ | H |
| FR-S4 | `notchy://` URLs: `timer`, `timer/cancel`, `pomodoro`, `shelf`, `clipboard`, `open`, `settings`, `update`. | P1 | ✅ | T, Q |
| FR-S5 | `build.sh` produces a signed `.app` (ad-hoc by default; Developer ID with hardened runtime documented). | P0 | ✅ | L, Q |
| FR-S6 | CI builds, tests and renders every state on each push; every app change on `main` publishes a numbered GitHub Release with its SHA-256. | P1 | ✅ | L |
| FR-S7 | `--demo <scenario>` and `--snapshot <dir>` for verification without a mouse. | P1 | ✅ | L |
| FR-S9 | Style: Classic (system font, smooth shapes) or Retro (bundled OFL pixel fonts Pixelify Sans and VT323, pixel-stepped corners, block meters, pixel-art covers), with a full-colour, green or amber screen and optional scanlines. | P2 | ✅ | R, Q |
| FR-S8 | In-app updates from GitHub Releases: checks on launch and every 6 hours (toggle), offers the update in the menu bar and Settings, verifies source, checksum, version and signature (same identity when releases are signed), swaps the app atomically and relaunches. | P1 | ✅ | T, Q |

### 7.11 Shelf and clipboard

| ID | Requirement | Pri | Status | Verified |
|---|---|---|---|---|
| FR-F1 | Files dragged to the notch open the island on the shelf, with a drop zone; dropping keeps them there (references only, never copies), and the shelf stays open to show them. | P1 | ✅ | R, Q |
| FR-F2 | Shelf files drag out to any app, open on double-click, and have Show in Finder / Remove; the list survives relaunches (bookmarks that follow moved files), up to 40. | P1 | ✅ | H |
| FR-CB1 | Clipboard history: the last 30 copied texts, newest first; click to copy back, pin to keep (pins survive relaunches), links open, colours show a swatch. | P1 | ✅ | T, R, Q |
| FR-CB2 | Privacy: history lives in memory only (only pins are saved); copies that apps mark private or temporary (the nspasteboard.org markers that password managers use) are never recorded; turning history off clears it; the QA trace never logs contents. | P0 | ✅ | T, Q |

### 7.12 Explicitly out (see §9)

| ID | Requirement | Status |
|---|---|---|
| FR-X1 | Focus / Do Not Disturb indicator | ⛔ no usable public API |
| FR-X2 | Other apps' notifications in the island | ⛔ private API; stretch goal |
| FR-X3 | Lock-screen presence | ⛔ private window-server API; stretch goal |

## 8. Non-functional requirements

| ID | Area | Requirement | Measured |
|---|---|---|---|
| NFR-1 | CPU | 0% when idle; animations and timelines run only while visible. | 0.0% Notchy, 0.0% adapter, 0 idle wake-ups/s (CI, all services on) |
| NFR-2 | Memory | Small and stable. | 12 MB app + 14 MB adapter process |
| NFR-3 | Latency | Hover-to-open ≈ dwell delay + one frame; no window resizes. | By design; H for feel |
| NFR-4 | Reliability | Adapter restarts with backoff, falls back if fatal, never outlives the app; orphans from a crash are cleaned up at launch. | L (exits with app), Q (restart without flicker, exits on quit) |
| NFR-5 | Privacy | No accounts, telemetry or analytics. Network use of its own: the update check on GitHub (can be turned off) and, in fallback mode, Spotify album art from Spotify's CDN. Every permission is optional and requested only when its feature is on. | Code review |
| NFR-6 | Compatibility | macOS 14+, universal binary, notched and non-notched displays, multiple displays. | L (CI on macOS 15) |
| NFR-7 | Accessibility | VoiceOver labels on controls; Reduce Motion honoured; text meets contrast on black. | Partly H |
| NFR-8 | Code quality | Swift 6 language mode; geometry, priority, hover intent and parsing unit-tested. | T |
| NFR-9 | Licensing | Third-party code BSD-3 only, credited in-app; no GPL code or Alcove assets. | Code review |
| NFR-10 | Security | Nobody can borrow Notchy's permissions: hardened runtime on every build, the Now Playing helper starts with a minimal environment, data from other apps, web pages and calendar invitations is never run as code or opened unless it is a known meeting link. See the [security review](SECURITY_REVIEW.md). | Q (injection attempts refused), T (hostile URLs) |

## 9. Constraints and things that are not possible

- **Now Playing on macOS 15.4+** works only because Apple's own `/usr/bin/perl` is still allowed to use MediaRemote. Apple could close this; Notchy then degrades to Music and Spotify.
- **System HUD suppression** is possible only by consuming the media key in an active event tap (Accessibility permission), and Notchy must then apply the change itself.
- **Brightness** has no public API on Apple silicon: it uses private DisplayServices, loaded with `dlopen`, built-in display only, with its own switch. **Keyboard backlight**: not implemented.
- **Focus:** `INFocusStatusCenter` needs a provisioned entitlement and only says yes or no; the alternative needs Full Disk Access. Not implemented.
- **Notifications and lock screen** need private SkyLight/CGS APIs or notification-database access. They would break with OS updates and are not App Store eligible, so they are not implemented.
- **App Intents** need Xcode's metadata extraction, which the SwiftPM build does not run. The `notchy://` URL from Shortcuts' "Open URLs" action covers the use case.
- **`sharingType = .none`** is honoured by system capture, but some third-party capture tools ignore it.

## 10. UX specification

Reference sizes for a 14" MacBook Pro (notch 185 × 32 pt). Everything derives from the measured notch, so other models scale.

| State | Size (pt) | Bottom radius | Ear radius |
|---|---|---|---|
| Idle (notch) | 185 × 32 | 10 | 4 |
| Idle, no notch, hidden | 0 high | 0 | 0 |
| Compact | (185 + 2 × wing) × 32 | 13 | 6 |
| Hover nudge (click-only mode) | +14 × +4 | +2 | — |
| Expanded / peek | max(470, notch + 300) × (notch + 128) → 485 × 160 | 32 | 12 |

Wing width per activity: Now Playing notch height + 12 (44), timer 64, calendar 66, HUD 88, battery 100, plus 22 per minimal glyph.

| Timing | Value |
|---|---|
| Hover open dwell / close delay / grace | 120 ms / 250 ms / 12 pt |
| Pass-through speed | 900 pt/s |
| Swipe thresholds | 36 pt horizontal, 26 pt vertical, 1.4 × dominance |
| Track-change peek / timer-done peek / meeting alert peek | 3 s / 6 s / 6 s |
| Paused-music grace before the wings collapse | 2.5 s |
| HUD visible after last key | 1.6 s |
| Charging banner / low-battery banner | 3.5 s / 5 s |
| Timer auto-dismiss after completion | 8 s |

Screens: see `docs/screenshots/` ([all states](screenshots/sheet-notch.png), [no notch](screenshots/sheet-nonotch.png), [open animation](screenshots/filmstrip-open.png), [close](screenshots/filmstrip-close.png)).

## 11. Architecture (summary)

- `NotchyCore` (plain Foundation, unit-tested): `NotchMetrics` (geometry), `ActivityQueue` (priority), `HoverIntent`, `AdapterStreamState` (Now Playing parsing), deep links, meeting links, spring curve, artwork tint.
- `Notchy` app: `IslandPanel` (window, click-through, mouse and trackpad), `IslandShape`, `IslandModel` (derives state and geometry and commits each change in one spring transaction), `IslandView`, services (Now Playing, Timer, Battery, Calendar, HUD), Settings.
- Details: [README → How it works](../README.md#how-it-works).

## 12. Success metrics and verification plan

| Metric | Target | How |
|---|---|---|
| Idle CPU | 0.0% | `top`/`sample` on CI on every push (done); Instruments on a notched Mac |
| Idle memory | < 40 MB total | CI (done: 26 MB incl. adapter) |
| Accidental opens | none when crossing the notch to the menu bar | Manual test on hardware (pending) |
| Animation hitches | 0 dropped frames on open/close | Instruments "Animation Hitches" on hardware (pending) |
| Idle alignment | no visible black edge around the notch | Visual check on 14" and 16" MacBook Pro and MacBook Air (pending) |
| Now Playing coverage | Music, Spotify, Safari, Chrome, Firefox, VLC, Podcasts | Manual matrix on hardware (pending) |

## 13. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Apple closes the perl/MediaRemote route | Now Playing limited to Music and Spotify | Automatic fallback; documented |
| Private DisplayServices changes | Brightness keys stop working | Opt-in, loaded with `dlopen`, keys pass through when unavailable |
| Ad-hoc signature changes on every rebuild | macOS forgets Accessibility and Automation grants | Documented; Developer ID signing path documented |
| Notch geometry differs per model | Thin black edge when idle | Geometry from `NSScreen` APIs, never hard-coded; verify per model |
| Unnotarized download | Gatekeeper blocks first launch | User guide steps; notarization path documented |

## 14. Release plan

| Version | Scope |
|---|---|
| 1.0 (this) | Everything marked ✅/🧪 above; CI build, tests, snapshots, tag-driven releases. |
| 1.1 | Hands-on tuning on notched hardware (alignment, springs, hover), Instruments pass, Developer ID signing and notarization. |
| 1.2 | Optional Xcode project for App Intents; per-app Now Playing filters; customisable quick-timer presets. |
| Later | Stretch goals from §9 only if a public API appears. |

## 15. Open questions

1. Should Notchy ship notarized builds (needs an Apple Developer ID, $99/year)?
2. Should hover-to-open stay the default, or should click-only be the default as on some competitors?
3. Which extra activities matter most next: AirPods/Bluetooth battery, file tray, weather, or system stats?
