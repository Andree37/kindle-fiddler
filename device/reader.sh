#!/bin/sh
# Pauses the stock UI, runs the reader, and always puts the stock UI back.
# Usage: reader.sh <book.kfx>
DIR=/mnt/us/kf-reader
FONT=/usr/java/lib/fonts/Bookerly-Regular.ttf
prevent=$(lipc-get-prop com.lab126.powerd preventScreenSaver 2>/dev/null)

restore() {
    killall -CONT awesome 2>/dev/null
    lipc-set-prop com.lab126.pillow disableEnablePillow enable 2>/dev/null
    lipc-set-prop com.lab126.powerd preventScreenSaver "${prevent:-0}" 2>/dev/null
}
trap restore EXIT

lipc-set-prop com.lab126.powerd preventScreenSaver 1
lipc-set-prop com.lab126.pillow disableEnablePillow disable
killall -STOP awesome

STATE="$DIR/state-$(basename "$1" | md5sum | cut -c1-16)"
# Background plus wait, so a signal reaches the reader instead of waiting on it.
"$DIR/reader" "$1" "$FONT" "$STATE" >> "$DIR/reader.log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null' INT TERM HUP
wait "$pid"
wait "$pid"
echo "exit code $?" >> "$DIR/reader.log"
