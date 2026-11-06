#!/bin/sh
# Exports the book list and opens noface. Started through device/kpm/launch.sh.
# Lives outside documents so it stays out of the library.
sleep 2 # Let KPM finish and the keyboard go away first
echo "launch $(date)"
killall jobman 2>/dev/null

DIR=/mnt/us/noface
cp /var/local/cc.db /tmp/kf-cc.db
sqlite3 -separator "$(printf '\t')" /tmp/kf-cc.db \
    "select coalesce(p_location, ''), p_titles_0_nominal,
            coalesce(json_extract(j_credits, '\$[0].name.display'), ''),
            coalesce(p_percentFinished, 0), coalesce(p_lastAccess, 0),
            coalesce(p_readState, 0), coalesce(p_thumbnail, ''),
            coalesce(p_modificationTime, 0),
            case when p_isDownloading = 1 then 2
                 when coalesce(p_location, '') = '' then 1
                 else 0 end
     from Entries
     where p_location like '%.kfx'
        or (p_isArchived = 1 and p_isVisibleInHome = 1 and p_type = 'Entry:Item')" > "$DIR/library.tsv"
rm -f /tmp/kf-cc.db

exec /bin/sh "$DIR/noface.sh"
