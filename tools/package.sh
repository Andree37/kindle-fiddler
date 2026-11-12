#!/bin/sh
# Builds noface and packs it as one zip holding a single "noface" folder:
#
#   noface/                     the app, its picture helper, scripts and notices,
#                               copied to the root of the Kindle's drive
#   noface/kpm/noface/          the launcher entry, copied into kmc/kpm/packages/
#
# Nothing in it shares a name with a folder already on the Kindle, so copying it
# never asks to replace one (Finder replacing "kmc" would remove KMC).
#
#   tools/package.sh <version>  ->  zig-out/noface-<version>.zip
set -eu
version=${1:?version, like 1.0.0}
cd "$(dirname "$0")/.."
zig build
zig build scenarios
out=zig-out/package
rm -rf "$out"
mkdir -p "$out/noface/kpm/noface"

cp zig-out/bin/noface zig-out/bin/jxr2pgm "$out/noface/"
cp zig-out/bin/noface-scenarios "$out/noface/selftest"
cp device/noface.sh device/start.sh device/export.sh device/autostart.sh device/data.sh \
   device/noface-autostart.conf "$out/noface/"
cp device/kpm/launch.sh "$out/noface/kpm/noface/"
cp LICENSE.md THIRD_PARTY_NOTICES.md "$out/noface/"
printf 'noface %s\n' "$version" > "$out/noface/VERSION"
chmod 755 "$out/noface/noface" "$out/noface/jxr2pgm" "$out/noface/selftest" "$out/noface/"*.sh "$out/noface/kpm/noface/launch.sh"

zip_path="$PWD/zig-out/noface-$version.zip"
rm -f "$zip_path"
(cd "$out" && zip -qr -X "$zip_path" noface)
echo "$zip_path"
