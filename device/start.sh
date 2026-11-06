#!/bin/sh
# Exports the book list and opens noface. Started through device/kpm/launch.sh.
# Lives outside documents so it stays out of the library.
sleep 2 # Let KPM finish and the keyboard go away first
echo "launch $(date)"
killall jobman 2>/dev/null

DIR=/mnt/us/noface
/bin/sh "$DIR/export.sh"
exec /bin/sh "$DIR/noface.sh"
