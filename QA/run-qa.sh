#!/bin/bash
# End-to-end QA on a real macOS session (GitHub's macOS runner or your own Mac).
#
#   QA/run-qa.sh <app-source-dir> <output-dir>
#
# Installs Notchy from source the way docs/USER_GUIDE.md describes, then drives it with
# synthetic mouse/trackpad input (QA/Driver) and a fake music app (QA/FakePlayer), asserting on
# Notchy's test trace (NOTCHY_QA_LOG=1), the fake player's log, window lists, the accessibility
# tree and screenshots. Writes <output-dir>/results.md and <output-dir>/shots/*.png.
#
# On your own Mac: it moves the mouse and changes Notchy's preferences (restored at the end),
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
APP=/Applications/Notchy.app
BID=dev.local.notchy
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
# Average %CPU of Notchy over the last three of four 2-second top samples.
cpu_avg() { top -l 4 -s 2 -pid "$NOTCHY_PID" -stats cpu | awk '{gsub(/ /,"")} /^[0-9.]+$/ {v[n++]=$0} END {s=0; for (i=n-3; i<n; i++) s+=v[i]; printf "%.1f", s/3}'; }
near() { [ "$1" -ge $(($2 - $3)) ] && [ "$1" -le $(($2 + $3)) ]; }

launch_notchy() {
    mark "$LOG"
    NOTCHY_QA_LOG=1 "$APP/Contents/MacOS/Notchy" >> "$LOG" 2>&1 &
    NOTCHY_PID=$!
    wait_for "$LOG" "LAUNCH" 15
}
quit_notchy() {
    [ -n "$NOTCHY_PID" ] && kill -TERM "$NOTCHY_PID" 2>/dev/null
    for _ in $(seq 1 30); do kill -0 "$NOTCHY_PID" 2>/dev/null || break; sleep 0.2; done
    NOTCHY_PID=""
}
cleanup() {
    quit_notchy
    [ -n "$FP_PID" ] && kill "$FP_PID" 2>/dev/null
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
    rm -rf "$APP" && ditto "$SRC/build/Notchy.app" "$APP"
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

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"

# ---------------------------------------------------------------- privacy default
echo "== screen-sharing privacy (default settings)"
defaults delete "$BID" >/dev/null 2>&1
defaults write "$BID" calendarEnabled -bool false   # its permission prompt would sit on screen with nobody to answer
touch "$LOG" "$FPLOG"
launch_notchy || note "no LAUNCH line in the trace"
mark "$LOG"; lim 8 open "notchy://timer?seconds=30"
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

# Window: one panel, top-centre, above the menu bar, plus a menu bar item.
WINS=""
for _ in $(seq 1 15); do
    WINS=$("$D" windows Notchy)
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
if [ "$(state_since | cut -d' ' -f1)" = idle ] && [ "${W:-0}" -lt 40 ]; then
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
"$FP_APP/Contents/MacOS/FakePlayer" > "$FPLOG" 2>&1 &
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
    NOTCH=$(grep LAUNCH "$LOG" | tail -1 | sed -E 's/.*notchSize=([0-9]+)x([0-9]+).*/\1 \2/')
    NW=${NOTCH%% *}; NH=${NOTCH##* }
    WANT=$((NW + 2 * (NH + 12)))   # notch + two wings of (notch height + 12)
    if [ "$(last_state | cut -d' ' -f1)" = compact:nowPlaying ] && near "${W:-0}" "$WANT" 6; then
        pass QA-09 "Compact wings: artwork + equaliser (FR-N3)" "${W} pt wide, expected ${WANT} ([shot](shots/qa09-compact.png))"
    else
        fail QA-09 "Compact wings: artwork + equaliser (FR-N3)" "state $(last_state), ${W} pt wide, expected ${WANT}"
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
    sleep 0.6; "$D" jump "$CX" $((MB / 2)) >/dev/null
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
lim 8 open "notchy://timer?seconds=8"
if wait_for "$LOG" "URL notchy://timer" 4 && wait_for "$LOG" "STATE compact:timer" 4; then
    sleep 0.8; shot qa21-timer
    W=$(island_width qa21-timer)
    pass QA-21 "notchy://timer starts a timer in the wings, music as a glyph (FR-T1, FR-A3)" "$(grep 'STATE compact:timer' "$LOG" | tail -1 | sed -E 's/.*STATE //'); ${W} pt ([shot](shots/qa21-timer.png))"
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
    fail QA-21 "notchy://timer starts a timer in the wings, music as a glyph (FR-T1, FR-A3)" "state $(last_state)"
    skip QA-22 "Timer ends: peek, then clears itself (FR-T3)" "QA-21 failed"
fi

if [ "$INPUT" = yes ] && [ "$AX" = yes ]; then
    lim 8 open "notchy://timer?minutes=5"; sleep 1
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
echo "== settings window and menu"
mark "$LOG"
lim 8 open "notchy://settings"
if wait_for "$LOG" "SETTINGS shown" 4; then
    sleep 1.5
    # A normal-level (layer 0) window of about 500 pt: titles need Screen Recording to read.
    SW_ID=$("$D" windows Notchy | awk '{split($2,l,"="); split($5,w,"="); if (l[2]==0 && w[2]>=400) {split($1,i,"="); print i[2]}}' | head -1)
    if [ -n "$SW_ID" ]; then
        lim 10 screencapture -x -o -l "$SW_ID" "$OUT/shots/qa24-settings.png"
        CLOSED=untested
        FOCUSED=$(grep -o 'SETTINGS focused=[a-z]*' "$LOG" | tail -1 | cut -d= -f2)
        if [ "$INPUT" = yes ]; then
            "$D" key cmd-w; sleep 0.8
            "$D" windows Notchy | awk '{split($1,i,"="); print i[2]}' | grep -qx "$SW_ID" && CLOSED=no || CLOSED=yes
        fi
        if [ "$CLOSED" != no ]; then
            pass QA-24 "Settings window opens; ⌘W closes it (FR-S2)" "window shown and focused=${FOCUSED:-?} ([shot](shots/qa24-settings.png)); closed by ⌘W: $CLOSED"
        else
            fail QA-24 "Settings window opens; ⌘W closes it (FR-S2)" "window shown, focused=${FOCUSED:-?} ([shot](shots/qa24-settings.png)), but ⌘W did not close it"
        fi
    else
        fail QA-24 "Settings window opens; ⌘W closes it (FR-S2)" "no settings window on screen"
    fi
else
    fail QA-24 "Settings window opens (FR-S2)" "notchy://settings not handled"
fi

menu_click() { # $1 = label for the evidence
    ITEM=$("$D" windows Notchy | awk '{split($5,w,"="); split($6,h,"="); if (h[2]>0 && h[2]<=40 && w[2]<60) print}' | head -1)
    [ -z "$ITEM" ] && { echo "no-item"; return; }
    IX=$(echo "$ITEM" | sed -E 's/.* x=([0-9]+).*/\1/'); IW=$(echo "$ITEM" | sed -E 's/.* w=([0-9]+).*/\1/')
    mark "$LOG"
    "$D" click $((IX + IW / 2)) $((MB / 2)); sleep 0.6
    lim 10 screencapture -x -R "$((IX - 220)),0,320,260" "$OUT/shots/qa26-menu-$1.png"
    if wait_for "$LOG" "MENU opened" 2; then echo yes; else echo no; fi
    "$D" key escape; sleep 0.4
}
if [ "$INPUT" = yes ]; then
    open -a Finder; sleep 1                       # the usual case: another app in front
    M1=$(menu_click other-app)
    lim 8 open "notchy://settings"; sleep 1.2      # Notchy itself in front (Settings open)
    M2=$(menu_click notchy-active)
    "$D" key cmd-w; sleep 0.5
    if [ "$M1" = yes ]; then
        pass QA-26 "Menu bar menu opens (FR-S1)" "with another app in front ([shot](shots/qa26-menu-other-app.png)). Observation: with Notchy's own Settings window in front a synthetic click opened it: $M2"
    else
        fail QA-26 "Menu bar menu opens (FR-S1)" "another app in front: $M1; Notchy in front: $M2; trace: $(grep -E 'MOUSEDOWN|MENU' "$LOG" | tail -3 | sed -E 's/^QA [0-9.]+ //' | tr '\n' ';')"
    fi
else
    skip QA-26 "Menu bar menu opens (FR-S1)" "cannot synthesise input"
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

quit_notchy; sleep 1
if pgrep -f "mediaremote-adapter.pl" >/dev/null; then
    fail QA-28 "Quitting stops the Now Playing helper (NFR-4)" "perl adapter still running"
else
    pass QA-28 "Quitting stops the Now Playing helper (NFR-4)" "no adapter process left"
fi

defaults write "$BID" nonNotchMode never
launch_notchy; sleep 1.5
if "$D" windows Notchy | awk '{split($5,w,"="); if (w[2]>300) f=1} END {exit f}'; then
    pass QA-29 "\"Never\" on displays without a notch hides the island (FR-W5)" "no panel window on screen"
else
    fail QA-29 "\"Never\" on displays without a notch hides the island (FR-W5)" "panel still on screen"
fi
quit_notchy

# ---------------------------------------------------------------- downloaded copy (Gatekeeper)
# Last, because the system dialog it triggers stays on screen.
echo "== downloaded copy"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
DL="$OUT/download"; rm -rf "$DL"; mkdir -p "$DL/a" "$DL/b"
ditto -c -k --keepParent "$APP" "$DL/Notchy.zip"
ditto -x -k "$DL/Notchy.zip" "$DL/a"; ditto -x -k "$DL/Notchy.zip" "$DL/b"
QUAR="0081;$(printf %x "$(date +%s)");Safari;"
xattr -w com.apple.quarantine "$QUAR" "$DL/a/Notchy.app"
xattr -w com.apple.quarantine "$QUAR" "$DL/b/Notchy.app"
if spctl --status 2>/dev/null | grep -q disabled; then
    skip QA-02 "Downloaded build: blocked while quarantined, opens after the guide's xattr step" "Gatekeeper is disabled on this machine"
else
    # a) opened as downloaded: must be blocked (LaunchServices waits on the dialog: do not wait for it)
    ( lim 6 open "$DL/a/Notchy.app" >/dev/null 2>&1 & ); sleep 6
    BLOCKED=yes; pgrep -f "$DL/a/Notchy.app/Contents/MacOS/Notchy" >/dev/null && BLOCKED=no
    shot qa02-gatekeeper 700
    # b) the user guide's step first, then open: must run
    xattr -dr com.apple.quarantine "$DL/b/Notchy.app"
    ( lim 10 open "$DL/b/Notchy.app" >/dev/null 2>&1 & )
    RUNS=no
    for _ in $(seq 1 20); do pgrep -f "$DL/b/Notchy.app/Contents/MacOS/Notchy" >/dev/null && { RUNS=yes; break; }; sleep 0.5; done
    if [ $BLOCKED = yes ] && [ $RUNS = yes ]; then
        pass QA-02 "Downloaded build: blocked while quarantined, opens after the guide's xattr step" "blocked as downloaded ([shot](shots/qa02-gatekeeper.png)); after xattr -dr it opens"
    else
        fail QA-02 "Downloaded build: blocked while quarantined, opens after the guide's xattr step" "blocked=$BLOCKED, opens after xattr=$RUNS; $(spctl -a -t exec -vv "$DL/b/Notchy.app" 2>&1 | tr '\n' ' ' | cut -c1-160)"
    fi
    pkill -f "$DL/a/Notchy.app/Contents/MacOS/Notchy"; pkill -f "$DL/b/Notchy.app/Contents/MacOS/Notchy"
fi
$LSREG -u "$DL/a/Notchy.app" 2>/dev/null; $LSREG -u "$DL/b/Notchy.app" 2>/dev/null

# ---------------------------------------------------------------- summary
{
    echo
    echo "**$PASS passed, $FAIL failed, $SKIP skipped.**"
    echo
    echo "CPU of Notchy (average of three 2 s samples, on a CI virtual machine; expect less on real hardware): idle ${CPU}% · music playing in the compact wings ${CPU_COMPACT:-?}% · expanded Now Playing ${CPU_EXPANDED:-?}% · music paused, island idle ${CPU_PAUSED:-?}%."
    echo
    echo "Input synthesis: $INPUT. Accessibility for the driver: $AX. Screen: ${SW} pt wide, menu bar ${MB} pt, no notch."
} >> "$REPORT"
echo "== $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
