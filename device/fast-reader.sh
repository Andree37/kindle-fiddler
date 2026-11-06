#!/bin/sh
# Name: Fast Reader
# Author: Andre Ribeiro
# Opens the test book in the fast reader. Library screen comes later.
killall jobman 2>/dev/null
cd /mnt/us/documents/Downloads/Items01 || exit 1
set -- As*intermit*.kfx
nohup setsid /bin/sh /mnt/us/kf-reader/reader.sh "$PWD/$1" >/dev/null 2>&1 </dev/null &
