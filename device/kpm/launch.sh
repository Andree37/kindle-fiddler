#!/bin/sh
# Started by ";kpm launch kindle-fiddler". The library icon's launcher is broken,
# so this is the working way in. Detached so KPM can return straight away.
setsid sh /mnt/us/documents/kindle-fiddler.sh --detached >> /mnt/us/kf-reader/launch.log 2>&1 < /dev/null &
