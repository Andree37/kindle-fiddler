# Developing noface

## Building

Needs [Zig](https://ziglang.org) 0.17.

- `zig build`: the app (`zig-out/bin/noface`) and the picture helper (`jxr2pgm`), for
  the Kindle (32-bit ARM, static).
- `zig build test`: unit tests.
- `zig build check`: the ownership boundaries below.
- `zig build tools`: development tools, also for the Kindle.

## Installing a build by hand

noface runs from `/mnt/us/noface/` and opens from the home search bar with
`;kpm launch noface`.

1. Copy `noface` and `jxr2pgm` from `zig-out/bin/` into `/mnt/us/noface/`.
2. Copy the scripts in `device/` there too, and `device/kpm/` into KPM's app folder.
3. To open noface when the Kindle starts, turn on Aa > More > "Open noface when the
   Kindle starts", and copy `device/noface-autostart.conf` into `/etc/upstart/` (with
   the root filesystem mounted read-write). Three failed starts in a row turn it off
   again by themselves. The Kindle button in the drag-down panel always returns to the
   stock home screen.

## Dictionaries

The Kindle's own dictionaries are DRM protected, so noface uses Wiktionary instead.
Build the files from the extracts at [kaikki.org](https://kaikki.org):

```
curl -LO https://kaikki.org/dictionary/English/kaikki.org-dictionary-English.jsonl.gz
curl -LO https://kaikki.org/dictionary/Portuguese/kaikki.org-dictionary-Portuguese.jsonl.gz
python3 tools/build_dictionary.py kaikki.org-dictionary-English.jsonl.gz dict-en
python3 tools/build_dictionary.py kaikki.org-dictionary-Portuguese.jsonl.gz dict-pt
```

Then put `dict-en` (about 95 MB) and `dict-pt` (about 38 MB) in `/mnt/us/noface/`.
A book's language is worked out from its text.

## Layout

Code is split by who owns it. `zig build check` fails if a file imports across these lines.

- `src/kindle/`: everything that knows Amazon: the KFX format, lipc services, the
  store, annotation sync, the catalog export, fonts, the screen and input devices.
- `src/linux/`: Linux itself: files, processes with timeouts, time.
- `src/model/`: our data, with no I/O: books, settings, the library, highlights,
  bookmarks, search, the dictionary format, the reading journal, reading stats.
- `src/gfx/`: pixels, fonts and pictures.
- `src/layout/`: setting a book's text into pages, and hyphenation.
- `src/ui/`: drawing screens and mapping taps to controls.
- `src/screens/`: the flow of each screen. The only place that calls into `kindle/`.
- `src/app.zig`, `src/main.zig`: what screens share, and startup.
- `src/core.zig`: the parts the tools share. `src/tests.zig` runs every test.
- `device/`: scripts installed on the Kindle, and `jxr2pgm`, the picture helper that
  decodes JPEG XR with the Kindle's own library.
- `tools/`: development tools, not part of the app. `tools/check/` holds the boundary
  check, `tools/build_dictionary.py` builds the dictionaries, and `fbrec`, `touchsim`
  and `xtap` record the screen and fake taps, for timing and demos.
- `third_party/`: stb libraries.

## How the speed comparison was measured

`docs/speed.gif` was recorded on a Kindle Paperwhite 12th gen with `tools/fbrec`
(the screen's memory, 30 frames a second, each with its time) while `tools/xtap`
(stock reader) and `tools/touchsim` (noface) tapped to turn eight pages of the same
public-domain book. The time is from the tap until the new page is in the screen's
memory; the e‑ink panel's own refresh follows and takes the same time in both. The
book is Project Gutenberg's edition of *Pride and Prejudice*, with Hugh Thomson's 1894
illustrations.

