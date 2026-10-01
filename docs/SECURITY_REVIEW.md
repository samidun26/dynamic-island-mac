# Security review

| | |
|---|---|
| Scope | The Notchy app (`Sources/`), the vendored Now Playing helper (`Vendor/mediaremote-adapter`), `build.sh`, signing and entitlements, the CI workflows (`.github/workflows/`), the release and install path, and the QA harness (`QA/`) |
| Version | Branch `claude/youthful-maxwell-tdlzo2` at the commit that adds this file |
| Date | 1 October 2026 |
| Method | Code review of every source file and workflow; a search of every commit in the git history for credentials; attack tests run on macOS by the QA workflow ([QA-33, QA-34](qa/results.md)); unit tests for hostile inputs |

## Summary

**No breach and no high or critical issue was found.** Nothing in the repository or its history is a secret (no tokens, keys or passwords; the workflows use only GitHub's built-in per-run token). The app has no network listener and no account, makes no network requests of its own apart from Spotify album art in fallback mode, and sends nothing anywhere.

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
| `notchy://` URLs | Any app; web pages after the browser asks you | Four commands (start or cancel a timer, open the island, open Settings); numbers validated; no setting can be changed through a URL |
| Launch environment | Whoever starts Notchy | Hardened runtime ignores injected libraries; the helper starts with a minimal environment (SR-1, SR-2) |
| Music and Spotify (fallback mode) | Those apps | Fixed AppleScript texts; only those two apps are ever scripted (SR-3) |
| Spotify artwork URL (fallback mode) | Spotify | HTTPS to Spotify's CDN only, 5 s timeout (SR-4) |
| Media keys | You | The key tap sees only media/system-defined key events, never typing |

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

## Informational (by design)

- **Not sandboxed.** The App Sandbox doesn't allow starting `/usr/bin/perl` for the adapter or watching the pointer everywhere for hover. The hardened runtime is on, with only the Apple Events and Calendars entitlements.
- **Permissions are asked for only when needed.** Calendars is asked for at first launch, because the calendar activity is on by default; decline it, or turn the activity off, and Notchy never reads your calendar. Accessibility is asked for only if you turn on the volume HUD. Automation is asked for only in fallback mode, and only for Music or Spotify. Each can be revoked in System Settings at any time.
- **The media-key tap** is an active tap on system-defined events (media and volume keys) only. It can't see typing.
- **Private API.** The brightness option uses Apple's private DisplayServices framework, loaded from its fixed system path. It is off by default and labelled experimental.
- **The `notchy://` scheme** can be opened by any app, and by web pages after the browser asks. The worst it can do is start or cancel a timer or open the island or Settings. Hostile numbers (NaN, infinity, negative, huge) are rejected or clamped; unit-tested.
- **Calendar invitations are untrusted.** Anyone can put an event in your calendar. Notchy shows its text as plain text and offers "Join" only for known meeting hosts. Lookalikes (`zoom.us.evil.example`, `zoom.us@evil.example`, ports, `file:`, `javascript:`) are rejected; unit-tested.
- **Hidden from screen sharing** (`sharingType = .none`, on by default), so track and meeting titles don't leak into recordings. Some capture tools ignore this.
- **Startup clean-up** stops leftover adapter processes whose parent has exited and whose command line contains Notchy's own adapter path. It can only signal processes owned by you.
- **Test trace.** `NOTCHY_QA_LOG=1` prints state, track titles and click positions to the console of whoever started Notchy. It is off unless set.
- **CI permissions.** Workflows have `contents: write` so CI can publish screenshots, QA reports and releases. Pull requests from forks get a read-only token from GitHub, and nothing uses `pull_request_target`. GitHub's own actions are referenced by major version (`@v4`). Pinning them to commit SHAs, and splitting publishing into its own job, would narrow this further.
- **The app bundle is writable by its owner** when installed by drag-and-drop, so a program running as you could edit the helper script inside it. macOS 13+ App Management protection guards against apps changing other apps; building from source and keeping macOS up to date keeps this protection in place.

## Recommendations (not done here)

1. Sign with a Developer ID and notarize releases (closes SR-7).
2. Pin third-party GitHub Actions to commit SHAs, and move publishing steps into separate jobs that alone get `contents: write`.
3. Re-review when the vendored adapter is updated (`Vendor/mediaremote-adapter/VENDORED.md` records the pinned upstream commit).
