#!/bin/sh
# Exports the book list and opens the reader. Started through device/kpm/launch.sh.
# Lives outside documents so it stays out of the library.
sleep 2 # Let KPM finish and the keyboard go away first
echo "launch $(date)"
killall jobman 2>/dev/null

DIR=/mnt/us/kf-reader
cp /var/local/cc.db /tmp/kf-cc.db
sqlite3 -separator "$(printf '\t')" /tmp/kf-cc.db \
    "select p_location, p_titles_0_nominal,
            coalesce(json_extract(j_credits, '\$[0].name.display'), ''),
            coalesce(p_percentFinished, 0), coalesce(p_lastAccess, 0),
            coalesce(p_readState, 0)
     from Entries where p_location like '%.kfx'" > "$DIR/library.tsv"
rm -f /tmp/kf-cc.db

exec /bin/sh "$DIR/reader.sh"
