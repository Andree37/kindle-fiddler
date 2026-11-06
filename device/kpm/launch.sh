#!/bin/sh
# Started by ";kpm launch noface". Library tap launching is broken,
# so this is the working way in. Detached so KPM can return straight away.
setsid sh /mnt/us/noface/start.sh >> /mnt/us/noface/launch.log 2>&1 < /dev/null &
