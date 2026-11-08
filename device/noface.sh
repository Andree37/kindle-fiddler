#!/bin/sh
# Pauses the stock UI, runs noface, and always puts the stock UI back.
DIR=/mnt/us/noface
FONTS=/usr/java/lib/fonts
restore() {
    killall -CONT awesome 2>/dev/null
    lipc-set-prop com.lab126.pillow disableEnablePillow enable 2>/dev/null
    lipc-set-prop com.lab126.blanket load screensaver 2>/dev/null
    # Only noface's own power watcher, in case noface died before ending it. Stock
    # has listeners of its own that must keep running.
    for p in $(pidof lipc-wait-event); do
        grep -q "goingToScreenSaver,outOfScreenSaver" "/proc/$p/cmdline" 2>/dev/null && kill "$p"
    done
}
trap restore EXIT

# noface draws its own lock screen, so the stock one has to stay out of the way.
lipc-set-prop com.lab126.powerd preventScreenSaver 0
lipc-set-prop com.lab126.blanket unload screensaver 2>/dev/null
lipc-set-prop com.lab126.pillow disableEnablePillow disable
killall -STOP awesome

# Keep the log small: start over once it passes 512 KB, keeping one old copy.
if [ "$(wc -c < "$DIR/noface.log" 2>/dev/null || echo 0)" -gt 524288 ]; then
    mv "$DIR/noface.log" "$DIR/noface.log.old"
fi

# Background plus wait, so a signal reaches noface instead of waiting on it.
"$DIR/noface" "$DIR/library.tsv" "$FONTS/Bookerly-Regular.ttf" "$FONTS/Bookerly-Bold.ttf" "$FONTS/Amazon-Ember-Regular.ttf" "$FONTS/Amazon-Ember-Bold.ttf" "$DIR" >> "$DIR/noface.log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null' INT TERM HUP
wait "$pid"
wait "$pid"
echo "exit code $?" >> "$DIR/noface.log"
