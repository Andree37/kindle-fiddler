#!/bin/sh
# Exports the book list from the Kindle's catalog. noface reruns this to refresh.
. /mnt/us/noface/data.sh
DIR=$DATA
cp /var/local/cc.db /tmp/kf-cc.db
sqlite3 -separator "$(printf '\t')" /tmp/kf-cc.db \
    "select coalesce(p_location, ''), p_titles_0_nominal,
            coalesce(json_extract(j_credits, '\$[0].name.display'), ''),
            coalesce(p_percentFinished, 0), coalesce(p_lastAccess, 0),
            coalesce(p_readState, 0), coalesce(p_thumbnail, ''),
            coalesce(p_modificationTime, 0),
            case when p_isDownloading = 1 then 2
                 when coalesce(p_location, '') = '' then 1
                 else 0 end,
            coalesce(p_cdeKey, ''), coalesce(p_cdeType, ''), coalesce(p_guid, '')
     from Entries
     where p_location like '%.kfx'
        or (p_isArchived = 1 and p_isVisibleInHome = 1 and p_type = 'Entry:Item')" > "$DIR/library.tsv.tmp"
rm -f /tmp/kf-cc.db
[ -s "$DIR/library.tsv.tmp" ] && mv "$DIR/library.tsv.tmp" "$DIR/library.tsv"
