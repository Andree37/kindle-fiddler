# Sourced by the other scripts: where noface lives, and where what it keeps lives.
#
# The app sits in /mnt/us/noface, which an update replaces whole. Settings, reading
# positions, stats, notes, the battery log and the dictionaries sit apart, in
# /mnt/us/noface-data, which no update touches. Installs from before the split kept
# both in /mnt/us/noface: what isn't the app is moved across. The first time it goes
# through a temporary folder, renamed when done, so a run cut short finishes next
# time; if noface-data already exists (made by hand for a dictionary, say), anything
# old is moved in unless the same name is already there.
APP=/mnt/us/noface
DATA=/mnt/us/noface-data

# Whether a file in the app folder is part of the app, or the install log
is_app() {
    case "${1##*/}" in
        noface | noface.new | jxr2pgm | selftest | *.sh | noface-autostart.conf | LICENSE.md | \
        THIRD_PARTY_NOTICES.md | VERSION | kpm | launch.log) return 0 ;;
    esac
    return 1
}

if [ ! -d "$DATA" ]; then
    mkdir -p "$DATA.moving"
    for f in "$APP"/* "$APP"/.[!.]*; do
        [ -e "$f" ] || continue
        is_app "$f" || mv "$f" "$DATA.moving/"
    done
    mv "$DATA.moving" "$DATA"
else
    for f in "$APP"/* "$APP"/.[!.]*; do
        [ -e "$f" ] || continue
        is_app "$f" && continue
        [ -e "$DATA/${f##*/}" ] || mv "$f" "$DATA/"
    done
fi
