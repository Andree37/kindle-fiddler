#!/bin/sh
# Starts noface when the Kindle boots. Installed as /mnt/us/emergency.sh, run by
# /etc/upstart/noface-autostart.conf once the user drive is mounted (KMC's kmc.conf
# also runs it, but too early to find it). Deleting either file undoes autostart.
#
# It never holds up boot: it returns at once and starts noface in the background.
# Safety:
#   - Off unless the settings say "autostart on" (Aa > More in noface).
#   - Crash guard: three boots in a row where noface didn't run for a minute turn
#     autostart off by themselves (noface.sh clears the count after a good minute).
DIR=/mnt/us/noface
# Once per boot: the drive comes back after every USB unplug, and both KMC's hook and
# ours may call this. /tmp is in RAM, so the mark is gone on the next boot.
[ -e /tmp/noface-autostart-ran ] && exit 0
touch /tmp/noface-autostart-ran
grep -q '^autostart on' "$DIR/settings" 2>/dev/null || exit 0
count=$(cat "$DIR/boot-attempts" 2>/dev/null || echo 0)
if [ "$count" -ge 3 ]; then
    sed -i 's/^autostart on/autostart off/' "$DIR/settings"
    rm -f "$DIR/boot-attempts"
    echo "autostart: noface failed to start 3 boots in a row, autostart turned off" >> "$DIR/noface.log"
    exit 0
fi
echo $((count + 1)) > "$DIR/boot-attempts"
# Give the Kindle's home a moment to finish drawing, then open noface over it.
nohup sh -c 'sleep 20; /var/local/kmc/sbin/kpm.sh launch noface' > /dev/null 2>&1 &
exit 0
