#!/bin/bash
# End-to-end HDR test of the Patch Companion itself.
#
# Everything before this measured a probe. This drives the real Companion the
# way PGenerator+ drives it - pairing, poll, hdr10 patches - and checks that a
# patch asking for N nits actually produces N nits on the glass.
#
#   ./test-hdr-companion.sh <sdr-white-nits> [display name]
#   ./test-hdr-companion.sh 151.7
#
# Get the SDR white figure from:  ./run-experiment-2.sh --scrgb <display-id> X
# It is the measured value at 1.0, and it moves with the brightness slider, so
# do not change brightness between that run and this one.
#
# Enable HDR for the display first. The Companion refuses to present HDR when
# the display grants no headroom, which is the correct behaviour and will stop
# this script rather than produce numbers.

set -u
set +m
cd "$(dirname "$0")" || exit 1

DRY=0
if [ "${1:-}" = "--dry-run" ]; then DRY=1; shift; fi

[ $# -ge 1 ] || { echo "usage: $0 [--dry-run] <sdr-white-nits> [display name]" >&2; exit 2; }
WHITE=$1
DISPLAY_NAME=${2:-Built-in Retina Display}
PORT=8099
APP="apps/PGeneratorPlusPatchCompanion.app/Contents/MacOS/PGeneratorPlusPatchCompanion"

[ -x "$APP" ] || { echo "Companion not found at $APP" >&2; exit 1; }
[ -f mock-pgen-server.py ] || { echo "mock-pgen-server.py is not in this folder" >&2; exit 1; }
# --dry-run exercises pairing, the HDR renderer and the patch path without a
# meter, so the plumbing can be checked on a machine that has no colorimeter.
if [ "$DRY" = "1" ]; then
    METER_PORT=""
else
command -v spotread >/dev/null 2>&1 || { echo "spotread not found" >&2; exit 1; }

METER_PORT=$(spotread -? 2>&1 | awk "/-c listno/,/^ *-t /" \
    | grep -E "^ +[0-9]+ = " | sed -E "s/^ +([0-9]+) = '(.*)'.*/\1|\2/" \
    | grep -v "|/dev/" | head -1 | cut -d'|' -f1)
[ -n "$METER_PORT" ] || { echo "no colorimeter visible to ArgyllCMS" >&2; exit 1; }
fi

cleanup() {
    pkill -f PGeneratorPlusPatchCompanion 2>/dev/null
    pkill -f "mock-pgen-server.py --port $PORT" 2>/dev/null
}
trap cleanup EXIT INT TERM

# A stale conf points the Companion at whatever it paired with last.
rm -f "apps/PGeneratorPlusPatchCompanion.app/Contents/Resources/PGenPatchCompanion.conf"
rm -rf ~/Library/Application\ Support/PGeneratorPlus

echo "starting the mock unit..."
python3 mock-pgen-server.py --port "$PORT" --no-console >/tmp/pgen-hdr-mock.log 2>&1 &
sleep 2

echo "starting the Companion with SDR white $WHITE cd/m2 on \"$DISPLAY_NAME\"..."
"$APP" --server="http://127.0.0.1:$PORT" --display="$DISPLAY_NAME" \
    --sdr-white="$WHITE" >/tmp/pgen-hdr-companion.log 2>&1 &
sleep 9

curl -s "http://127.0.0.1:$PORT/mock/settings?correction_signal_mode=hdr10" >/dev/null
sleep 1

echo
printf "  %-9s %-6s %-12s %-9s %s\n" target code measured expected error
FAILED=0
RESULTS=""
for nits in 1 10 50 100 203 400; do
    code=$(python3 -c "
m1,m2=2610/16384,2523/4096*128
c1,c2,c3=3424/4096,2413/4096*32,2392/4096*32
Y=$nits/10000.0
ym=Y**m1
print(round(((c1+c2*ym)/(1+c3*ym))**m2*1023))")
    # input_max 1023 so the Companion normalises the code back to a PQ signal.
    curl -s "http://127.0.0.1:$PORT/mock/patch?r=$code&g=$code&b=$code&signal_mode=hdr10" >/dev/null
    sleep 3
    if [ "$DRY" = "1" ]; then
        reading=""
    else
        reading=$(spotread -e -x -O -c "$METER_PORT" 2>&1 | grep -i "Yxy:" | tail -1 \
                  | sed -E 's/.*Yxy: *([0-9.]+).*/\1/')
    fi
    ack=$(curl -s "http://127.0.0.1:$PORT/mock/state" \
          | python3 -c "import json,sys; d=json.load(sys.stdin); a=d.get('last_ack') or {}; print(a.get('status',''), (a.get('message') or '')[:90])")
    case "$ack" in
        error*) echo "  the Companion refused this patch:"; echo "    $ack"
                FAILED=1; break ;;
    esac
    if [ "$DRY" = "1" ]; then
        printf "  %-9s %-6s %-12s %-9s %s\n" "$nits" "$code" "(dry run)" "$nits" "$ack"
        continue
    fi
    [ -z "$reading" ] && { echo "  $nits: no meter reading"; FAILED=$((FAILED+1)); continue; }
    err=$(python3 -c "print(f'{abs($reading-$nits)/$nits*100:.1f}%')")
    printf "  %-9s %-6s %-12s %-9s %s\n" "$nits" "$code" "$reading" "$nits" "$err"
    RESULTS="$RESULTS$nits,$reading
"
done

echo
# A refusal is reported before anything else, dry run or not - claiming success
# directly under a refusal message is worse than saying nothing.
if [ "$FAILED" = "1" ]; then
    echo "Stopped. The Companion's own log:"
    grep -E "macOS:|HDR|headroom" /tmp/pgen-hdr-companion.log | tail -5 | sed 's/^/  /'
    echo
    echo "That is the guard doing its job, not a bug. Enable HDR for this display"
    echo "and try again; without headroom every patch above SDR white would clip."
    exit 1
fi
if [ "$DRY" = "1" ]; then
    echo "Dry run complete: the Companion accepted every hdr10 patch, so pairing,"
    echo "the extended-linear renderer and the patch path all work. Re-run without"
    echo "--dry-run, with a meter, to check the luminance is actually right."
    exit 0
fi

printf "%s" "$RESULTS" | python3 -c "
import sys
rows=[l.split(',') for l in sys.stdin.read().split('\n') if ',' in l]
if not rows: raise SystemExit('no results')
errs=[(float(t), abs(float(m)-float(t))/float(t)) for t,m in rows]
worst=max(e for _,e in errs)
print(f'  worst error across the range: {worst*100:.1f}%')
print()
if worst < 0.10:
    print('  PASS. A patch asking for N nits produced N nits. The extended-linear')
    print('  HDR path works end to end through the real Companion, and PGenerator+')
    print('  can profile this display in HDR.')
else:
    big=[(t,e) for t,e in errs if e>0.10]
    print('  Off target at: ' + ', '.join(f'{t:g} nits ({e*100:.0f}%)' for t,e in big))
    print('  If the errors grow toward the top, the panel is clipping - check the')
    print('  ceiling. If they are uniform, the SDR white figure is wrong; re-measure')
    print('  it without touching the brightness slider.')
"
