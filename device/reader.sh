#!/bin/sh
# Pauses the stock UI, runs the reader, and always puts the stock UI back.
DIR=/mnt/us/kf-reader
FONTS=/usr/java/lib/fonts
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

# Background plus wait, so a signal reaches the reader instead of waiting on it.
"$DIR/reader" "$DIR/library.tsv" "$FONTS/Bookerly-Regular.ttf" "$FONTS/Bookerly-Bold.ttf" "$FONTS/Amazon-Ember-Regular.ttf" "$FONTS/Amazon-Ember-Bold.ttf" "$DIR" >> "$DIR/reader.log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null' INT TERM HUP
wait "$pid"
wait "$pid"
echo "exit code $?" >> "$DIR/reader.log"
