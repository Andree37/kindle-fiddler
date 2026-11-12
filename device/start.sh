#!/bin/sh
# Exports the book list and opens noface. Started through device/kpm/launch.sh, or
# by autostart.sh with "now", which skips the wait: at boot there's no keyboard.
# Lives outside documents so it stays out of the library.
# From the search bar, KMC repaints the stock screen about 2 s after launching; start
# after that, so it doesn't draw over noface
[ "$1" = now ] || sleep 2
echo "launch $(date)"
killall jobman 2>/dev/null

. /mnt/us/noface/data.sh
/bin/sh "$APP/export.sh"
exec /bin/sh "$APP/noface.sh"
