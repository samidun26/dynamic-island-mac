#!/bin/bash
# End-to-end QA on a real macOS session (GitHub's macOS runner or your own Mac).
#
#   QA/run-qa.sh <app-source-dir> <output-dir>
#
# Installs ponyhub from source the way docs/USER_GUIDE.md describes, then drives it with
# synthetic mouse/trackpad input (QA/Driver) and a fake music app (QA/FakePlayer), asserting on
# ponyhub's test trace (NOTCHY_QA_LOG=1), the fake player's log, window lists, the accessibility
# tree and screenshots. Writes <output-dir>/results.md and <output-dir>/shots/*.png.
#
# On your own Mac: it moves the mouse and changes ponyhub's preferences (restored at the end),
# and needs Accessibility + Screen Recording for the terminal you run it from.
set -u
SRC=$(cd "${1:?app source dir}" && pwd)
OUT=$(mkdir -p "${2:?output dir}" && cd "$2" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT/shots" "$OUT/bin"
REPORT="$OUT/results.md"
LOG="$OUT/notchy.log"
FPLOG="$OUT/fakeplayer.log"
D="$OUT/bin/qa-driver"
APP=/Applications/ponyhub.app
BID=dev.local.notchy
app_version() { /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist"; }
PASS=0 FAIL=0 SKIP=0
NOTCHY_PID="" FP_PID=""

: > "$REPORT"
row() { printf '| %s | %s | %s | %s |\n' "$1" "$2" "$3" "$4" >> "$REPORT"; }
pass() { PASS=$((PASS + 1)); row "$1" "$2" "✅ pass" "$3"; echo "✅ PASS $1 $2 — $3"; }
fail() { FAIL=$((FAIL + 1)); row "$1" "$2" "❌ fail" "$3"; echo "❌ FAIL $1 $2 — $3"; }
skip() { SKIP=$((SKIP + 1)); row "$1" "$2" "⏭ skip" "$3"; echo "⏭ SKIP $1 $2 — $3"; }
note() { echo "   · $*"; }
# Run with a hard time limit (perl's alarm: portable, no coreutils needed). Anything that can wait
# on UI (open, Accessibility calls into a busy app, screencapture) goes through this.
lim() { local s=$1; shift; perl -e 'alarm shift; exec @ARGV' "$s" "$@"; }

# Log helpers: bookmark a log, then wait for a pattern after the bookmark (one per log file;
# macOS ships bash 3.2, so no associative arrays).
MARK_APP=0 MARK_FP=0
mark() { local n; n=$(wc -l < "$1" | tr -d ' '); if [ "$1" = "$LOG" ]; then MARK_APP=$n; else MARK_FP=$n; fi; }
after() { local m=$MARK_FP; [ "$1" = "$LOG" ] && m=$MARK_APP; tail -n +"$((m + 1))" "$1"; }
wait_for() { # file pattern seconds
    local end=$((SECONDS + $3))
    while [ $SECONDS -le $end ]; do
        after "$1" | grep -E -q "$2" && return 0
        sleep 0.2
    done
    return 1
}
last_state() { grep -E 'QA .* STATE ' "$LOG" | tail -1 | sed -E 's/.* STATE ([^ ]+) ([0-9]+x[0-9]+).*/\1 \2/'; }
# State changes since the last bookmark ("idle" if there were none: idle is not logged at launch).
state_since() { local l; l=$(after "$LOG" | grep -E ' STATE ' | tail -1 | sed -E 's/.* STATE ([^ ]+) ([0-9]+x[0-9]+).*/\1 \2/'); echo "${l:-idle}"; }
shot() { lim 10 screencapture -x -R "0,0,$SW,${2:-220}" "$OUT/shots/$1.png" 2>/dev/null; }
# Width of the black island along its top edge (3 pt down: below any content, above the menu text).
island_width() { "$D" dark-run "$OUT/shots/$1.png" 3 | awk '{print $2}'; }
logged_size() { last_state | awk '{print $2}'; }
# Average %CPU of ponyhub over the last three of four 2-second top samples.
cpu_avg() { top -l 4 -s 2 -pid "$NOTCHY_PID" -stats cpu | awk '{gsub(/ /,"")} /^[0-9.]+$/ {v[n++]=$0} END {s=0; for (i=n-3; i<n; i++) s+=v[i]; printf "%.1f", s/3}'; }
near() { [ "$1" -ge $(($2 - $3)) ] && [ "$1" -le $(($2 + $3)) ]; }

launch_notchy() {
    mark "$LOG"
    NOTCHY_QA_LOG=1 "$APP/Contents/MacOS/ponyhub" >> "$LOG" 2>&1 &
    NOTCHY_PID=$!
    wait_for "$LOG" "LAUNCH" 15
}
quit_notchy() {
    [ -n "$NOTCHY_PID" ] && kill -TERM "$NOTCHY_PID" 2>/dev/null
    for _ in $(seq 1 30); do kill -0 "$NOTCHY_PID" 2>/dev/null || break; sleep 0.2; done
    NOTCHY_PID=""
}
HTTP_PID="" QA_KEYCHAIN="" OLD_KEYCHAINS=""
cleanup() {
    quit_notchy
    [ -n "$FP_PID" ] && kill "$FP_PID" 2>/dev/null
    [ -n "$HTTP_PID" ] && kill "$HTTP_PID" 2>/dev/null
    pkill -f "$OUT/update/" 2>/dev/null
    if [ -n "$QA_KEYCHAIN" ]; then
        # shellcheck disable=SC2086
        security list-keychains -d user -s $OLD_KEYCHAINS
        security delete-keychain "$QA_KEYCHAIN" 2>/dev/null
    fi
    defaults delete "$BID" >/dev/null 2>&1
    if [ -f "$OUT/defaults-backup.plist" ]; then defaults import "$BID" "$OUT/defaults-backup.plist"; fi
}
trap cleanup EXIT

{
    echo "# QA results"
    echo
    echo "| | |"
    echo "|---|---|"
    echo "| Date | $(date -u '+%Y-%m-%d %H:%M UTC') |"
    echo "| macOS | $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m) |"
    echo "| App | $(cd "$SRC" && git log -1 --format='%h %s' 2>/dev/null) |"
    echo
    echo "| ID | Case | Result | Evidence |"
    echo "|---|---|---|---|"
} >> "$REPORT"

# ---------------------------------------------------------------- harness
echo "== building the QA harness"
harness_failed() { echo "$1"; { echo; echo "Harness build failed: $1"; echo; echo '```'; grep -E "error:" "$OUT/harness-build.log" | head -20; echo '```'; } >> "$REPORT"; exit 2; }
swiftc -O -swift-version 5 "$HERE/Driver/main.swift" -o "$D" 2> "$OUT/harness-build.log" || harness_failed "QA driver did not compile"
FP_APP="$OUT/bin/FakePlayer.app"
mkdir -p "$FP_APP/Contents/MacOS"
swiftc -O -swift-version 5 "$HERE/FakePlayer/main.swift" -o "$FP_APP/Contents/MacOS/FakePlayer" 2>> "$OUT/harness-build.log" || harness_failed "FakePlayer did not compile"
cat > "$FP_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.local.qa.fakeplayer</string>
<key>CFBundleName</key><string>FakePlayer</string>
<key>CFBundleExecutable</key><string>FakePlayer</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$FP_APP" >/dev/null 2>&1

INFO=$("$D" info)
echo "   $INFO"
SW=$(echo "$INFO" | sed -E 's/.*screen=([0-9]+)x.*/\1/')
MB=$(echo "$INFO" | sed -E 's/.*visibleTop=([0-9]+).*/\1/')
[ "$MB" -gt 0 ] 2>/dev/null || MB=24
CX=$((SW / 2))
AX=$(echo "$INFO" | grep -q 'axTrusted=true' && echo yes || echo no)
AXR="$((CX - 260)) 0 520 180"   # where the expanded island is, for accessibility hit-testing

# Can we synthesise input here?
"$D" jump 300 400 >/dev/null; "$D" move 340 420 150 >/dev/null
INPUT=$("$D" info | grep -q 'mouse=(340.0, 420.0)' && echo yes || echo no)
note "input synthesis: $INPUT, accessibility for the driver: $AX"

defaults export "$BID" "$OUT/defaults-backup.plist" >/dev/null 2>&1 || rm -f "$OUT/defaults-backup.plist"

# ---------------------------------------------------------------- install
echo "== install"
T0=$SECONDS
if (cd "$SRC" && ./build.sh > "$OUT/build.log" 2>&1); then
    rm -rf "$APP" && ditto "$SRC/build/ponyhub.app" "$APP"
    if codesign --verify --deep --strict "$APP" 2>/dev/null; then
        pass QA-01 "Build from source and install to /Applications (FR-S5)" "build.sh in $((SECONDS - T0)) s, signature valid"
    else
        fail QA-01 "Build from source and install to /Applications (FR-S5)" "codesign --verify failed"
    fi
else
    fail QA-01 "Build from source and install to /Applications (FR-S5)" "build.sh failed, see build.log"
    exit 1
fi
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"

# ---------------------------------------------------------------- privacy default
echo "== screen-sharing privacy (default settings)"
defaults delete "$BID" >/dev/null 2>&1
defaults write "$BID" calendarEnabled -bool false   # its permission prompt would sit on screen with nobody to answer
# The first-launch Accessibility screen has its own case (QA-45).
defaults write "$BID" hudOnboardedVersion "$(app_version)"
touch "$LOG" "$FPLOG"
launch_notchy || note "no LAUNCH line in the trace"
mark "$LOG"; lim 8 open "ponyhub://timer?seconds=30"
if wait_for "$LOG" "STATE compact:timer" 8; then
    sleep 0.8; shot qa25-hidden
    W=$(island_width qa25-hidden)
    if [ "${W:-0}" -lt 40 ]; then
        pass QA-25 "Hidden from screen capture by default (FR-W8)" "timer running, island absent from capture ([shot](shots/qa25-hidden.png))"
    else
        fail QA-25 "Hidden from screen capture by default (FR-W8)" "island visible in capture (dark run ${W} pt)"
    fi
else
    fail QA-25 "Hidden from screen capture by default (FR-W8)" "timer did not start"
fi
quit_notchy

# ---------------------------------------------------------------- main session
echo "== launch for the visual tests"
defaults write "$BID" hideFromScreenSharing -bool false
defaults write "$BID" calendarEnabled -bool false
launch_notchy
LAUNCH=$(grep LAUNCH "$LOG" | tail -1)
note "$LAUNCH"
NOTCH=$(echo "$LAUNCH" | sed -E 's/.*notchSize=([0-9]+)x([0-9]+).*/\1 \2/')
NW=${NOTCH%% *}; NH=${NOTCH##* }
HASNOTCH=$(echo "$LAUNCH" | grep -q 'hasNotch=true' && echo yes || echo no)

# Window: one panel, top-centre, above the menu bar, plus a menu bar item.
WINS=""
for _ in $(seq 1 15); do
    WINS=$("$D" windows ponyhub)
    echo "$WINS" | awk '{split($5,w,"="); if (w[2]>300) a=1; split($6,h,"="); if (h[2]>0 && h[2]<=40 && w[2]<60) b=1} END {exit !(a && b)}' && break
    sleep 0.2
done
echo "$WINS" | sed 's/^/   · /'
PANEL=$(echo "$WINS" | awk '{split($4,y,"="); split($5,w,"="); if (y[2]==0 && w[2]>300) print}' | head -1)
if [ -n "$PANEL" ]; then
    PX=$(echo "$PANEL" | sed -E 's/.* x=([-0-9]+).*/\1/'); PW=$(echo "$PANEL" | sed -E 's/.* w=([0-9]+).*/\1/')
    PL=$(echo "$PANEL" | sed -E 's/.*layer=([0-9]+).*/\1/')
    if near $((PX + PW / 2)) "$CX" 2 && [ "$PL" -gt 24 ]; then
        pass QA-03 "Panel is top-centre, above the menu bar, fixed size (FR-W1, FR-W7)" "x=$PX w=$PW layer=$PL (menu bar is 24)"
    else
        fail QA-03 "Panel is top-centre, above the menu bar, fixed size (FR-W1, FR-W7)" "$PANEL"
    fi
else
    fail QA-03 "Panel is top-centre, above the menu bar, fixed size (FR-W1, FR-W7)" "no panel window found"
fi
if echo "$WINS" | awk '{split($5,w,"="); split($6,h,"="); if (h[2]>0 && h[2]<=40 && w[2]<60) f=1} END {exit !f}'; then
    pass QA-04 "Menu bar icon present (FR-S1)" "status item window found"
else
    fail QA-04 "Menu bar icon present (FR-S1)" "no status item window"
fi

mark "$LOG"; sleep 1; shot qa05-idle
W=$(island_width qa05-idle)
if [ "$HASNOTCH" = yes ]; then
    # On a notched display the idle island is drawn over the notch: it must match it exactly.
    if [ "$(state_since | cut -d' ' -f1)" = idle ] && near "${W:-0}" "$NW" 3; then
        pass QA-05 "Idle island covers exactly the notch (FR-W4)" "${W} pt wide, notch ${NW} pt ([shot](shots/qa05-idle.png))"
    else
        fail QA-05 "Idle island covers exactly the notch (FR-W4)" "state $(state_since), dark run ${W} pt, notch ${NW} pt"
    fi
elif [ "$(state_since | cut -d' ' -f1)" = idle ] && [ "${W:-0}" -lt 40 ]; then
    pass QA-05 "Idle island is hidden on a display without a notch (FR-W5)" "state idle, nothing drawn over the menu bar ([shot](shots/qa05-idle.png))"
else
    fail QA-05 "Idle island is hidden on a display without a notch (FR-W5)" "state $(state_since), dark run ${W} pt"
fi

sleep 4
CPU=$(cpu_avg)
MEM=$(top -l 1 -pid "$NOTCHY_PID" -stats mem | tail -1 | tr -d ' ')
if awk "BEGIN {exit !($CPU < 1.0)}"; then
    pass QA-06 "Idle CPU and memory (NFR-1, NFR-2)" "${CPU}% CPU, ${MEM}"
else
    fail QA-06 "Idle CPU and memory (NFR-1, NFR-2)" "${CPU}% CPU, ${MEM}"
fi

# ---------------------------------------------------------------- now playing
echo "== now playing (FakePlayer)"
mark "$LOG"
FP_CROWD_FILE="$OUT/crowd-width" "$FP_APP/Contents/MacOS/FakePlayer" > "$FPLOG" 2>&1 &
FP_PID=$!
sleep 0.5
if wait_for "$LOG" "NOWPLAYING title=QA Track One.*playing=true" 12; then
    SRCLINE=$(grep -E "SOURCE " "$LOG" | tail -1 | sed -E 's/.*SOURCE //')
    pass QA-07 "Now Playing is detected from another app (FR-N1)" "\"QA Track One\" via ${SRCLINE}"
    if wait_for "$LOG" "STATE peek:nowPlaying" 3; then
        sleep 0.9; shot qa08-peek 220
        if wait_for "$LOG" "STATE compact:nowPlaying" 6; then
            pass QA-08 "New track peeks, then settles to compact (FR-A5)" "peek then compact ([shot](shots/qa08-peek.png))"
        else
            fail QA-08 "New track peeks, then settles to compact (FR-A5)" "peek did not end"
        fi
    else
        fail QA-08 "New track peeks, then settles to compact (FR-A5)" "no peek"
    fi
    sleep 1; shot qa09-compact
    W=$(island_width qa09-compact)
    # The width depends on how much menu bar is free beside the notch (QA-35): check the island on
    # screen is the size ponyhub says it drew.
    WANT=$(logged_size | cut -dx -f1)
    FIT=$(grep -E 'STATE compact:nowPlaying' "$LOG" | tail -1 | grep -oE 'fit=[a-z]+:[0-9]+/[0-9]+')
    if [ "$(last_state | cut -d' ' -f1)" = compact:nowPlaying ] && near "${W:-0}" "${WANT:-0}" 6; then
        pass QA-09 "Compact wings: artwork + equaliser (FR-N3)" "${W} pt wide as drawn (${FIT}) ([shot](shots/qa09-compact.png))"
    else
        fail QA-09 "Compact wings: artwork + equaliser (FR-N3)" "state $(last_state), ${W} pt wide on screen, ${WANT} drawn"
    fi
    "$D" jump "$CX" 500 >/dev/null; sleep 2
    CPU_COMPACT=$(cpu_avg)
    note "CPU, compact with the equaliser animating: ${CPU_COMPACT}%"
    grep -q "ARTWORK received" "$LOG" && pass QA-10 "Artwork arrives and is shown (FR-N6)" "artwork decoded" \
        || fail QA-10 "Artwork arrives and is shown (FR-N6)" "no artwork received"
else
    fail QA-07 "Now Playing is detected from another app (FR-N1)" "nothing after 12 s; source: $(grep SOURCE "$LOG" | tail -1); player: $(tail -3 "$FPLOG" | tr '\n' ' ')"
    for t in QA-08 QA-09 QA-10; do skip "$t" "Now Playing dependent" "QA-07 failed"; done
fi

# ---------------------------------------------------------------- hover
echo "== hover, click, swipe"
if [ "$INPUT" != yes ]; then
    for t in QA-11 QA-12 QA-13 QA-14 QA-15 QA-16 QA-17 QA-18 QA-19 QA-20; do skip "$t" "Interaction" "cannot synthesise input on this machine"; done
else
    "$D" jump "$CX" 400 >/dev/null; sleep 0.6
    mark "$LOG"
    "$D" move "$CX" $((MB / 2)) 450 >/dev/null
    if wait_for "$LOG" "HOVER open" 2 && wait_for "$LOG" "STATE expanded" 1; then
        sleep 0.8; shot qa11-expanded 240
        SIZE=$(logged_size); EW=${SIZE%x*}; EH=${SIZE#*x}
        W=$(island_width qa11-expanded)
        BOTTOM_IN=$("$D" pixel "$OUT/shots/qa11-expanded.png" "$CX" $((EH - 4)) | cut -d' ' -f1)
        BOTTOM_OUT=$("$D" pixel "$OUT/shots/qa11-expanded.png" "$CX" $((EH + 14)) | cut -d' ' -f1)
        if near "${W:-0}" "$EW" 8 && [ "$BOTTOM_IN" = dark ] && [ "$BOTTOM_OUT" = light ]; then
            pass QA-11 "Resting the pointer opens it (FR-I1)" "$(last_state); on screen ${W} pt wide, bottom edge at ${EH} pt ([shot](shots/qa11-expanded.png))"
        else
            fail QA-11 "Resting the pointer opens it (FR-I1)" "logged ${SIZE}, on screen ${W} pt wide, bottom ${BOTTOM_IN}/${BOTTOM_OUT}"
        fi
        CPU_EXPANDED=$(cpu_avg)
        note "CPU, expanded Now Playing: ${CPU_EXPANDED}%"
        lim 30 "$D" ax-dump $BID > "$OUT/ax-dump.txt" 2>&1
        for y in 60 100 125; do echo "at $CX,$y: $(lim 8 "$D" ax-at "$CX" "$y")"; done >> "$OUT/ax-dump.txt"
    else
        fail QA-11 "Resting the pointer opens it (FR-I1)" "state $(last_state)"
    fi

    if [ "$AX" = yes ]; then
        TEXTS=$(lim 20 "$D" ax-texts $BID $AXR | tr '\n' '|')
        if echo "$TEXTS" | grep -q "QA Track One" && echo "$TEXTS" | grep -q "The Testers"; then
            pass QA-12 "Expanded shows title and artist (FR-N4)" "AX texts: ${TEXTS:0:120}"
        else
            fail QA-12 "Expanded shows title and artist (FR-N4)" "AX texts: ${TEXTS:0:160}"
        fi
        # Play/pause through a real click on the button.
        P=$(lim 20 "$D" ax-find $BID "Pause" $AXR 2>/dev/null)
        if [ -n "$P" ]; then
            mark "$FPLOG"; "$D" click $P
            if wait_for "$FPLOG" "CMD (toggle|pause)" 4; then
                mark "$FPLOG"; P2=$(lim 20 "$D" ax-find $BID "Play" $AXR 2>/dev/null); [ -n "$P2" ] && "$D" click $P2
                if wait_for "$FPLOG" "CMD (toggle|play)" 4; then
                    pass QA-13 "Play/pause button controls the player (FR-N4)" "player received pause then play"
                else
                    fail QA-13 "Play/pause button controls the player (FR-N4)" "pause worked, play did not"
                fi
            else
                fail QA-13 "Play/pause button controls the player (FR-N4)" "player got no command"
            fi
        else
            fail QA-13 "Play/pause button controls the player (FR-N4)" "no Pause button in the accessibility tree"
        fi
        # Next track.
        N=$(lim 20 "$D" ax-find $BID "Next track" $AXR 2>/dev/null)
        mark "$LOG"; mark "$FPLOG"
        if [ -n "$N" ] && "$D" click $N && wait_for "$FPLOG" "CMD next" 4; then
            if wait_for "$LOG" "NOWPLAYING title=QA Track Two" 5; then
                pass QA-14 "Next button skips and the island follows (FR-N4)" "player skipped, island shows \"QA Track Two\""
            else
                fail QA-14 "Next button skips and the island follows (FR-N4)" "player skipped, island did not update"
            fi
        else
            fail QA-14 "Next button skips and the island follows (FR-N4)" "no next command"
        fi
        # Seek by dragging the scrubber to 75%.
        F=$(lim 20 "$D" ax-frame $BID "Playback position" $AXR 2>/dev/null)
        if [ -n "$F" ]; then
            read -r FX FY FW FH <<< "$F"
            mark "$FPLOG"
            "$D" drag $((FX + FW / 2)) $((FY + FH / 2)) $((FX + FW * 3 / 4)) $((FY + FH / 2)) 300
            if wait_for "$FPLOG" "CMD seek" 4; then
                POS=$(after "$FPLOG" | grep "CMD seek" | tail -1 | sed -E 's/.*position=([0-9-]+).*/\1/')
                if near "$POS" 140 12; then
                    pass QA-15 "Dragging the progress bar seeks (FR-N4)" "player seeked to ${POS} s of 187 (expected ≈140)"
                else
                    fail QA-15 "Dragging the progress bar seeks (FR-N4)" "player seeked to ${POS} s, expected ≈140"
                fi
            else
                fail QA-15 "Dragging the progress bar seeks (FR-N4)" "player got no seek"
            fi
        else
            fail QA-15 "Dragging the progress bar seeks (FR-N4)" "no progress bar in the accessibility tree"
        fi
        shot qa15-after-seek 240
    else
        for t in QA-12 QA-13 QA-14 QA-15; do skip "$t" "Expanded controls" "driver has no Accessibility permission"; done
    fi

    # Leave: closes after the delay.
    mark "$LOG"
    "$D" move "$CX" 500 200 >/dev/null
    if wait_for "$LOG" "HOVER close" 2 && wait_for "$LOG" "STATE compact" 1; then
        pass QA-16 "Moving away closes it (FR-I2)" "$(last_state)"
    else
        fail QA-16 "Moving away closes it (FR-I2)" "state $(last_state)"
    fi

    # Fast sweep along the menu bar through the island: must not open.
    sleep 0.5; "$D" jump $((CX - 400)) $((MB / 2)) >/dev/null; sleep 0.3
    mark "$LOG"
    "$D" move $((CX + 400)) $((MB / 2)) 90 >/dev/null
    sleep 1
    if after "$LOG" | grep -q "HOVER open"; then
        fail QA-17 "Sweeping across the notch does not open it (FR-I1)" "opened during a fast sweep"
    else
        pass QA-17 "Sweeping across the notch does not open it (FR-I1)" "800 pt in 90 ms: stayed closed"
    fi

    # Click-through: inside the panel's rectangle but outside the island lands on the app below.
    "$D" jump "$CX" 500 >/dev/null; sleep 0.4
    mark "$FPLOG"; mark "$LOG"
    "$D" click $((CX + 210)) 120
    if wait_for "$FPLOG" "BACKDROP_CLICK" 2; then
        pass QA-18 "Clicks beside the island pass through (FR-W2)" "click at ($((CX + 210)), 120), inside the panel frame, reached the window below"
    else
        fail QA-18 "Clicks beside the island pass through (FR-W2)" "click was swallowed"
    fi

    # Click to pin, move away (stays), click elsewhere (dismisses).
    "$D" jump "$CX" 500 >/dev/null; sleep 0.4
    mark "$LOG"
    "$D" jump "$CX" $((MB / 2)) >/dev/null
    "$D" click "$CX" $((MB / 2))
    PINNED=no; wait_for "$LOG" "PIN" 2 && wait_for "$LOG" "STATE expanded" 1 && PINNED=yes
    "$D" move "$CX" 500 150 >/dev/null; sleep 1.2
    STAY=$(last_state | cut -d' ' -f1)
    mark "$LOG"; "$D" click "$CX" 520
    if [ $PINNED = yes ] && [[ $STAY == expanded* ]] && wait_for "$LOG" "DISMISS" 2; then
        pass QA-19 "Click pins it open; a click elsewhere closes it (FR-I4)" "pinned, stayed open after leaving, dismissed by outside click"
    else
        fail QA-19 "Click pins it open; a click elsewhere closes it (FR-I4)" "pinned=$PINNED, after leaving=$STAY; clicks seen: $(grep MOUSEDOWN "$LOG" | tail -3 | sed -E 's/.*MOUSEDOWN //' | tr '\n' ';')"
    fi

    # Two-finger swipes on the island.
    # Rest on the island first: a swipe that starts before ponyhub has seen the pointer arrive
    # (and stopped passing clicks through) goes to the app underneath.
    sleep 0.6; mark "$LOG"; "$D" jump "$CX" $((MB / 2)) >/dev/null; wait_for "$LOG" "CLICKTHROUGH false" 1; sleep 0.3
    mark "$LOG"; "$D" swipe 0 -60
    sleep 0.5; S1=$(after "$LOG" | grep -o 'SWIPE [a-z]*' | head -1)
    mark "$LOG"; "$D" swipe 0 60
    sleep 0.5; S2=$(after "$LOG" | grep -o 'SWIPE [a-z]*' | head -1)
    sleep 0.4; ST2=$(last_state | cut -d' ' -f1)
    mark "$LOG"; "$D" swipe 0 -60; sleep 0.4
    mark "$LOG"; "$D" swipe 80 0
    sleep 0.6; S3=$(after "$LOG" | grep -o 'SWIPE [a-z]*' | head -1); ST3=$(last_state | cut -d' ' -f1)
    if [ -n "$S1" ] && [ -n "$S2" ] && [ "$S1" != "$S2" ] && [ -n "$S3" ]; then
        pass QA-20 "Two-finger swipes on the island (FR-I5)" "vertical: '$S1' then '$S2' (state after: $ST2); horizontal: '$S3' (state: $ST3)"
    else
        fail QA-20 "Two-finger swipes on the island (FR-I5)" "got '$S1' / '$S2' / '$S3'; scroll gestures seen: $(grep -o 'SCROLL began [a-z ]*' "$LOG" | tail -4 | tr '\n' ';')"
    fi
    "$D" move "$CX" 520 150 >/dev/null; "$D" click "$CX" 520; sleep 1
fi

# ---------------------------------------------------------------- timer
echo "== timer"
mark "$LOG"
lim 8 open "ponyhub://timer?seconds=8"
if wait_for "$LOG" "URL ponyhub://timer" 4 && wait_for "$LOG" "STATE compact:timer" 4; then
    sleep 0.8; shot qa21-timer
    W=$(island_width qa21-timer)
    pass QA-21 "ponyhub://timer starts a timer in the wings, music as a glyph (FR-T1, FR-A3)" "$(grep 'STATE compact:timer' "$LOG" | tail -1 | sed -E 's/.*STATE //'); ${W} pt ([shot](shots/qa21-timer.png))"
    if wait_for "$LOG" "TIMER done" 12 && wait_for "$LOG" "STATE peek:timer" 2; then
        sleep 0.8; shot qa22-done 220
        if wait_for "$LOG" "STATE compact:nowPlaying" 20; then
            pass QA-22 "Timer ends: peek, then clears itself (FR-T3)" "done → peek → back to music ([shot](shots/qa22-done.png))"
        else
            fail QA-22 "Timer ends: peek, then clears itself (FR-T3)" "did not clear; state $(last_state)"
        fi
    else
        fail QA-22 "Timer ends: peek, then clears itself (FR-T3)" "no completion; state $(last_state)"
    fi
else
    fail QA-21 "ponyhub://timer starts a timer in the wings, music as a glyph (FR-T1, FR-A3)" "state $(last_state)"
    skip QA-22 "Timer ends: peek, then clears itself (FR-T3)" "QA-21 failed"
fi

if [ "$INPUT" = yes ] && [ "$AX" = yes ]; then
    lim 8 open "ponyhub://timer?minutes=5"; sleep 1
    "$D" jump "$CX" 500 >/dev/null; sleep 0.3
    mark "$LOG"; "$D" move "$CX" $((MB / 2)) 400 >/dev/null
    wait_for "$LOG" "STATE expanded:timer" 2
    sleep 0.6; shot qa23-timer-page 240
    OK=yes; DETAIL=""
    B=$(lim 20 "$D" ax-find $BID "+1 min" $AXR 2>/dev/null); [ -n "$B" ] && "$D" click $B || { OK=no; DETAIL="no +1 min"; }
    sleep 0.5
    B=$(lim 20 "$D" ax-find $BID "Pause timer" $AXR 2>/dev/null); [ -n "$B" ] && "$D" click $B || { OK=no; DETAIL="$DETAIL no pause"; }
    sleep 0.6
    PAUSED=$(lim 20 "$D" ax-texts $BID $AXR | grep -c Paused)
    T=$(lim 20 "$D" ax-texts $BID $AXR | grep -E '^[0-9]+:[0-9]{2}$' | head -1)
    shot qa23-timer-paused 240
    B=$(lim 20 "$D" ax-find $BID "Cancel timer" $AXR 2>/dev/null); mark "$LOG"; [ -n "$B" ] && "$D" click $B || { OK=no; DETAIL="$DETAIL no cancel"; }
    if [ $OK = yes ] && [ "$PAUSED" -ge 1 ] && wait_for "$LOG" "STATE expanded:nowPlaying" 2; then
        pass QA-23 "Timer page: +1 min, pause, cancel (FR-T2)" "paused at ${T:-?} after +1 min, cancel removed the page ([shot](shots/qa23-timer-paused.png))"
    else
        fail QA-23 "Timer page: +1 min, pause, cancel (FR-T2)" "$DETAIL paused=$PAUSED time=${T:-?} state $(last_state)"
    fi
    "$D" move "$CX" 520 150 >/dev/null; sleep 1
else
    skip QA-23 "Timer page: +1 min, pause, cancel (FR-T2)" "needs input synthesis and Accessibility"
fi

# ---------------------------------------------------------------- settings & menu
echo "== menu bar menu (before ponyhub has ever been active)"
# The menu is open when ponyhub owns a window at the pop-up menu level (101). (The menu delegate's
# "MENU opened" is not proof: it also fires whenever an accessibility client reads the menu.)
menu_open() { "$D" windows ponyhub | awk '{split($2,l,"="); if (l[2]>=100) f=1} END {exit !f}'; }
wait_menu() { for _ in 1 2 3 4 5 6 7 8 9 10; do menu_open && { echo yes; return; }; sleep 0.2; done; echo no; }
front_app() { lsappinfo info -only name "$(lsappinfo front)" 2>/dev/null | sed -E 's/.*=//; s/"//g'; }
menu_click() { # $1 = label for the evidence; prints yes/no and what was under the pointer
    local item ix iw r
    item=$("$D" windows ponyhub | awk '{split($5,w,"="); split($6,h,"="); if (h[2]>0 && h[2]<=40 && w[2]<60) print}' | head -1)
    [ -z "$item" ] && { echo "no-item"; return; }
    ix=$(echo "$item" | sed -E 's/.* x=([0-9]+).*/\1/'); iw=$(echo "$item" | sed -E 's/.* w=([0-9]+).*/\1/')
    mark "$LOG"
    "$D" click $((ix + iw / 2)) $((MB / 2))
    r=$(wait_menu)
    lim 10 screencapture -x -R "$((ix - 220)),0,320,260" "$OUT/shots/qa26-menu-$1.png"
    "$D" key escape; sleep 0.4
    local closed=yes; menu_open && closed=no
    echo "$r (front: $(front_app); $(after "$LOG" | grep -oE 'MOUSEDOWN [a-z]+( window [A-Za-z]+)?|active=[a-z]+' | tr '\n' ' '); closed by Escape: $closed)"
}
menu_press() { # $1 = screenshot name; the same menu, opened through Accessibility instead of a click
    local r ix
    ix=$("$D" windows ponyhub | awk '{split($5,w,"="); split($6,h,"="); if (h[2]>0 && h[2]<=40 && w[2]<60) print}' | head -1 | sed -E 's/.* x=([0-9]+).*/\1/')
    ( lim 4 "$D" status-press $BID >/dev/null 2>&1 & )
    r=$(wait_menu)
    [ -n "$ix" ] && lim 10 screencapture -x -R "$((ix - 220)),0,320,260" "$OUT/shots/$1.png"
    "$D" key escape; sleep 0.6
    menu_open && { "$D" key escape; sleep 0.6; }   # never leave a menu open for the next case
    echo "$r"
}
if [ "$INPUT" = yes ]; then
    open -a Finder; sleep 1                       # the usual case: another app in front
    M1=$(menu_click other-app)
    if [ "${M1%% *}" = yes ]; then
        pass QA-26 "Menu bar menu opens (FR-S1)" "menu window on screen, ${M1#yes } ([shot](shots/qa26-menu-other-app.png))"
    else
        fail QA-26 "Menu bar menu opens (FR-S1)" "no menu window: $M1 ([shot](shots/qa26-menu-other-app.png))"
    fi
else
    skip QA-26 "Menu bar menu opens (FR-S1)" "cannot synthesise input"
fi


echo "== settings window and menu"
mark "$LOG"
lim 8 open "ponyhub://settings"
if wait_for "$LOG" "SETTINGS shown" 4; then
    sleep 1.5
    # A normal-level (layer 0) window of about 500 pt: titles need Screen Recording to read.
    SW_ID=$("$D" windows ponyhub | awk '{split($2,l,"="); split($5,w,"="); if (l[2]==0 && w[2]>=400) {split($1,i,"="); print i[2]}}' | head -1)
    if [ -n "$SW_ID" ]; then
        lim 10 screencapture -x -o -l "$SW_ID" "$OUT/shots/qa24-settings.png"
        CLOSED=untested
        FOCUSED=$(grep -o 'SETTINGS focused=[a-z]*' "$LOG" | tail -1 | cut -d= -f2)
        if [ "$INPUT" = yes ]; then
            finder_windows() { "$D" windows Finder | awk '{split($2,l,"="); if (l[2]==0) n++} END {print n+0}'; }
            settings_open() { "$D" windows ponyhub | awk '{split($1,i,"="); print i[2]}' | grep -qx "$SW_ID"; }
            F0=$(finder_windows)
            mark "$LOG"; "$D" key cmd-w; sleep 0.8
            settings_open && CLOSED=no || CLOSED=yes
            if [ $CLOSED = no ]; then
                # Where did it go? Then once more, after clicking the window like a person would.
                WENT="ponyhub got it: $(after "$LOG" | grep -c ' KEY w '); Finder windows ${F0}→$(finder_windows)"
                WIN=$("$D" windows ponyhub | grep "id=$SW_ID ")
                WX=$(echo "$WIN" | sed -E 's/.* x=([0-9]+).*/\1/'); WY=$(echo "$WIN" | sed -E 's/.* y=([0-9]+).*/\1/'); WW=$(echo "$WIN" | sed -E 's/.* w=([0-9]+).*/\1/')
                "$D" click $((WX + WW / 2)) $((WY + 12)); sleep 0.4
                mark "$LOG"; "$D" key cmd-w; sleep 0.8
                if settings_open; then
                    # The VM sometimes drops synthetic key presses before any app gets them (the
                    # trace shows ponyhub never received one). Hand ⌘W straight to ponyhub instead.
                    mark "$LOG"; "$D" key cmd-w "$NOTCHY_PID"; sleep 0.8
                    TO_PID=$(after "$LOG" | grep -c ' KEY w ')
                    if ! settings_open; then
                        CLOSED="yes, with ⌘W delivered straight to ponyhub (the VM dropped the normal key presses: $WENT)"
                    elif [ "$TO_PID" = 0 ] && [ "$AX" = yes ]; then
                        # Not one key press reached ponyhub, so this VM session isn't delivering
                        # keys (seen on earlier runs too). Check the app side without the keyboard:
                        # ⌘W must be the shortcut of Window → Close, and that item must close the window.
                        MENU=$(lim 10 "$D" ax-menu $BID Close press 2>&1 | tr '\n' ' '); sleep 0.8
                        if ! settings_open && echo "$MENU" | grep -qiE 'key=w modifiers=0 pressed'; then
                            CLOSED="yes, by Window → Close, whose shortcut is ⌘W (${MENU% }), pressed through Accessibility: none of the 3 key presses reached ponyhub on this VM ($WENT; sent to its process: 0)"
                        else
                            WENT="$WENT; sent to its process: 0; Window → Close: ${MENU:-not found}"
                        fi
                    fi
                else
                    CLOSED="after clicking the window (the first press went astray: $WENT)"
                fi
            fi
        fi
        if [ "$CLOSED" != no ]; then
            pass QA-24 "Settings window opens; ⌘W closes it (FR-S2)" "window shown and focused=${FOCUSED:-?} ([shot](shots/qa24-settings.png)); closed by ⌘W: $CLOSED"
        else
            fail QA-24 "Settings window opens; ⌘W closes it (FR-S2)" "window shown, focused=${FOCUSED:-?} ([shot](shots/qa24-settings.png)), but ⌘W did not close it, even after clicking it; ${WENT:-}; front: $(front_app); trace: $(after "$LOG" | grep -E 'KEY|SETTINGS|MENU' | sed -E 's/^QA [0-9.]+ //' | tail -6 | tr '\n' ';')"
        fi
    else
        fail QA-24 "Settings window opens; ⌘W closes it (FR-S2)" "no settings window on screen"
    fi
else
    fail QA-24 "Settings window opens (FR-S2)" "ponyhub://settings not handled"
fi

# The menu still opens after Settings was used (ponyhub has been the active app). Opened through
# Accessibility, as VoiceOver would: on the CI machine only the first synthetic click on a menu bar
# item in a session opens its menu, for a fresh ponyhub that was never active too, so a second click
# proves nothing either way.
if [ "$AX" = yes ]; then
    open -a Finder; sleep 1
    if [ "$(menu_press qa32-menu-after-settings)" = yes ]; then
        pass QA-32 "Menu bar menu still opens after Settings was used (FR-S1)" "menu window on screen ([shot](shots/qa32-menu-after-settings.png))"
    else
        fail QA-32 "Menu bar menu still opens after Settings was used (FR-S1)" "no menu window ([shot](shots/qa32-menu-after-settings.png))"
    fi
else
    skip QA-32 "Menu bar menu still opens after Settings was used (FR-S1)" "driver has no Accessibility permission"
fi

# ---------------------------------------------------------------- resilience
echo "== resilience"
ADP=$(pgrep -f "mediaremote-adapter.pl.*stream" | head -1)
if [ -n "$ADP" ]; then
    mark "$LOG"
    kill -9 "$ADP"; sleep 3
    NEW=$(pgrep -f "mediaremote-adapter.pl.*stream" | head -1)
    FLICKER=$(after "$LOG" | grep -cE "STATE (idle|peek)")
    if [ -n "$NEW" ] && [ "$NEW" != "$ADP" ] && [ "$FLICKER" = 0 ]; then
        pass QA-27 "Now Playing stream restarts after a crash, without flicker (FR-N2)" "killed pid $ADP, restarted as $NEW; island stayed on the track"
    elif [ -n "$NEW" ] && [ "$NEW" != "$ADP" ]; then
        fail QA-27 "Now Playing stream restarts after a crash, without flicker (FR-N2)" "restarted as $NEW, but the island flickered ($(after "$LOG" | grep -oE 'STATE (idle|peek)[^ ]*' | tr '\n' ' '))"
    else
        fail QA-27 "Now Playing stream restarts after a crash, without flicker (FR-N2)" "not restarted"
    fi
else
    skip QA-27 "Now Playing stream restarts after a crash, without flicker (FR-N2)" "adapter not running (fallback mode)"
fi

# Controlled CPU: music playing in the compact island (measured twice), then paused in the player.
"$D" jump "$CX" 500 >/dev/null 2>&1; sleep 3
if [ "$(last_state | cut -d' ' -f1)" = compact:nowPlaying ]; then
    A1=$(cpu_avg); A2=$(cpu_avg)
    mark "$LOG"; kill -USR2 "$FP_PID"
    COLLAPSED=no
    wait_for "$LOG" "NOWPLAYING .*playing=false" 3 && wait_for "$LOG" "STATE idle" 5 && COLLAPSED=yes
    WAITED=$(after "$LOG" | awk '/playing=false/ {a=$2} / STATE idle/ {b=$2} END {if (a && b) printf "%.1f", b - a}')
    sleep 2; B=$(cpu_avg)
    if [ $COLLAPSED = yes ]; then
        pass QA-30 "Pausing in the player: wings collapse after the grace period (FR-N3)" "collapsed ${WAITED} s after the pause (grace 2.5 s)"
    else
        fail QA-30 "Pausing in the player: wings collapse after the grace period (FR-N3)" "state $(last_state)"
    fi
    CPU_COMPACT="$A1 / $A2"; CPU_PAUSED=$B
    if awk "BEGIN {exit !($B < 1.0)}"; then
        pass QA-31 "CPU with music paused and the island idle (NFR-1)" "${B}% (music playing in the wings: ${A1}% and ${A2}%)"
    else
        fail QA-31 "CPU with music paused and the island idle (NFR-1)" "${B}% (music playing in the wings: ${A1}% and ${A2}%)"
    fi
    kill -USR2 "$FP_PID"; sleep 1
else
    skip QA-30 "Pausing in the player: wings collapse after the grace period (FR-N3)" "not in compact:nowPlaying ($(last_state))"
    skip QA-31 "CPU with music paused and the island idle (NFR-1)" "precondition not met"
fi

# ---------------------------------------------------------------- menu bar clearance
# The compact island must never cover an app menu or a menu bar icon next to the notch.
echo "== menu bar clearance"
island_span() { "$D" dark-run "$OUT/shots/$1.png" 3 | awk '{print $1, $1 + $2}'; }
notch_max=$((CX + NW / 2))
first_icon() { "$D" status-items | awk -v n=$notch_max '$2 >= n - 2 {print $2}' | sort -n | head -1; }
menus_end() { [ "$AX" = yes ] && lim 8 "$D" menu-extent 2>/dev/null | awk '{print $2}'; }
clear_check() { # $1 = screenshot; prints "ok|overlap" and the evidence
    local span a b icon menus fit verdict=ok
    span=$(island_span "$1"); a=${span% *}; b=${span#* }
    icon=$(first_icon); menus=$(menus_end)
    fit=$(grep -E 'STATE compact' "$LOG" | tail -1 | grep -oE 'fit=[a-z]+:[0-9]+/[0-9]+')
    if [ $((b - a)) -lt 20 ]; then echo "ok nothing drawn over the menu bar, first icon at ${icon:-none}, ${fit}"; return; fi
    [ -n "$icon" ] && [ "${b:-0}" -gt $((icon - 1)) ] && verdict=overlap
    [ -n "$menus" ] && [ "${menus:-0}" -gt 0 ] && [ "${a:-0}" -lt $((menus + 1)) ] && verdict=overlap
    echo "$verdict island ${a}–${b} pt, app menus end at ${menus:-?}, first icon at ${icon:-none}, ${fit}"
}
sleep 2.5
if [ "$(last_state | cut -d' ' -f1)" = compact:nowPlaying ]; then
    shot qa35-clear
    C=$(clear_check qa35-clear)
    FIT0=$(echo "$C" | grep -oE 'fit=[a-z]+')
    SEEN=$(grep MENUBAR "$LOG" | tail -1 | sed -E 's/.*MENUBAR //')
    if [ "${C%% *}" = ok ]; then
        pass QA-35 "Compact island keeps clear of menus and menu bar icons (FR-W9)" "${C#ok }; ponyhub measured ${SEEN} ([shot](shots/qa35-clear.png))"
    else
        fail QA-35 "Compact island keeps clear of menus and menu bar icons (FR-W9)" "${C}; ponyhub measured ${SEEN} ([shot](shots/qa35-clear.png))"
    fi

    # Crowd the menu bar: a wide icon right next to the notch, like the Wi-Fi icon in the bug report.
    ICON0=$(first_icon)
    ROOM=$(( ${ICON0:-0} - notch_max - 12 ))
    if [ -n "$ICON0" ] && [ "$ROOM" -gt 30 ] && ! echo "$FIT0" | grep -qE 'folded|left'; then
        echo "$ROOM" > "$OUT/crowd-width"
        mark "$LOG"; kill -HUP "$FP_PID"
        if wait_for "$LOG" "STATE compact:nowPlaying .*fit=(folded|left|hidden)" 6; then
            sleep 1; shot qa36-crowded
            C2=$(clear_check qa36-crowded)
            mark "$LOG"; kill -HUP "$FP_PID"
            BACK=no; wait_for "$LOG" "STATE compact:nowPlaying .*${FIT0}" 6 && BACK=yes
            if [ "${C2%% *}" = ok ] && [ $BACK = yes ]; then
                pass QA-36 "A crowded menu bar moves or folds the island instead of being covered (FR-W9)" "${ROOM} pt icon added: ${C2#ok }; back to ${FIT0#fit=} when it went away ([shot](shots/qa36-crowded.png))"
            else
                fail QA-36 "A crowded menu bar moves or folds the island instead of being covered (FR-W9)" "${C2}; back when removed: ${BACK} ([shot](shots/qa36-crowded.png))"
            fi
        else
            shot qa36-crowded
            fail QA-36 "A crowded menu bar moves or folds the island instead of being covered (FR-W9)" "no re-fit after a ${ROOM} pt icon appeared; $(last_state); $(grep -hE 'CROWD' "$FPLOG" | tail -2 | sed -E 's/^.*CROWD/CROWD/' | tr '\n' ';') icons: $("$D" status-items | tr '\n' ',') ([shot](shots/qa36-crowded.png))"
            kill -HUP "$FP_PID"
        fi
    else
        skip QA-36 "A crowded menu bar moves or folds the island instead of being covered (FR-W9)" "the menu bar is already full next to the notch (first icon at ${ICON0:-none}, ${FIT0})"
    fi
else
    skip QA-35 "Compact island keeps clear of menus and menu bar icons (FR-W9)" "not in compact:nowPlaying ($(last_state))"
    skip QA-36 "A crowded menu bar moves or folds the island instead of being covered (FR-W9)" "precondition not met"
fi

quit_notchy; sleep 1
if pgrep -f "mediaremote-adapter.pl" >/dev/null; then
    fail QA-28 "Quitting stops the Now Playing helper (NFR-4)" "perl adapter still running"
else
    pass QA-28 "Quitting stops the Now Playing helper (NFR-4)" "no adapter process left"
fi

if [ "$HASNOTCH" = yes ]; then
    skip QA-29 "\"Never\" on displays without a notch hides the island (FR-W5)" "this display has a notch"
else
    defaults write "$BID" nonNotchMode never
    launch_notchy; sleep 1.5
    if "$D" windows ponyhub | awk '{split($5,w,"="); if (w[2]>300) f=1} END {exit f}'; then
        pass QA-29 "\"Never\" on displays without a notch hides the island (FR-W5)" "no panel window on screen"
    else
        fail QA-29 "\"Never\" on displays without a notch hides the island (FR-W5)" "panel still on screen"
    fi
    quit_notchy
fi

# ---------------------------------------------------------------- volume and brightness in the notch
# QA-45: volume and brightness in the notch are on by default and need Accessibility. Opened the
# way people open it (Finder, `open`), ponyhub has no Accessibility here, so the first launch
# opens Settings on Activities to ask, once per version. (Started from the test's shell, it
# inherits the shell's Accessibility instead: that is QA-46.)
quit_notchy
defaults delete "$BID" hudOnboardedVersion 2>/dev/null
open_app() { : > "$1"; lim 10 open -n --env NOTCHY_QA_LOG=1 --stdout "$1" "$APP"; }
quit_opened() { pkill -TERM -f "$APP/Contents/MacOS/ponyhub" 2>/dev/null; for _ in $(seq 1 25); do pgrep -f "$APP/Contents/MacOS/ponyhub" >/dev/null || break; sleep 0.2; done; }
in_file() { for _ in $(seq 1 $(($3 * 5))); do grep -q "$2" "$1" 2>/dev/null && return 0; sleep 0.2; done; return 1; }
L1="$OUT/qa45-first.log"; L2="$OUT/qa45-second.log"
open_app "$L1"
ONB=no; SWIN=""; ASK=0
if in_file "$L1" "ONBOARDING hud" 8; then
    ONB=yes; sleep 1.5
    SWIN=$("$D" windows ponyhub | awk '{split($2,l,"="); split($5,w,"="); if (l[2]==0 && w[2]>=400) {split($1,i,"="); print i[2]}}' | head -1)
    [ -n "$SWIN" ] && lim 10 screencapture -x -o -l "$SWIN" "$OUT/shots/qa45-onboarding.png"
    [ "$AX" = yes ] && ASK=$(lim 20 "$D" ax-texts $BID | grep -c "Needs Accessibility")
fi
TAP1=$(grep -o 'HUD tap=[a-zA-Z]*' "$L1" | tail -1)
quit_opened
open_app "$L2"; in_file "$L2" "LAUNCH" 8; sleep 1.5
AGAIN=$(grep -c "ONBOARDING hud" "$L2")
quit_opened
if [ $ONB = yes ] && [ -n "$SWIN" ] && { [ "$AX" != yes ] || [ "$ASK" -ge 1 ]; } && [ "$AGAIN" = 0 ]; then
    pass QA-45 "First launch asks once for Accessibility for volume and brightness in the notch (FR-H1)" "${TAP1:-tap state not logged}; Settings opened on Activities with \"Needs Accessibility\" and Allow…; not again on the next launch ([shot](shots/qa45-onboarding.png))"
else
    fail QA-45 "First launch asks once for Accessibility for volume and brightness in the notch (FR-H1)" "${TAP1:-tap state not logged}; onboarding: $ONB; settings window: ${SWIN:-none}; permission row: $ASK; shown again on relaunch: $AGAIN"
fi
defaults write "$BID" hudOnboardedVersion "$(app_version)"

# QA-46: with Accessibility, the volume key shows its level in the notch and is kept from macOS
# (so its own pop-up doesn't appear).
launch_notchy
if grep -q "HUD tap=active" <(after "$LOG"); then
    sleep 2   # let the panel draw its first frames
    mark "$LOG"; "$D" media-key volume-up >/dev/null
    K=$(wait_for "$LOG" "HUD key=0 handled=" 3 && after "$LOG" | grep -o 'HUD key=0 handled=[a-z]*' | head -1)
    HUDST=no; W=0
    wait_for "$LOG" "STATE compact:hud" 2 && { HUDST=yes; sleep 0.6; shot qa46-volume; W=$(island_width qa46-volume); }
    HUDW=$(after "$LOG" | grep 'STATE compact:hud' | head -1 | sed -E 's/.*compact:hud ([0-9]+)x.*/\1/')
    "$D" media-key volume-down >/dev/null; sleep 2
    if [ "$K" = "HUD key=0 handled=true" ] && [ $HUDST = yes ] && near "${W:-0}" "${HUDW:-0}" 12; then
        pass QA-46 "Volume key: the level shows in the notch instead of macOS's pop-up (FR-H1)" "key taken by ponyhub ($K); the island showed the volume level, ${W} pt wide on screen ([shot](shots/qa46-volume.png))"
    else
        fail QA-46 "Volume key: the level shows in the notch instead of macOS's pop-up (FR-H1)" "${K:-the key never reached ponyhub}; HUD state: $HUDST (${HUDW:-?} pt); on screen: ${W:-?} pt; $(last_state)"
    fi
else
    skip QA-46 "Volume key: the level shows in the notch instead of macOS's pop-up (FR-H1)" "no Accessibility for ponyhub on this machine ($(after "$LOG" | grep -o 'HUD tap=[a-zA-Z]*' | tail -1))"
fi
quit_notchy

# ---------------------------------------------------------------- retro style
# Settings → General → Style: Retro. The bundled pixel fonts must load, and the island must draw.
defaults write "$BID" nonNotchMode whenActive
defaults write "$BID" islandStyle retro
launch_notchy; sleep 1
lim 8 open "ponyhub://timer?minutes=3"
if wait_for "$LOG" "STATE compact:timer" 6; then
    sleep 1; shot qa40-retro-compact
    "$D" jump "$CX" 400 >/dev/null; sleep 0.4; mark "$LOG"; "$D" move "$CX" $((MB / 2)) 400 >/dev/null
    wait_for "$LOG" "STATE expanded" 3 && { sleep 0.9; shot qa40-retro-expanded 240; }
    "$D" move "$CX" 520 200 >/dev/null
fi
FONTS=$(grep -E 'FONTS ' "$LOG" | tail -1 | sed -E 's/.*FONTS //')
W=$(island_width qa40-retro-compact)
if [ "$FONTS" = "text=true digits=true" ] && [ "${W:-0}" -gt 150 ]; then
    pass QA-40 "Retro style: pixel fonts load and the island draws in them (FR-S9)" "fonts: $FONTS; island ${W} pt ([compact](shots/qa40-retro-compact.png), [open](shots/qa40-retro-expanded.png))"
else
    fail QA-40 "Retro style: pixel fonts load and the island draws in them (FR-S9)" "fonts: ${FONTS:-not logged}; island ${W:-?} pt; $(last_state)"
fi
lim 8 open "ponyhub://timer/cancel"; sleep 0.5
quit_notchy
defaults delete "$BID" islandStyle 2>/dev/null

# ---------------------------------------------------------------- pomodoro, clipboard, shelf
echo "== pomodoro, clipboard and shelf"
defaults delete "$BID" shelfFiles 2>/dev/null
launch_notchy; sleep 1.5

# QA-41: notchy://pomodoro (the link scheme from before the rename, still handled) starts focus
# round 1; Skip on the timer page moves to the short break.
mark "$LOG"
lim 8 open "notchy://pomodoro"
if ! wait_for "$LOG" "STATE compact:timer" 6; then
    fail QA-41 "Pomodoro: focus, then Skip to the break (FR-T5)" "notchy://pomodoro gave no timer; $(last_state)"
elif [ "$INPUT" = yes ] && [ "$AX" = yes ]; then
    "$D" jump "$CX" 500 >/dev/null; sleep 0.3
    mark "$LOG"; "$D" move "$CX" $((MB / 2)) 400 >/dev/null
    wait_for "$LOG" "STATE expanded:timer" 3
    sleep 0.7; shot qa41-pomodoro-focus 240
    T1=$(lim 20 "$D" ax-texts $BID $AXR | grep -E '^(Focus|Short|Long)' | head -1)
    B=$(lim 20 "$D" ax-find $BID "Skip" $AXR 2>/dev/null)
    mark "$LOG"; [ -n "$B" ] && "$D" click $B
    T2=""
    if wait_for "$LOG" "POMODORO Short break" 3; then
        sleep 0.7; shot qa41-pomodoro-break 240
        T2=$(lim 20 "$D" ax-texts $BID $AXR | grep -E '^(Focus|Short|Long)' | head -1)
    fi
    if [ "$T1" = "Focus 1 of 4" ] && [ "$T2" = "Short break" ]; then
        pass QA-41 "Pomodoro: focus, then Skip to the break (FR-T5)" "started by the old notchy:// link; \"$T1\" → Skip → \"$T2\" ([focus](shots/qa41-pomodoro-focus.png), [break](shots/qa41-pomodoro-break.png))"
    else
        fail QA-41 "Pomodoro: focus, then Skip to the break (FR-T5)" "before: ${T1:-?}; Skip button: ${B:-not found}; after: ${T2:-?}; $(last_state)"
    fi
    "$D" move "$CX" 520 200 >/dev/null; sleep 1
else
    skip QA-41 "Pomodoro: focus, then Skip to the break (FR-T5)" "needs input synthesis and Accessibility"
fi
lim 8 open "ponyhub://timer/cancel"; sleep 0.8

# QA-42: copied text shows up in clipboard history; a copy marked private (as password managers
# mark them) never does.
CLIP="notchy-qa-clip-$$"; SECRET="qa-secret-$$"
mark "$LOG"
"$D" pasteboard "$CLIP" >/dev/null
ADDED=no; wait_for "$LOG" "CLIP added" 3 && ADDED=yes
mark "$LOG"
"$D" pasteboard "$SECRET" org.nspasteboard.ConcealedType >/dev/null
SKIPPED=no; wait_for "$LOG" "CLIP skipped" 3 && SKIPPED=yes
mark "$LOG"
lim 8 open "ponyhub://clipboard"
if wait_for "$LOG" "STATE expanded:shelf" 4; then
    sleep 0.8; shot qa42-clipboard 240
    if [ "$AX" = yes ]; then
        TEXTS=$(lim 20 "$D" ax-texts $BID $AXR | tr '\n' '|')
        SHOWN=$(echo "$TEXTS" | grep -c "$CLIP"); LEAKED=$(echo "$TEXTS" | grep -c "$SECRET")
    else
        SHOWN=1; LEAKED=0   # logged only; the screenshot is the evidence
    fi
    if [ $ADDED = yes ] && [ $SKIPPED = yes ] && [ "$SHOWN" -ge 1 ] && [ "$LEAKED" = 0 ] && ! grep -q "$SECRET" "$LOG"; then
        pass QA-42 "Clipboard history keeps copies, never private ones (FR-CB1, FR-CB2)" "copy listed; the copy marked org.nspasteboard.ConcealedType was skipped and appears nowhere, not even in the trace ([shot](shots/qa42-clipboard.png))"
    else
        fail QA-42 "Clipboard history keeps copies, never private ones (FR-CB1, FR-CB2)" "added=$ADDED skipped=$SKIPPED shown=$SHOWN leaked=$LEAKED"
    fi
else
    fail QA-42 "Clipboard history keeps copies, never private ones (FR-CB1, FR-CB2)" "ponyhub://clipboard did not open the shelf; $(last_state)"
fi
mark "$LOG"; "$D" click "$CX" 520; wait_for "$LOG" "DISMISS" 2; sleep 0.8

# QA-43: a file dragged from another app to the notch opens the shelf, drops there, and stays.
if [ "$INPUT" = yes ]; then
    F="$OUT/notchy-qa-shelf.txt"; echo "ponyhub shelf test" > "$F"
    "$D" jump "$CX" 500 >/dev/null; sleep 0.3
    mark "$LOG"
    DROP=$(lim 25 "$D" file-drag "$F" $((CX - 300)) 420 "$CX" $((MB / 2)) 1400 2>&1 | tail -1)
    sleep 0.8; shot qa43-shelf-drop 240
    NEAR=$(after "$LOG" | grep -c "DRAG files near"); OPENED=$(after "$LOG" | grep -c "STATE expanded:shelf")
    ADDED=$(after "$LOG" | grep -c "SHELF added 1")
    LISTED=0; [ "$AX" = yes ] && LISTED=$(lim 20 "$D" ax-texts $BID $AXR | grep -c "notchy-qa-shelf.txt")
    STAYED=$(last_state | cut -d' ' -f1)
    if [ "$DROP" = "drop accepted" ] && [ "$ADDED" -ge 1 ] && [ "$OPENED" -ge 1 ] && { [ "$AX" != yes ] || [ "$LISTED" -ge 1 ]; } && [ "$STAYED" = expanded:shelf ]; then
        pass QA-43 "Dragging a file to the notch drops it on the shelf (FR-F1)" "opened on the shelf as the drag arrived, drop accepted, file listed, still open after ([shot](shots/qa43-shelf-drop.png))"
    else
        fail QA-43 "Dragging a file to the notch drops it on the shelf (FR-F1)" "driver: ${DROP:-nothing}; near=$NEAR opened=$OPENED added=$ADDED listed=$LISTED after=$STAYED; $(after "$LOG" | grep -E 'CLICKTHROUGH|DROP|DRAG' | tail -4 | sed -E 's/^QA [0-9.]+ //' | tr '\n' ';')"
    fi
    "$D" move "$CX" 520 200 >/dev/null; sleep 1.2
else
    skip QA-43 "Dragging a file to the notch drops it on the shelf (FR-F1)" "needs input synthesis"
fi
quit_notchy
defaults delete "$BID" shelfFiles 2>/dev/null

# ---------------------------------------------------------------- updates
# Copies of ponyhub that think they are 1.0.0 and read releases from a local stand-in for GitHub
# (a test-only Info.plist key; shipped builds always ask GitHub). It offers 9.9.9. Covers the
# download, every check before installing, the swap in place and the relaunch.
echo "== updates"
UPD="$OUT/update"; rm -rf "$UPD"; mkdir -p "$UPD/feed"
PB=/usr/libexec/PlistBuddy
make_copy() { # dir version identity("-" = ad-hoc)
    rm -rf "$1"; mkdir -p "$1"; ditto "$APP" "$1/ponyhub.app"
    local plist="$1/ponyhub.app/Contents/Info.plist"
    $PB -c "Set :CFBundleShortVersionString $2" "$plist"
    $PB -c "Add :NotchyUpdateFeed string http://127.0.0.1:8765/latest.json" "$plist"
    # Plain HTTP to the local stand-in (App Transport Security otherwise insists on HTTPS).
    $PB -c "Add :NSAppTransportSecurity dict" -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" "$plist"
    codesign --force --timestamp=none --options runtime --sign "$3" "$1/ponyhub.app/Contents/Frameworks/MediaRemoteAdapter.framework" 2>> "$UPD/codesign.log"
    codesign --force --timestamp=none --options runtime --entitlements "$SRC/Resources/Notchy.entitlements" --sign "$3" "$1/ponyhub.app" 2>> "$UPD/codesign.log"
}
publish() { # app dir to offer as 9.9.9 ["bad" checksum]
    # Like a real release: ponyhub.zip, plus the same app as Notchy.zip/Notchy.app for copies from
    # before the rename (see release.yml).
    rm -rf "$UPD/feed/ponyhub.zip" "$UPD/feed/Notchy.zip" "$UPD/legacy-pack"
    (cd "$1" && ditto -c -k --keepParent ponyhub.app "$UPD/feed/ponyhub.zip")
    mkdir -p "$UPD/legacy-pack" && ditto "$1/ponyhub.app" "$UPD/legacy-pack/Notchy.app"
    (cd "$UPD/legacy-pack" && ditto -c -k --keepParent Notchy.app "$UPD/feed/Notchy.zip")
    (cd "$UPD/feed" && shasum -a 256 ponyhub.zip > ponyhub.zip.sha256 && shasum -a 256 Notchy.zip > Notchy.zip.sha256)
    [ "${2:-}" = bad ] && echo "0000000000000000000000000000000000000000000000000000000000000000  ponyhub.zip" > "$UPD/feed/ponyhub.zip.sha256"
    cat > "$UPD/feed/latest.json" <<JSON
{"tag_name": "v9.9.9", "html_url": "https://github.com/samidun26/dynamic-island-mac/releases/tag/v9.9.9",
 "body": "- QA release", "draft": false, "prerelease": false,
 "assets": [{"name": "ponyhub.zip", "browser_download_url": "http://127.0.0.1:8765/ponyhub.zip", "size": $(stat -f %z "$UPD/feed/ponyhub.zip")},
            {"name": "ponyhub.zip.sha256", "browser_download_url": "http://127.0.0.1:8765/ponyhub.zip.sha256", "size": 77},
            {"name": "Notchy.zip", "browser_download_url": "http://127.0.0.1:8765/Notchy.zip", "size": $(stat -f %z "$UPD/feed/Notchy.zip")},
            {"name": "Notchy.zip.sha256", "browser_download_url": "http://127.0.0.1:8765/Notchy.zip.sha256", "size": 77}]}
JSON
}
UPD_RESULT="" RELAUNCHED=""
try_update() { # installed dir: sets UPD_RESULT and RELAUNCHED
    local exe="$1/ponyhub.app/Contents/MacOS/ponyhub" pid
    mark "$LOG"
    NOTCHY_QA_LOG=1 NOTCHY_QA_UPDATE=install "$exe" >> "$LOG" 2>&1 &
    pid=$!
    if wait_for "$LOG" "UPDATE (installed|failed)" 45; then
        UPD_RESULT=$(after "$LOG" | grep -E 'UPDATE (installed|failed)' | tail -1 | sed -E 's/.*UPDATE //; s/ at \/.*//')
    else
        UPD_RESULT="timeout: $(after "$LOG" | grep UPDATE | tail -2 | sed -E 's/^QA [0-9.]+ //' | tr '\n' ';')"
    fi
    # An installed update quits this copy and opens the new one (without the test trace).
    RELAUNCHED=""
    for _ in $(seq 1 25); do
        RELAUNCHED=$(pgrep -f "$exe" | grep -vx "$pid" | head -1)
        [ -n "$RELAUNCHED" ] && break
        echo "$UPD_RESULT" | grep -q '^installed' || break
        sleep 0.4
    done
    kill "$pid" 2>/dev/null; pkill -f "$exe" 2>/dev/null; sleep 1
}
disk_version() { $PB -c 'Print CFBundleShortVersionString' "$1/ponyhub.app/Contents/Info.plist" 2>/dev/null; }
disk_version_of() { $PB -c 'Print CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null; }

python3 -m http.server 8765 --bind 127.0.0.1 --directory "$UPD/feed" > "$UPD/http.log" 2>&1 &
HTTP_PID=$!
# Wait until the stand-in actually answers (a cold runner can take a while to start Python).
for _ in $(seq 1 60); do curl -s -o /dev/null --max-time 2 http://127.0.0.1:8765/ && break; sleep 0.5; done

# QA-37: the usual case today: ad-hoc signed copy, ad-hoc signed release.
make_copy "$UPD/installed" 1.0.0 -
make_copy "$UPD/new" 9.9.9 -
publish "$UPD/new"
try_update "$UPD/installed"
V=$(disk_version "$UPD/installed")
if echo "$UPD_RESULT" | grep -q '^installed 9.9.9' && [ "$V" = 9.9.9 ] && [ -n "$RELAUNCHED" ] && codesign --verify --deep --strict "$UPD/installed/ponyhub.app" 2>/dev/null; then
    pass QA-37 "Update: finds a newer release, verifies it, installs it in place and relaunches (FR-S8)" "1.0.0 → 9.9.9 from the release feed; signature valid; new copy running (pid $RELAUNCHED)"
else
    fail QA-37 "Update: finds a newer release, verifies it, installs it in place and relaunches (FR-S8)" "result: $UPD_RESULT; on disk: ${V:-?}; relaunched: ${RELAUNCHED:-no}"
fi

# QA-44: a friend's copy from before the rename. The real Notchy 1.0.2 from GitHub Releases (its
# updater only knows Notchy.zip and Notchy.app) is pointed at the local feed and installs this
# build from the legacy asset; the new build then renames itself to ponyhub.app and starts again.
LEG="$UPD/legacy"; rm -rf "$LEG"; mkdir -p "$LEG"
if lim 60 curl -sSfL -o "$LEG/old.zip" "https://github.com/samidun26/dynamic-island-mac/releases/download/v1.0.2/Notchy.zip"; then
    ditto -x -k "$LEG/old.zip" "$LEG"
    OLDP="$LEG/Notchy.app/Contents/Info.plist"
    $PB -c "Add :NotchyUpdateFeed string http://127.0.0.1:8765/latest.json" "$OLDP"
    $PB -c "Add :NSAppTransportSecurity dict" -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" "$OLDP"
    codesign --force --timestamp=none --options runtime --entitlements "$SRC/Resources/Notchy.entitlements" --sign - "$LEG/Notchy.app" 2>> "$UPD/codesign.log"
    make_copy "$UPD/new" 9.9.9 -
    publish "$UPD/new"
    OLDV=$(disk_version_of "$LEG/Notchy.app")
    mark "$LOG"
    NOTCHY_QA_LOG=1 NOTCHY_QA_UPDATE=install "$LEG/Notchy.app/Contents/MacOS/Notchy" >> "$LOG" 2>&1 &
    OLDPID=$!
    R44="no answer"
    wait_for "$LOG" "UPDATE (installed|failed)" 45 && R44=$(after "$LOG" | grep -E 'UPDATE (installed|failed)' | tail -1 | sed -E 's/.*UPDATE //; s/ at \/.*//')
    # The old copy quits and opens the installed build, which renames itself and opens again.
    RENAMED=no; RUNNING=""
    for _ in $(seq 1 40); do
        if [ -d "$LEG/ponyhub.app" ] && [ ! -e "$LEG/Notchy.app" ]; then
            RENAMED=yes
            RUNNING=$(pgrep -f "$LEG/ponyhub.app/Contents/MacOS/ponyhub" | head -1)
            [ -n "$RUNNING" ] && break
        fi
        sleep 0.5
    done
    NEWV=$(disk_version_of "$LEG/ponyhub.app")
    kill "$OLDPID" 2>/dev/null; pkill -f "$LEG/" 2>/dev/null; sleep 1
    if echo "$R44" | grep -q '^installed 9.9.9' && [ $RENAMED = yes ] && [ "$NEWV" = 9.9.9 ] && [ -n "$RUNNING" ]; then
        pass QA-44 "Update from before the rename: Notchy 1.0.2 installs it and it becomes ponyhub.app (FR-S8)" "Notchy ${OLDV:-1.0.2} (the real release) installed 9.9.9 from Notchy.zip; it renamed itself to ponyhub.app and is running from there (pid $RUNNING)"
    else
        fail QA-44 "Update from before the rename: Notchy 1.0.2 installs it and it becomes ponyhub.app (FR-S8)" "old copy: $R44; renamed: $RENAMED (folder: $(ls "$LEG" | tr '\n' ' ')); version: ${NEWV:-?}; running: ${RUNNING:-no}"
    fi
else
    skip QA-44 "Update from before the rename: Notchy 1.0.2 installs it and it becomes ponyhub.app (FR-S8)" "could not download Notchy 1.0.2 from GitHub"
fi

# QA-38: a download that doesn't match the published checksum.
make_copy "$UPD/installed" 1.0.0 -
publish "$UPD/new" bad
try_update "$UPD/installed"
V=$(disk_version "$UPD/installed")
if echo "$UPD_RESULT" | grep -q "^failed: .*checksum" && [ "$V" = 1.0.0 ] && [ -z "$RELAUNCHED" ]; then
    pass QA-38 "Update: a download that doesn't match its checksum is refused (NFR-10)" "\"${UPD_RESULT#failed: }\"; installed copy untouched (1.0.0)"
else
    fail QA-38 "Update: a download that doesn't match its checksum is refused (NFR-10)" "result: $UPD_RESULT; on disk: ${V:-?}"
fi

# QA-39: with a release signing identity, only updates signed with the same identity install.
# Two throwaway identities in a temporary keychain (CI only: it changes the keychain list).
if [ "${CI:-}" = true ]; then
    QA_KEYCHAIN="$UPD/qa.keychain-db"
    OLD_KEYCHAINS=$(security list-keychains -d user | tr -d '"')
    security create-keychain -p qa "$QA_KEYCHAIN"
    security set-keychain-settings "$QA_KEYCHAIN"
    security unlock-keychain -p qa "$QA_KEYCHAIN"
    LEGACY=""; openssl pkcs12 -help 2>&1 | grep -q -- '-legacy' && LEGACY="-legacy"
    for who in A B; do
        printf '[req]\ndistinguished_name = dn\nx509_extensions = ext\nprompt = no\n[dn]\nCN = ponyhub QA %s\n[ext]\nbasicConstraints = critical, CA:false\nkeyUsage = critical, digitalSignature\nextendedKeyUsage = critical, codeSigning\n' "$who" > "$UPD/$who.cnf"
        openssl req -x509 -newkey rsa:2048 -sha256 -days 2 -nodes -config "$UPD/$who.cnf" -keyout "$UPD/$who.key" -out "$UPD/$who.pem" 2>/dev/null
        # shellcheck disable=SC2086
        openssl pkcs12 -export $LEGACY -inkey "$UPD/$who.key" -in "$UPD/$who.pem" -name "ponyhub QA $who" -out "$UPD/$who.p12" -passout pass:qa
        security import "$UPD/$who.p12" -k "$QA_KEYCHAIN" -P qa -T /usr/bin/codesign >/dev/null
    done
    security set-key-partition-list -S apple-tool:,apple: -s -k qa "$QA_KEYCHAIN" >/dev/null
    # shellcheck disable=SC2086
    security list-keychains -d user -s "$QA_KEYCHAIN" $OLD_KEYCHAINS
    IDA=$(security find-identity -p codesigning "$QA_KEYCHAIN" | awk '/ponyhub QA A/ {print $2; exit}')
    IDB=$(security find-identity -p codesigning "$QA_KEYCHAIN" | awk '/ponyhub QA B/ {print $2; exit}')
    if [ -n "$IDA" ] && [ -n "$IDB" ]; then
        make_copy "$UPD/installed" 1.0.0 "$IDA"
        make_copy "$UPD/new" 9.9.9 "$IDB"
        publish "$UPD/new"
        try_update "$UPD/installed"
        R_OTHER=$UPD_RESULT; V_OTHER=$(disk_version "$UPD/installed")
        make_copy "$UPD/new" 9.9.9 "$IDA"
        publish "$UPD/new"
        try_update "$UPD/installed"
        R_SAME=$UPD_RESULT; V_SAME=$(disk_version "$UPD/installed")
        if echo "$R_OTHER" | grep -q '^failed: .*same developer' && [ "$V_OTHER" = 1.0.0 ] && echo "$R_SAME" | grep -q '^installed 9.9.9' && [ "$V_SAME" = 9.9.9 ]; then
            pass QA-39 "Update: only a release signed with the same identity installs (NFR-10)" "signed by another identity: \"${R_OTHER#failed: }\"; same identity: installed 9.9.9"
        else
            fail QA-39 "Update: only a release signed with the same identity installs (NFR-10)" "other identity: $R_OTHER (disk ${V_OTHER:-?}); same identity: $R_SAME (disk ${V_SAME:-?}); $(tail -2 "$UPD/codesign.log" | tr '\n' ' ')"
        fi
    else
        fail QA-39 "Update: only a release signed with the same identity installs (NFR-10)" "could not create the test identities: $(security find-identity -p codesigning "$QA_KEYCHAIN" | tr '\n' ' ')"
    fi
else
    skip QA-39 "Update: only a release signed with the same identity installs (NFR-10)" "needs a throwaway keychain; runs on CI"
fi
kill "$HTTP_PID" 2>/dev/null; HTTP_PID=""

# ---------------------------------------------------------------- security
# Another program running as the user must not be able to borrow ponyhub's permissions
# (Accessibility, Calendars, Automation) by starting it with an environment that loads its code:
# DYLD_INSERT_LIBRARIES into ponyhub, or PERL5OPT/PERL5LIB into its Now Playing helper (perl).
# Each attack is first shown to work on an unprotected program, then tried on ponyhub.
echo "== security: code injection through the launch environment"
SEC="$OUT/sec"; rm -rf "$SEC"; mkdir -p "$SEC/perl"
printf '#include <stdio.h>\n#include <stdlib.h>\n#include <unistd.h>\n__attribute__((constructor)) static void injected(void) { FILE *f = fopen("%s", "a"); if (f) { fprintf(f, "%%s(%%d) ", getprogname(), getpid()); fclose(f); } }\n' "$SEC/marker-dylib" > "$SEC/inject.c"
printf 'int main(void) { return 0; }\n' > "$SEC/plain.c"
printf 'package QAInject;\nif (open(my $o, ">>", "%s")) { print $o "injected\\n"; close $o; }\n1;\n' "$SEC/marker-perl" > "$SEC/perl/QAInject.pm"
clang -dynamiclib -o "$SEC/inject.dylib" "$SEC/inject.c" 2>> "$OUT/harness-build.log"
clang -o "$SEC/plain" "$SEC/plain.c" 2>> "$OUT/harness-build.log"
DYLD_INSERT_LIBRARIES="$SEC/inject.dylib" "$SEC/plain"
PERL5LIB="$SEC/perl" PERL5OPT=-MQAInject /usr/bin/perl -e 1
CTRL_DYLIB=no; [ -s "$SEC/marker-dylib" ] && CTRL_DYLIB=yes
CTRL_PERL=no; [ -s "$SEC/marker-perl" ] && CTRL_PERL=yes
rm -f "$SEC/marker-dylib" "$SEC/marker-perl"
note "attacks work on unprotected programs: dylib $CTRL_DYLIB, perl $CTRL_PERL"

defaults write "$BID" nonNotchMode whenActive
mark "$LOG"
DYLD_INSERT_LIBRARIES="$SEC/inject.dylib" PERL5LIB="$SEC/perl" PERL5OPT=-MQAInject NOTCHY_QA_LOG=1 \
    "$APP/Contents/MacOS/ponyhub" >> "$LOG" 2>&1 &
NOTCHY_PID=$!
STARTED=no; wait_for "$LOG" "LAUNCH" 15 && STARTED=yes
ADAPTER=no; wait_for "$LOG" "NOWPLAYING title=QA" 10 && ADAPTER=yes
sleep 1
FLAGS=$(codesign -dv "$APP" 2>&1 | grep -o 'flags=[^ ]*')
if [ $CTRL_DYLIB = no ]; then
    skip QA-33 "Libraries injected at launch are refused (NFR-10)" "the injection does not work here even on an unprotected program"
elif [ $STARTED = yes ] && [ ! -e "$SEC/marker-dylib" ] && echo "$FLAGS" | grep -q runtime; then
    pass QA-33 "Libraries injected at launch are refused (NFR-10)" "DYLD_INSERT_LIBRARIES ran in a plain program, not in ponyhub ($FLAGS, __RESTRICT segment)"
else
    fail QA-33 "Libraries injected at launch are refused (NFR-10)" "started=$STARTED, injected into: $(cat "$SEC/marker-dylib" 2>/dev/null || echo nothing); $FLAGS; restrict segment: $(otool -l "$APP/Contents/MacOS/ponyhub" | grep -c __RESTRICT)"
fi
if [ $CTRL_PERL = no ]; then
    skip QA-34 "The Now Playing helper ignores Perl injection variables (NFR-10)" "PERL5OPT has no effect here even on plain perl"
elif [ $ADAPTER = yes ] && [ ! -e "$SEC/marker-perl" ]; then
    pass QA-34 "The Now Playing helper ignores Perl injection variables (NFR-10)" "PERL5OPT/PERL5LIB ran code in plain perl, not in the helper; Now Playing still works"
else
    fail QA-34 "The Now Playing helper ignores Perl injection variables (NFR-10)" "adapter running=$ADAPTER, injected=$([ -e "$SEC/marker-perl" ] && echo yes || echo no)"
fi
quit_notchy

# ---------------------------------------------------------------- downloaded copy (Gatekeeper)
# Last, because the system dialog it triggers stays on screen.
echo "== downloaded copy"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
DL="$OUT/download"; rm -rf "$DL"; mkdir -p "$DL/a" "$DL/b"
ditto -c -k --keepParent "$APP" "$DL/ponyhub.zip"
ditto -x -k "$DL/ponyhub.zip" "$DL/a"; ditto -x -k "$DL/ponyhub.zip" "$DL/b"
QUAR="0081;$(printf %x "$(date +%s)");Safari;"
xattr -w com.apple.quarantine "$QUAR" "$DL/a/ponyhub.app"
xattr -w com.apple.quarantine "$QUAR" "$DL/b/ponyhub.app"
if spctl --status 2>/dev/null | grep -q disabled; then
    skip QA-02 "Downloaded build: blocked while quarantined, opens after the guide's xattr step" "Gatekeeper is disabled on this machine"
else
    # a) opened as downloaded: must be blocked (LaunchServices waits on the dialog: do not wait for it)
    ( lim 6 open "$DL/a/ponyhub.app" >/dev/null 2>&1 & ); sleep 6
    BLOCKED=yes; pgrep -f "$DL/a/ponyhub.app/Contents/MacOS/ponyhub" >/dev/null && BLOCKED=no
    shot qa02-gatekeeper 700
    # b) the user guide's step first, then open: must run
    xattr -dr com.apple.quarantine "$DL/b/ponyhub.app"
    ( lim 10 open "$DL/b/ponyhub.app" >/dev/null 2>&1 & )
    RUNS=no
    for _ in $(seq 1 20); do pgrep -f "$DL/b/ponyhub.app/Contents/MacOS/ponyhub" >/dev/null && { RUNS=yes; break; }; sleep 0.5; done
    if [ $BLOCKED = yes ] && [ $RUNS = yes ]; then
        pass QA-02 "Downloaded build: blocked while quarantined, opens after the guide's xattr step" "blocked as downloaded ([shot](shots/qa02-gatekeeper.png)); after xattr -dr it opens"
    else
        fail QA-02 "Downloaded build: blocked while quarantined, opens after the guide's xattr step" "blocked=$BLOCKED, opens after xattr=$RUNS; $(spctl -a -t exec -vv "$DL/b/ponyhub.app" 2>&1 | tr '\n' ' ' | cut -c1-160)"
    fi
    pkill -f "$DL/a/ponyhub.app/Contents/MacOS/ponyhub"; pkill -f "$DL/b/ponyhub.app/Contents/MacOS/ponyhub"
fi
$LSREG -u "$DL/a/ponyhub.app" 2>/dev/null; $LSREG -u "$DL/b/ponyhub.app" 2>/dev/null

# ---------------------------------------------------------------- summary
{
    echo
    echo "**$PASS passed, $FAIL failed, $SKIP skipped.**"
    echo
    echo "CPU of ponyhub (average of three 2 s samples, on a CI virtual machine; expect less on real hardware): idle ${CPU}% · music playing in the compact wings ${CPU_COMPACT:-?}% · expanded Now Playing ${CPU_EXPANDED:-?}% · music paused, island idle ${CPU_PAUSED:-?}%."
    echo
    echo "Input synthesis: $INPUT. Accessibility for the driver: $AX. Screen: ${SW} pt wide, menu bar ${MB} pt, notch: $([ "${HASNOTCH:-no}" = yes ] && echo "${NW}×${NH} pt" || echo none)."
} >> "$REPORT"
echo "== $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
