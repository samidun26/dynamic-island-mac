# Security review

| | |
|---|---|
| Scope | The Notchy app (`Sources/`), the vendored Now Playing helper (`Vendor/mediaremote-adapter`), `build.sh`, signing and entitlements, the CI workflows (`.github/workflows/`), the release and install path, and the QA harness (`QA/`) |
| Version | Branch `claude/youthful-maxwell-tdlzo2` at the commit that adds this file |
| Date | 1 October 2026 |
| Method | Code review of every source file and workflow; a search of every commit in the git history for credentials; attack tests run on macOS by the QA workflow ([QA-33, QA-34](qa/results.md)); unit tests for hostile inputs |

## Summary

**No breach and no high or critical issue was found.** Nothing in the repository or its history is a secret (no tokens, keys or passwords; the workflows use only GitHub's built-in per-run token). The app has no network listener and no account, and sends nothing about you anywhere. Its own requests are the update check and downloads from GitHub (added later, reviewed in [Updates](#updates)) and Spotify album art in fallback mode.

Eight issues were found: **seven are fixed** in this branch, and the eighth (releases aren't notarized) is mitigated. The two most serious (rated **medium**) were local only: another program already running on the Mac as the same user could have *borrowed the permissions you granted Notchy* (Accessibility, Calendars, Automation) by launching it with a crafted environment. macOS would not have asked you again. Both fixes are verified on macOS by the QA run. Each attack is first shown to work against an unprotected program, then shown to fail against Notchy.

| Severity | Found | Fixed | Remaining |
|---|---|---|---|
| Critical | 0 | — | 0 |
| High | 0 | — | 0 |
| Medium | 3 | 2 | 1 accepted, mitigated (not notarized: needs a paid Apple Developer account) |
| Low | 5 | 5 | 0 |
| Informational | 11 | — | by design, documented below |

Severity reflects how the issue can be reached and what it gives an attacker. **Medium:** local, needs code already running as you, but grants permissions you gave Notchy without asking. **Low:** needs several unusual conditions, or impact is limited to a nuisance or a hang. **Informational:** works as intended, listed so the trade-off is visible.

## Attack surface

What can feed data into Notchy, and who controls it:

| Input | Who controls it | Handling |
|---|---|---|
| Now Playing title, artist, album, app ID, artwork | Any app, **and any web page** playing media (browsers publish the page's Media Session metadata) | Displayed as plain text (no Markdown or HTML rendering); artwork decoded as a 300 px thumbnail with ImageIO, at most 16 MB; the app ID is used only to look up an icon, never as code |
| Calendar events (title, location, notes, URL) | **Anyone who sends you an invitation** | Displayed as plain text; "Join" only for links to known meeting hosts (Zoom, Meet, Teams, Webex, Whereby, Jitsi, FaceTime, Around) |
| `notchy://` URLs | Any app; web pages after the browser asks you | Start or cancel a timer or a Pomodoro, open the island, the shelf or Settings, check for updates; numbers validated; no setting can be changed and nothing can be read through a URL |
| Clipboard text | **Any app, and any web page** you copy from (pages can also copy on click) | Recorded only while clipboard history is on; shown as plain text; only `http`/`https` links get an open button; copies marked private are skipped (see [Shelf and clipboard](#shelf-and-clipboard)) |
| Files dropped on the shelf | You | Notchy keeps only a reference (a bookmark) and never reads, copies or runs the file; opening one is the same as double-clicking it in Finder |
| Launch environment | Whoever starts Notchy | Hardened runtime ignores injected libraries; the helper starts with a minimal environment (SR-1, SR-2) |
| Music and Spotify (fallback mode) | Those apps | Fixed AppleScript texts; only those two apps are ever scripted (SR-3) |
| Spotify artwork URL (fallback mode) | Spotify | HTTPS to Spotify's CDN only, 5 s timeout (SR-4) |
| Media keys | You | The key tap sees only media/system-defined key events, never typing |
| Update releases | Whoever can publish a release on the repository | HTTPS from GitHub only, checksum, version and signature checks before an atomic swap (see [Updates](#updates)) |

## Findings

### SR-1 · Medium · Fixed: library injection could borrow Notchy's permissions

**What:** `build.sh` signed the default (ad-hoc) build without the hardened runtime. Any program running as you could start Notchy with `DYLD_INSERT_LIBRARIES=evil.dylib`, which runs that library's code inside Notchy. Code inside Notchy acts with Notchy's privacy permissions: Accessibility if you enabled the volume HUD (read the screen's UI, type and click), Calendars, and Automation for Music and Spotify. macOS doesn't ask again. This is a well-known class of macOS permission bypass.

**Fix:** two layers, because the first one turned out not to be enough on its own:

1. Ad-hoc builds are now signed with the hardened runtime (`--options runtime`) and only the two entitlements Notchy needs (Apple Events, Calendars), as Developer ID builds already were. No exception entitlements (`allow-dyld-environment-variables`, `disable-library-validation`, JIT) are used.
2. The QA attack test showed that macOS does **not** apply the hardened runtime's `DYLD_*` restriction to an ad-hoc signed app: the test library still ran inside Notchy. So the executable now also carries a `__RESTRICT` segment (a linker flag in `Package.swift`), which makes the loader ignore `DYLD_*` variables whatever the signature.

**Verified:** QA-33. A test library injected with `DYLD_INSERT_LIBRARIES` runs in a plain program, but not in Notchy.

### SR-2 · Medium · Fixed: Perl variables could inject code into the Now Playing helper

**What:** Now Playing runs the bundled adapter in Apple's `/usr/bin/perl`, started by Notchy. The child process inherited Notchy's whole environment. Perl loads extra code named in `PERL5OPT` and `PERL5LIB`, and the hardened runtime doesn't strip those. Starting Notchy with these variables (for example `open --env PERL5OPT=-Mevil -a Notchy`) ran attacker code in the helper. macOS attributes the helper's privacy access to Notchy, so this gave the same result as SR-1.

**Fix:** the helper now starts with a minimal environment (`HOME`, `USER`, `LOGNAME`, `TMPDIR`, language variables, and a fixed `PATH`), for the long-running stream and for each play/pause/seek command (`AdapterStream.environment` in `NowPlayingService.swift`).

**Verified:** QA-34. With `PERL5OPT`/`PERL5LIB` set, a test module runs in plain `perl` but not in Notchy's helper, and Now Playing keeps working.

### SR-3 · Low · Fixed: an app ID could reach AppleScript in fallback mode

**What:** when the adapter fails, Notchy falls back to scripting Music and Spotify. Its play/pause/next/seek commands put the current track's app ID into AppleScript source (`tell application id "…"`). Right after a fallback, the current track can still come from the system Now Playing, whose app ID is set by whatever app is playing. A local app with a crafted ID containing quotes could then have AppleScript of its choice run by Notchy on your next click of play/pause. That includes `do shell script`, running with Notchy's permissions.

**Fix:** the fallback only ever scripts `com.apple.Music` or `com.spotify.client`. Any other ID is ignored and never reaches script source. Seek positions must be finite numbers.

### SR-4 · Low · Fixed: Spotify artwork URL fetched without checks

**What:** in fallback mode, the album-art URL reported by Spotify was fetched with `Data(contentsOf:)`. That accepted any scheme and host (plain HTTP, `file://`, anything). It had no timeout, and ran on the queue that also sends play/pause, so a stalled server would freeze the controls.

**Fix:** fetched only over HTTPS from Spotify's image CDN (`*.scdn.co`, `*.spotifycdn.com`), with an ephemeral session, a 5 s request timeout and a 10 s total limit, off the AppleScript queue (`SpotifyArtwork.url`, unit-tested).

### SR-5 · Low · Fixed: no size limit on artwork

**What:** artwork comes from any app or web page that reports Now Playing. It was decoded as a thumbnail (which bounds the decoded image), but any size of input was accepted.

**Fix:** artwork over 16 MB is ignored before decoding.

### SR-6 · Low · Fixed: workflow input pasted into a shell script

**What:** the `qa` workflow inserted its `ref` input into the script text with `${{ inputs.ref }}`, the pattern behind GitHub Actions script injection. Only people with write access can start that workflow, so it was not exploitable by outsiders.

**Fix:** the value is passed through an environment variable and used quoted, with `--` after it.

### SR-7 · Medium · Mitigated, accepted: releases aren't notarized

**What:** release builds are ad-hoc signed and not notarized, so the user guide tells people to allow the app in System Settings or remove the quarantine flag. That switches off Gatekeeper's check for that copy. A tampered download wouldn't be caught.

**Done:** each release now has a SHA-256 checksum, in the release notes and as `Notchy.zip.sha256`. The user guide asks you to check it (`shasum -a 256 -c Notchy.zip.sha256`) before allowing the app. Releases are built only by CI from a tagged commit.

**Remaining:** proper code signing and notarization need an Apple Developer ID (paid account). `build.sh` already supports it (`SIGN_IDENTITY=…`); see [REQUIREMENTS.md](REQUIREMENTS.md#to-distribute-it). Until then, building from source is the most trustworthy install.

### SR-8 · Low · Fixed: the QA harness trusted the "menu opened" signal

Not a vulnerability in the app, but a test-integrity issue found during this work. The menu delegate's callback also fires when an accessibility client merely reads the menu, so a test could pass without the menu opening. The QA checks now look for the menu's own window on screen.

## Updates

Added after the review above, at the owner's request: Notchy updates itself from the repository's GitHub Releases, and every app change on `main` publishes a release. An updater is the most powerful thing in an app (whatever it installs runs as you, with every permission you gave Notchy), so it is built to install nothing but a genuine release.

| Threat | What stops it |
|---|---|
| Someone on the network (café Wi‑Fi, a proxy) swaps the download | Only HTTPS, only `github.com`, `api.github.com` and `*.githubusercontent.com`, including where redirects lead; then the SHA-256 published with the release |
| A corrupted or truncated download | SHA-256 check; size limit (100 MB); the app must unpack to a Notchy.app with Notchy's bundle ID and exactly the announced version |
| An older release offered again (downgrade) | Only versions newer than the installed one are offered |
| A release built by someone else | With a release signing identity (`scripts/setup-signing.sh`), the update must satisfy the installed copy's designated requirement, so only the holder of that key can sign an update. QA-39 shows an update signed by another identity being refused. Without it (ad-hoc releases), authenticity rests on the GitHub account and HTTPS |
| A half-finished install | Unpacked and checked next to the app, then swapped with one atomic rename. Any failure leaves the installed app as it was (QA-38) |
| Another program on the Mac redirecting the updater | The update source is fixed in the code; a test source can be set only in Info.plist, which is covered by the signature, so changing it means replacing the app. The QA install switch works only with such a test source |

**Remaining risk (by design):** anyone who can publish on the repository can ship code to every installed copy. That is true of any app that updates itself. Protect it: turn on two-factor authentication for the GitHub accounts with write access, protect `main` (Settings → Branches: require a pull request), and set up the release signing identity. A verified, installed update is opened without Gatekeeper's prompt, like any self-updating Mac app.

## Shelf and clipboard

Added after the review above, at the owner's request (features in the spirit of other notch apps: a Pomodoro timer, a file shelf and clipboard history). The Pomodoro timer handles no outside data. The other two do, and the clipboard is one of the most sensitive things on a Mac: passwords, one-time codes, private messages and API keys all pass through it.

| Threat | What stops it |
|---|---|
| Passwords copied from a password manager end up in the history | Copies that carry the [nspasteboard.org](http://nspasteboard.org) markers (`ConcealedType`, `TransientType`, `AutoGeneratedType`) or the older 1Password, KeeWeb, TypeIt4Me and generator markers are never recorded. 1Password, Bitwarden, KeePassXC, Keychain Access and most password tools set them. Unit-tested, and QA-42 copies a marked text on macOS and checks it appears nowhere: not in the island, not in the trace |
| The history lingers or reaches disk | The history is in memory only and is gone when Notchy quits; turning clipboard history (or the shelf) off clears it. Only items you **pin** are saved, as plain text in Notchy's preferences file, so don't pin secrets |
| Secrets copied from apps that don't mark them (a terminal, a text file) | They are recorded like any copy, as in every clipboard manager. They are visible only when you open the shelf, Notchy is hidden from screen sharing by default, and you can turn history off in Settings → Activities |
| A web page copies something hostile onto your clipboard | Shown as plain text (no Markdown, HTML or rich text); only `http`/`https` links get an ↗ button, so `javascript:`, `file:` and custom schemes are never opened; at most 20,000 characters per item and 30 items. Clicking an item copies back plain text only |
| Contents in logs | The QA trace logs only the length of a copy ("CLIP added 12 characters"), never its text |
| Reading the clipboard when nothing changed | Notchy reads only the clipboard's change counter twice a second, and reads the contents only after a change. Newer macOS versions may ask whether Notchy may read what other apps copied; say no, or turn history off, and Notchy never reads it |
| Dropped files | Notchy remembers where they are (bookmarks), never reads, copies or uploads them; opening one goes through Finder's usual checks (Gatekeeper and quarantine still apply). The drop target reacts only to file drags that start while the button is held, and only near the notch |

## Informational (by design)

- **Not sandboxed.** The App Sandbox doesn't allow starting `/usr/bin/perl` for the adapter or watching the pointer everywhere for hover. The hardened runtime is on, with only the Apple Events and Calendars entitlements.
- **Permissions are asked for only when needed.** Calendars is asked for at first launch, because the calendar activity is on by default; decline it, or turn the activity off, and Notchy never reads your calendar. Accessibility is asked for only if you turn on the volume HUD, or press *Allow Accessibility…* under "Keep clear of menus and menu bar icons" (Notchy then reads only the positions of the frontmost app's menu titles, off the main thread and with a 0.25 s limit, never their contents or anything else on screen). Automation is asked for only in fallback mode, and only for Music or Spotify. Each can be revoked in System Settings at any time.
- **The media-key tap** is an active tap on system-defined events (media and volume keys) only. It can't see typing.
- **Private API.** The brightness option uses Apple's private DisplayServices framework, loaded from its fixed system path. It is used only for the built-in display's brightness, has its own switch, and fails closed: if the symbols are missing the keys go back to macOS.
- **The `notchy://` scheme** can be opened by any app, and by web pages after the browser asks. The worst it can do is start or cancel a timer or a Pomodoro, open the island, the shelf or Settings, or check for updates. It can't read the shelf or the clipboard history. Hostile numbers (NaN, infinity, negative, huge) are rejected or clamped; unit-tested.
- **Calendar invitations are untrusted.** Anyone can put an event in your calendar. Notchy shows its text as plain text and offers "Join" only for known meeting hosts. Lookalikes (`zoom.us.evil.example`, `zoom.us@evil.example`, ports, `file:`, `javascript:`) are rejected; unit-tested.
- **Hidden from screen sharing** (`sharingType = .none`, on by default), so track and meeting titles don't leak into recordings. Some capture tools ignore this.
- **Startup clean-up** stops leftover adapter processes whose parent has exited and whose command line contains Notchy's own adapter path. It can only signal processes owned by you.
- **Test trace.** `NOTCHY_QA_LOG=1` prints state, track titles and click positions to the console of whoever started Notchy. It is off unless set.
- **CI permissions.** Workflows have `contents: write` so CI can publish screenshots, QA reports and releases. Pull requests from forks get a read-only token from GitHub, and nothing uses `pull_request_target`. GitHub's own actions are referenced by major version (`@v4`). Pinning them to commit SHAs, and splitting publishing into its own job, would narrow this further.
- **The app bundle is writable by its owner** when installed by drag-and-drop, so a program running as you could edit the helper script inside it. macOS 13+ App Management protection guards against apps changing other apps; building from source and keeping macOS up to date keeps this protection in place.

## Recommendations (not done here)

1. Sign with a Developer ID and notarize releases (closes SR-7). Until then, run `scripts/setup-signing.sh` so updates are tied to one identity.
2. Pin third-party GitHub Actions to commit SHAs, and move publishing steps into separate jobs that alone get `contents: write`.
3. Re-review when the vendored adapter is updated (`Vendor/mediaremote-adapter/VENDORED.md` records the pinned upstream commit).
