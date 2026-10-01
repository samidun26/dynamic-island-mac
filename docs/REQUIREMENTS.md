# Requirements

What you need to run Notchy, to build it, and to distribute it. Product requirements (what Notchy does) are in the [PRD](PRD.md); installation steps are in the [user guide](USER_GUIDE.md).

## To run it

| | Requirement |
|---|---|
| macOS | **14 Sonoma or later** (built and run on macOS 15 in CI) |
| Mac | Apple silicon or Intel (the app is a universal binary) |
| Display | Any. A notched MacBook gives the intended look: MacBook Pro 14" and 16" (2021 and later), MacBook Air 13" (M2, 2022 and later) and MacBook Air 15" (2023 and later). On displays without a notch it shows a pill at the top centre, only while something is happening (configurable). |
| Disk | under 10 MB |
| Memory | about 12 MB, plus about 14 MB for the Now Playing helper process |
| CPU | 0% when idle (measured on CI with every activity enabled) |
| Network | Not required. Notchy makes no network requests of its own. One exception: in the Music/Spotify fallback mode, Spotify album art is loaded from the URL Spotify provides. |
| Trackpad | Optional; needed only for swipe gestures and haptic feedback |

### Permissions

All optional. Each is requested only when the feature that needs it is on, and the rest of the app works without it.

| Permission (System Settings → Privacy & Security) | Requested when | Used for | Without it |
|---|---|---|---|
| **Calendars** (full access) | Calendar activity is on (default) at first launch | Reading upcoming events for the countdown, alert and Join button | No calendar activity; Home shows "No calendar access" |
| **Accessibility** | You turn on *Volume HUD in the island* | Intercepting the volume keys so the system HUD stays hidden | Keys behave normally and macOS shows its own HUD |
| **Automation → Music / Spotify** | Only if the Now Playing bridge is unavailable and Notchy falls back | Artwork, Music's playhead, and controls in fallback mode | Fallback shows titles only, without controls |

Not needed: Screen Recording, Input Monitoring, Full Disk Access, Location, Microphone, Camera, Notifications.

### Now Playing support

| Source | How | Notes |
|---|---|---|
| Anything that appears in Control Center's Now Playing: e.g. Music, Spotify, Podcasts, and audio or video playing in Safari or Chrome | Bundled mediaremote-adapter (`/usr/bin/perl` stream) | Same source macOS itself uses; artwork depends on what the app or website provides |
| Music and Spotify only | Fallback when macOS blocks the adapter | Event-driven via the players' own notifications; controls via AppleScript |

## To build it

| | Requirement |
|---|---|
| macOS | 14 or later |
| Toolchain | **Xcode 16 or later** (Swift 6). The Command Line Tools alone are enough for a single-architecture build; a universal build (`UNIVERSAL=1`) needs full Xcode. |
| Tools | `git`, `clang` and `codesign` (from Xcode or the CLT); `iconutil` and `perl` ship with macOS |
| Network | Only to clone the repository. All dependencies, including mediaremote-adapter, are vendored. |
| Tests | `swift test` runs the core tests on macOS, and on Linux with a Swift 6 toolchain |

```sh
xcode-select --install          # if you have neither Xcode nor the Command Line Tools
./build.sh                      # → build/Notchy.app
```

## To distribute it

| Channel | Needs |
|---|---|
| Local use, or sharing the CI build | Nothing extra. Ad-hoc signed and not notarized, so first launch needs the Gatekeeper steps in the user guide. |
| Notarized download (no Gatekeeper warning) | Apple Developer Program membership, a *Developer ID Application* certificate, and `notarytool` credentials. Build with `SIGN_IDENTITY="Developer ID Application: …" ./build.sh`, which enables the hardened runtime and `Resources/Notchy.entitlements`, then notarize and staple (see README). |
| GitHub Release | Push a tag like `v1.0.0`; CI builds the universal app and attaches `Notchy.zip` to a release. |
| Mac App Store | Not supported: the Now Playing bridge, the media-key event tap and the overlay above the menu bar are not compatible with the App Sandbox. |

## Signing and permissions caveat

macOS ties Accessibility and Automation grants to the app's code signature. An ad-hoc signed build gets a new signature every time it is rebuilt, so after replacing the app you may need to switch Notchy off and on again in *Privacy & Security → Accessibility* (and Automation, if used). A Developer ID signature avoids this.
