#!/bin/bash
# Read-only DDC/CI survey.
#
# Asks each attached display whether it answers DDC/CI and what its monitor-side
# controls currently read. Nothing is written, so this cannot disturb a display
# or a measurement.
#
# Why it matters here: DDC/CI is how the monitor's OWN controls are reached -
# RGB gain and black level, contrast, picture preset, and brightness. That is
# the half of calibration PGenerator+ currently leaves to the operator, and
# locking brightness through it would fix by prevention the drift the meter
# probes can currently only detect.
#
#   ./ddc-probe.sh
#
# Requires m1ddc (brew install m1ddc). That is deliberate: DDC/CI has no public
# API on macOS, and the Apple Silicon route is the private IOAVService. Shelling
# out to a maintained tool keeps that risk outside the calibration binaries and
# makes it trivial to disable.
#
# Two traps this checks for, both found on 2026-08-15:
#
#   - m1ddc answers for a display that cannot possibly support DDC, by falling
#     back to the default display instead of failing. Two displays reporting an
#     identical control vector is the signature, and is flagged below.
#   - m1ddc supports USB-C / DisplayPort Alt Mode. Its own help says displays on
#     the built-in HDMI port of M1 and entry-level M2 Macs are not supported, so
#     an HDMI-attached panel may be unreachable even when it speaks DDC happily
#     to something else.

set -u
cd "$(dirname "$0")" || exit 1

if ! command -v m1ddc >/dev/null 2>&1; then
    cat <<'MSG'
m1ddc is not installed. It is the DDC/CI transport this probe uses:

  brew install m1ddc

DDC/CI has no public API on macOS. On Apple Silicon it goes through the private
IOAVService, so this deliberately shells out to a maintained tool rather than
linking that into anything that measures.
MSG
    exit 1
fi

echo "displays macOS reports:"
if [ -x ./pgen-colorsync-probe ]; then
    ./pgen-colorsync-probe list | grep -E "^  display|^    (uuid|profile)" | sed 's/^/  /'
else
    echo "  (pgen-colorsync-probe not here; skipping the ColorSync cross-reference)"
fi

echo
echo "displays m1ddc can address:"
m1ddc display list 2>&1 | sed 's/^/  /'

CONTROLS="luminance contrast red green blue"
echo
echo "reading monitor-side controls (nothing is written):"

VECTORS=""
UUIDS=$(m1ddc display list 2>/dev/null | sed -nE 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/p')

for uuid in $UUIDS; do
    name=$(m1ddc display list 2>/dev/null | grep "$uuid" | sed -E 's/^\[[0-9]+\] (.*) \(.*/\1/')
    printf "\n  %s\n  %s\n" "${name:-unnamed}" "$uuid"
    vector=""
    answered=0
    for control in $CONTROLS; do
        value=$(m1ddc display "$uuid" get "$control" 2>&1 | head -1)
        case "$value" in
            ''|*[!0-9]*) printf "    %-10s %s\n" "$control" "no reply"; vector="$vector|-" ;;
            *)           printf "    %-10s %s\n" "$control" "$value"
                         vector="$vector|$value"; answered=$((answered + 1)) ;;
        esac
    done
    maximum=$(m1ddc display "$uuid" get "max luminance" 2>&1 | head -1)
    case "$maximum" in
        ''|*[!0-9]*) printf "    %-10s %s\n" "max lum" "no reply" ;;
        *)           printf "    %-10s %s\n" "max lum" "$maximum" ;;
    esac
    [ "$answered" -eq 0 ] && printf "    -> does not answer DDC/CI\n"
    # A display whose brightness, contrast and all three colour gains report
    # the SAME number is not reporting its settings. No panel ships that way,
    # and m1ddc returns a plausible-looking value rather than failing when
    # nothing answered - so this shape means "no reading", not "82".
    distinct=$(printf "%s" "$vector" | tr "|" "\n" | grep -v "^-\?$" | sort -u | wc -l | tr -d " ")
    if [ "$answered" -ge 4 ] && [ "$distinct" -eq 1 ]; then
        printf "    -> ALL CONTROLS IDENTICAL - this is not a real reading.\n"
        printf "       Almost certainly the built-in panel's brightness being\n"
        printf "       returned for every query because nothing answered DDC.\n"
    fi
    VECTORS="$VECTORS
$uuid $vector"
done

echo
DUPES=$(echo "$VECTORS" | awk 'NF>1 {print $2}' | sort | uniq -d)
if [ -n "$DUPES" ]; then
    cat <<'MSG'
WARNING: two or more displays returned an IDENTICAL control vector.

m1ddc does not fail when a display cannot be addressed - it answers for the
default display instead. Identical vectors almost always mean one of these
readings belongs to a different panel, so do not trust either until they are
told apart by changing one control on the real display and re-reading.
MSG
    echo "$VECTORS" | awk -v d="$DUPES" 'NF>1 && index(d,$2) {print "  " $1}'
else
    echo "control vectors are distinct, so each reading is likely from its own display."
fi

# Measured 2026-08-15 for the record, so the next person does not repeat it:
#   Dell U2723QE, USB-C/DP    ->  65 / 75 / 100 / 100 / 100 - plausible and
#                                 distinct, so that panel genuinely answers
#   ASUS VE228, HDMI-to-DVI   ->  82 / 82 / 82 / 82 / 82 - not a reading

cat <<'MSG'

Notes
  - The built-in panel has no DDC/CI; any value reported for it is the fallback
    described above, not a real reading.
  - m1ddc addresses USB-C / DisplayPort Alt Mode. Displays on the built-in HDMI
    port of M1 and entry-level M2 Macs are not supported, so a panel on HDMI -
    including HDMI-to-DVI - may be unreachable here even though DDC itself runs
    over DVI perfectly well.
  - Everything above is read-only. Writing RGB gain or black level is what would
    make this useful for calibration, and is a separate decision.
MSG
