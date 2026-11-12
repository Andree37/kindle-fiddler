# Sourced by the other scripts: where noface lives, and where what it keeps lives.
#
# The app sits in /mnt/us/noface, which an update replaces whole. Settings, reading
# positions, stats, notes, the battery log and the dictionaries sit apart, in
# /mnt/us/noface-data, which no update touches. Installs from before the split kept
# both in /mnt/us/noface: the first run moves everything that isn't the app across.
# It goes through a temporary folder, renamed when done, so a run cut short simply
# finishes the move next time.
APP=/mnt/us/noface
DATA=/mnt/us/noface-data

if [ ! -d "$DATA" ]; then
    mkdir -p "$DATA.moving"
    for f in "$APP"/* "$APP"/.[!.]*; do
        [ -e "$f" ] || continue
        case "${f##*/}" in
            # The app itself, and its install log
            noface | noface.new | jxr2pgm | selftest | *.sh | noface-autostart.conf | LICENSE.md | \
            THIRD_PARTY_NOTICES.md | VERSION | kpm | launch.log) ;;
            *) mv "$f" "$DATA.moving/" ;;
        esac
    done
    mv "$DATA.moving" "$DATA"
fi
