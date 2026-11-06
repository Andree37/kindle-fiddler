#!/bin/sh
# Started by ";kpm launch kindle-fiddler". Library tap launching is broken,
# so this is the working way in. Detached so KPM can return straight away.
setsid sh /mnt/us/kf-reader/start.sh >> /mnt/us/kf-reader/launch.log 2>&1 < /dev/null &
