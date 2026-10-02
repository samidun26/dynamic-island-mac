# Notchy install and user guide

- [1. Install](#1-install)
- [2. First launch](#2-first-launch)
- [3. Using the island](#3-using-the-island)
- [4. Activities](#4-activities)
- [5. Menu bar, URLs and Shortcuts](#5-menu-bar-urls-and-shortcuts)
- [6. Settings](#6-settings)
- [7. Troubleshooting](#7-troubleshooting)
- [8. Updating](#8-updating)
- [9. Uninstall](#9-uninstall)

Check the [requirements](REQUIREMENTS.md) first: macOS 14 or later, ideally a MacBook with a notch.

## 1. Install

Pick one of three ways.

### A. Download a release (easiest)

1. Open the repository's [Releases](https://github.com/samidun26/dynamic-island-mac/releases) page and download **Notchy.zip** from the latest release.
   (No release yet? Use option B or C. Releases are published automatically when the app changes on `main`, see §1.D.)
2. Double-click the zip, then drag **Notchy.app** into **Applications**.
3. Open it once (see "Allow it to open" below).

### B. Download the latest CI build

Needs a GitHub account.

1. Go to the [Actions tab](https://github.com/samidun26/dynamic-island-mac/actions), open the most recent green **build** run.
2. Under **Artifacts**, download **Notchy-app**. It contains `Notchy.zip`; unzip it and move **Notchy.app** to **Applications**.

### C. Build from source

```sh
git clone https://github.com/samidun26/dynamic-island-mac.git
cd dynamic-island-mac
./build.sh                       # host architecture; UNIVERSAL=1 ./build.sh for arm64 + x86_64
cp -R build/Notchy.app /Applications/
open /Applications/Notchy.app
```

A build you made yourself is not quarantined, so it opens without the Gatekeeper steps below.

### Allow it to open (downloads only)

Downloaded builds are signed but not notarized, so macOS blocks the first launch. Allowing it tells macOS to trust that copy, so first check it is the file CI built. Each release lists its SHA-256 checksum and has a `Notchy.zip.sha256` file next to the zip:

```sh
cd ~/Downloads
shasum -a 256 -c Notchy.zip.sha256    # must print "Notchy.zip: OK"
```

Then do **one** of these:

- **System Settings:** try to open Notchy, dismiss the warning, then go to **System Settings → Privacy & Security**, scroll to *"Notchy" was blocked…* and click **Open Anyway**.
- **Terminal:**
  ```sh
  xattr -dr com.apple.quarantine /Applications/Notchy.app
  open /Applications/Notchy.app
  ```

### D. Publish a release (maintainers)

Nothing to do by hand: whenever a change to the app (`Sources/`, `Resources/`, `Vendor/`, `Package.swift`, `build.sh` or `VERSION`) lands on `main`, the **release** workflow builds the universal app, numbers it (`VERSION` + a running number: 1.0.1, 1.0.2, …) and publishes a GitHub Release with `Notchy.zip`, its SHA-256 and notes listing the changes. Everyone who has Notchy is then offered the update (see §8).

- **A bigger step:** change `VERSION` (for example to `1.1` or `2.0`) in the same change.
- **Publish again without a change:** Actions → **release** → Run workflow (on `main`).
- **Recommended once: a release signing identity.** On your Mac, with the [GitHub CLI](https://cli.github.com) logged in:
  ```sh
  scripts/setup-signing.sh
  ```
  It creates a code signing identity and stores it in the repository's secrets; every release is then signed with it. Without it, releases are ad-hoc signed and macOS treats each update as a new app, so people have to allow Calendars and Accessibility again after updating. With it, macOS keeps those permissions, and Notchy accepts only updates signed with that identity.

## 2. First launch

- Notchy has **no Dock icon and no window**. Look for its icon in the menu bar: a small screen outline with a pill at the top.
- On a notched MacBook, **nothing visible changes** while nothing is happening: the island is exactly the size of the notch. That's intended.
- macOS asks for **Calendar** access (the calendar activity is on by default). Allow it to get meeting countdowns, or decline and turn the calendar off in Settings.
- To check it's working, start some music, or choose **Start Timer → 1 min** from the menu bar icon. The island grows "wings" around the notch.
- Optional: **Settings → General → Launch at login**.

## 3. Using the island

| Do this | What happens |
|---|---|
| Rest the pointer on the notch | Opens after a short pause (120 ms by default). Passing quickly across the notch does nothing. |
| Move the pointer away | Closes after a quarter of a second, unless you are dragging a slider |
| Click the island | Opens it and keeps it open |
| Click anywhere else | Closes a pinned island |
| Two-finger swipe **down** on it | Opens and keeps it open |
| Two-finger swipe **up** on it | Closes it |
| Two-finger swipe **left / right** on it | Open: next / previous page. Closed: brings the next running activity into the wings |
| Click a page dot (top right when open) | Jumps to that page |

Holding ⌘, ⌥, ⌃, ⇧ or a mouse button pauses hover-to-open, so you can drag things past the notch.
Prefer clicking? Turn off **Settings → General → Open when the pointer rests on the notch**; hovering then only nudges the island.

### What you see

- **Idle:** just the notch.
- **Compact:** something is running. Its icon is on the left of the notch and its status on the right. If several things are running, the most important one gets the wings and the others appear as small glyphs.
- **Expanded:** hover or click. A header beside the notch shows what you're looking at (left) and page dots plus battery (right). Below it are the controls.
- **Peek:** the island opens by itself for a few seconds on a new song, a finished timer or a meeting alert, then closes.

## 4. Activities

### Now Playing
- **Compact:** album art · equaliser in the album's colour.
- **Expanded:** art, title, artist, the app it's playing in, a progress bar (**drag it to seek**), previous / play-pause / next, and a **volume slider**.
- Works with anything that appears in Control Center's Now Playing: Music, Spotify, Podcasts, audio or video in Safari and Chrome, and so on.
- A new song shows for 3 seconds (turn off: Settings → Activities → *Show the track for a moment when it changes*).
- Paused music leaves the wings after a couple of seconds but stays as a page when you open the island, so you can resume it.

### Timer
- **Start:** Home page (1, 5, 10 min), the menu bar (1, 5, 10, 15, 25, 60 min), or a URL/Shortcut (§5).
- **Compact:** ⏱ · countdown. **Expanded:** progress ring, big countdown, **+1 min**, pause/resume, cancel.
- **When it ends:** a "Glass" sound (can be turned off), the island opens with *Time's up*, then clears itself after 8 seconds or when you click **Dismiss**.

### Pomodoro
- **Start:** **Focus** on the Home page, menu bar icon → **Start Timer → Pomodoro**, or `notchy://pomodoro`.
- Runs **25 minutes of focus, then a 5-minute break**, and after every fourth focus a **15-minute long break**, round after round until you cancel. Each change plays a sound and shows the island for a moment.
- Focus is coral with a 🧠, breaks are green with a ☕. The timer page says where you are ("Focus 2 of 4", "Short break"); **Skip** jumps to the next phase, and pause and cancel work as for any timer.
- Change the focus and break lengths in **Settings → Activities**.

### Shelf: files
- **Drag files to the notch** (from Finder, the desktop, Mail…). The island opens on the shelf with a drop zone; let go and the files stay there. The shelf stays open until you move the pointer away, so you can see what landed.
- **Drag them out** to any app or folder when you need them; double-click opens one; right-click for **Show in Finder** and **Remove from Shelf**; **Clear** empties it.
- Notchy keeps a reference to each file, never a copy. The shelf survives restarts and follows files you move. Up to 40 files.
- Open it any time: swipe to the last page of the island, or `notchy://shelf`.

### Shelf: clipboard history
- The **Clipboard** tab lists the last 30 texts you copied, newest first. **Click one to copy it again.**
- 📌 **Pin** keeps an item at hand (pins survive restarts); **Clear** removes everything except pins. Links get an ↗ button to open them; colour codes like `#FF6B54` show a swatch.
- **Privacy:** the history lives in memory only and is gone when Notchy quits (only pins are saved). Copies that apps mark as private, such as passwords from 1Password, Bitwarden, KeePassXC or Keychain Access, are never recorded. Turning clipboard history off clears it. Notchy is hidden from screen sharing by default, so the shelf doesn't show up in recordings either.
- Open it directly: `notchy://clipboard`. Turn it off in **Settings → Activities**.

### Calendar (Up Next)
- From 15 minutes before an event: a quiet countdown ("in 12m").
- At 5 minutes: it takes priority and the island opens briefly as an alert.
- **Expanded:** your next three events with times, location and a green **Join** button for Zoom, Google Meet, Teams, Webex, Whereby, Jitsi and FaceTime links.
- All-day and declined events are ignored.

### Battery
- Plugging in shows **⚡ Charging 76%** (or *Connected* when full) for a few seconds.
- On battery, it warns once at **20%** and once at **10%**.
- The battery percentage is always in the expanded header.

### Volume HUD (off by default)
1. **Settings → Activities → Volume HUD in the island**.
2. Click **Grant Accessibility…**, switch Notchy on in *Privacy & Security → Accessibility*. Notchy picks it up automatically.
3. The volume keys now show a level in the island instead of the big system HUD. **⌥⇧ + volume** changes in quarter steps.
- **Brightness works the same way:** the brightness keys show a sun and a level in the island instead of the system HUD, and Now Playing has a brightness slider under the volume one. This is for the built-in display and uses a private Apple framework (there is no public way), so a macOS update could break it; the keys then go back to macOS. Turn it off with *Brightness in the island*. Keyboard backlight keys always use the system HUD.
- If your output device has no software volume (some HDMI/USB devices), Notchy leaves the keys to macOS.

### Home
The page you see when nothing else is running: a large clock and date, one-click timers and **Focus** (a Pomodoro), and an **Up Next** card with your next event and its Join button. The shelf is the page after it.

## 5. Menu bar, URLs and Shortcuts

**Menu bar icon:** Open Island · Start Timer ▸ (1, 5, 10, 15, 25 min, 1 hour, Pomodoro, Cancel Timer) · Settings… · Check for Updates… · Quit Notchy. When an update is waiting, the icon gets a dot and the menu starts with **Update to Notchy x.y.z…**.

**URLs** (Terminal, scripts, launchers, Shortcuts):

| URL | Action |
|---|---|
| `notchy://timer?minutes=25` | Start a 25-minute timer |
| `notchy://timer?seconds=90` | Start a 90-second timer (`minutes` and `seconds` can be combined) |
| `notchy://timer/cancel` | Cancel the timer (or the Pomodoro) |
| `notchy://pomodoro` | Start a Pomodoro |
| `notchy://shelf` | Open the island on the shelf's files |
| `notchy://clipboard` | Open the island on clipboard history |
| `notchy://open` | Open the island and keep it open |
| `notchy://settings` | Open Settings |
| `notchy://update` | Open Settings → About and check for an update |

```sh
open "notchy://timer?minutes=25"
```

**Shortcuts:** create a shortcut with the **Open URLs** action set to `notchy://timer?minutes=25`. Add it to the menu bar, a keyboard shortcut or Siri. (Native Shortcuts actions are not available in this build; see the PRD.)

## 6. Settings

Open with the menu bar icon → **Settings…**, or `notchy://settings`, or by opening Notchy.app again (useful if you hid the menu bar icon).

| Tab | Setting | Default |
|---|---|---|
| General | Open when the pointer rests on the notch | On |
| | Hover delay (50–500 ms) | 120 ms |
| | Haptic feedback when opening (Force Touch trackpads) | On |
| | Hide from screen sharing and recordings | On |
| | Show the island on: built-in display (notch) / main display / display with the pointer | Built-in |
| | On displays without a notch: only when something is happening / always (fake notch) / never | Only when active |
| | Style: **Classic** or **Retro** (pixel type, stepped corners, block meters, pixel-art album covers); in Retro, the screen in full colour, green or amber, and scanlines on or off | Classic |
| | Keep clear of menus and menu bar icons: live activities fit into the free menu bar space beside the notch, move to the other side when one side is taken, and show as a thin line under the notch when there's no room. Seeing where app menus end needs Accessibility (*Allow Accessibility…*); until then activities stay right of the notch | On |
| | Launch at login | Off |
| | Show menu bar icon | On |
| Activities | Now Playing, and its track-change preview | On, on |
| | Timer, and its end sound | On, on |
| | Pomodoro focus and break lengths (focus 5–90 min, break 1–30 min) | 25 min, 5 min |
| | Shelf (files dropped on the notch) | On |
| | Clipboard history (memory only; private copies never kept) | On |
| | Charging and low battery | On |
| | Calendar (shows access status) | On |
| | Volume HUD in the island (shows Accessibility status) | Off |
| | Brightness in the island (keys and slider, built-in display) | On |
| Motion | Open and close spring response and damping, Preview, Reset | 0.42 s / 0.80, 0.36 s / 0.90 |
| About | Version, update status (**Check for Updates**, **What's New**, **Install and Relaunch**), credits, the mediaremote-adapter license | — |
| | Check for updates automatically (on launch and every 6 hours) | On |

If **Reduce motion** is on in *System Settings → Accessibility → Display*, Notchy uses short fades instead of springs.

## 7. Troubleshooting

| Problem | Fix |
|---|---|
| **"Notchy is damaged" / "can't be opened"** | It's a downloaded build without notarization. Follow *Allow it to open* in §1. |
| **Nothing shows at all** | It's idle, which is normal. Start a timer from the menu bar icon to check. On a display without a notch, the island only appears while something is happening; change *On displays without a notch* to *Always* to see it all the time. |
| **It's on the wrong display** | Settings → General → *Show the island on*. |
| **Music shows only as a thin line under the notch** | There's no free menu bar space next to the notch: menus or menu bar icons reach it. Hover the notch to open it as usual. Fewer menu bar icons (or allowing Accessibility, so Notchy can use the space left of the notch) gives the wings room. To let the wings cover menu bar items instead, turn off Settings → General → *Keep clear of menus and menu bar icons*. |
| **No menu bar icon** | You hid it. Open Notchy.app again from Applications or Spotlight to get Settings. |
| **Now Playing shows nothing** | Check Settings → Activities → *Source*. "System Now Playing" means the bridge works; the player must report to macOS Now Playing (most do; in browsers, media must be playing in a tab). "Music and Spotify (fallback)" means macOS blocked the bridge, so other players can't be shown. |
| **Fallback mode has no artwork or controls** | Allow Notchy under *Privacy & Security → Automation* for Music/Spotify. |
| **No meetings** | Settings → Activities → Calendar → Allow, or enable Notchy in *Privacy & Security → Calendars*. Only timed events in the next 36 hours are shown. |
| **Volume keys still show the system HUD** | Grant Accessibility (§4). After rebuilding or updating the app, switch Notchy off and on in the Accessibility list: macOS ties the grant to the app's signature. |
| **Brightness keys or slider do nothing** | Brightness works only on the built-in display, and only while macOS's private brightness framework is there. Turn off *Brightness in the island* to give the keys back to macOS. |
| **The island doesn't appear in screenshots or screen sharing** | That's the privacy default. Turn off *Hide from screen sharing and recordings*. |
| **"Launch at login" shows an error** | Move Notchy.app to /Applications first, then toggle it again. |
| **Hover opens it by accident** | Increase the hover delay, or turn off hover-to-open and use clicks. |

## 8. Updating

Notchy looks for a new release on GitHub shortly after it starts and every 6 hours. When there is one:

1. The menu bar icon gets a small dot, and its menu starts with **Update to Notchy x.y.z…**.
2. That opens **Settings → About**: **What's New** lists the changes, **Install and Relaunch** updates.
3. Notchy downloads the release, checks it, replaces itself and starts again, about ten seconds in all. Your settings stay as they were.

Before replacing anything, Notchy checks that the download comes from GitHub over HTTPS, matches the release's SHA-256, is a validly signed Notchy of that version, and (once releases have a signing identity) is signed with the same identity as the copy you have. If any check fails nothing is changed, and Settings says why.

- **Check now:** menu bar icon → **Check for Updates…**, or `notchy://update`.
- **Turn automatic checks off:** Settings → About → *Check for updates automatically*. This is the only request Notchy makes to the internet on its own; it sends nothing about you.
- **Notchy can't replace itself** (it's in a folder you can't write to): download the release from GitHub and replace the app by hand.
- **After an update, the calendar or the volume keys stop working:** that happens with releases that are ad-hoc signed (see §1.D). Allow Notchy again in *System Settings → Privacy & Security* (*Calendars*, *Accessibility*); if Notchy is already listed and switched on, remove it with **−** and add it again.

## 9. Uninstall

1. Turn off **Launch at login** in Settings, then **Quit Notchy** from the menu bar icon.
2. Delete **/Applications/Notchy.app**.
3. Optional clean-up in Terminal:
   ```sh
   defaults delete dev.local.notchy            # preferences
   tccutil reset Accessibility dev.local.notchy
   tccutil reset Calendar dev.local.notchy
   tccutil reset AppleEvents dev.local.notchy
   ```
