## Install

You need a jailbroken Kindle Paperwhite (12th gen) with KMC and KPM.

1. Download **noface-*.zip** below and unzip it.
2. Plug in the Kindle. Copy the **noface** folder to the Kindle's drive, then copy the
   folder **noface/kpm/noface** into **kmc/kpm/packages** on the Kindle.
3. Eject the Kindle and type `;kpm launch noface` in its search bar.

To open noface whenever the Kindle starts, turn on Aa > More > "Open noface when the
Kindle starts".

**Dictionaries (optional):** download `dict-en.zip` or `dict-pt.zip` from the
[Dictionaries release](../../releases/tag/dictionaries), unzip, and copy the `dict-en`
or `dict-pt` file into the **noface-data** folder on the Kindle (noface creates it the
first time it runs).

## Updating

Copy the new **noface** folder over the old one; replacing it is fine. Everything noface
keeps (settings, reading positions, stats, dictionaries) lives in **noface-data**,
which updates never touch.
