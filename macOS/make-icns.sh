#!/bin/sh
# favicon.ico -> AppIcon.icns, using only what Command Line Tools provides.
#
# The repo keeps its artwork as a Windows .ico at the root, which the resource
# script and the header generators already refer to there. sips reads it, and
# iconutil turns a .iconset directory into the .icns a bundle wants.
#
#   make-icns.sh ../favicon.ico build/AppIcon.icns

set -eu

source=$1
output=$2
work=$(dirname "$output")/AppIcon.iconset

command -v sips >/dev/null 2>&1 || { echo "sips not available"; exit 1; }
command -v iconutil >/dev/null 2>&1 || { echo "iconutil not available"; exit 1; }

rm -rf "$work"
mkdir -p "$work"

# Flatten to a single PNG first. A multi-image .ico makes sips pick one for us,
# and which one is not worth depending on, so go through the largest size and
# scale down from there.
base=$(dirname "$output")/icon-base.png
sips -s format png "$source" --out "$base" >/dev/null 2>&1
sips -z 1024 1024 "$base" --out "$base" >/dev/null 2>&1

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$base" \
         --out "$work/icon_${size}x${size}.png" >/dev/null 2>&1
    double=$((size * 2))
    sips -z "$double" "$double" "$base" \
         --out "$work/icon_${size}x${size}@2x.png" >/dev/null 2>&1
done

iconutil -c icns "$work" -o "$output"
rm -rf "$work" "$base"
echo "  $output"
