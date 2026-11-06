#!/bin/sh
# Opens the test book in the fast reader. Started through device/kpm/launch.sh.
# Lives outside documents so it stays out of the library. Library screen comes later.
sleep 2 # Let KPM finish and the keyboard go away first
echo "launch $(date)"
killall jobman 2>/dev/null
cd /mnt/us/documents/Downloads/Items01 || exit 1
set -- As*intermit*.kfx
exec /bin/sh /mnt/us/kf-reader/reader.sh "$PWD/$1"
