#!/bin/sh
# Name: Fast Reader
# Author: Andre Ribeiro
# Opens the test book in the fast reader. Library screen comes later.

# Detach from the library's launcher, which waits on this script and then fails.
if [ "$1" != "--detached" ]; then
    setsid sh /mnt/us/documents/fast-reader.sh --detached >> /mnt/us/kf-reader/launch.log 2>&1 < /dev/null &
    exit 0
fi

sleep 2 # Let the launcher finish and return to the home screen first
echo "launch $(date)"
killall jobman 2>/dev/null
cd /mnt/us/documents/Downloads/Items01 || exit 1
set -- As*intermit*.kfx
exec /bin/sh /mnt/us/kf-reader/reader.sh "$PWD/$1"
