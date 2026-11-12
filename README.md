# noface

A fast reader for a jailbroken Kindle Paperwhite 12th gen, written in Zig. It replaces
the Kindle's home screen and reader while leaving Amazon's services running: sync,
Wi-Fi, purchases and highlights carry on as before.

noface is free for personal, noncommercial use (see [License](#license)). It is an
independent project, not made, endorsed or supported by Amazon.

<p align="center"><img src="docs/speed.gif" width="560" alt="The stock Kindle reader and noface side by side, turning pages of the same book: the stock reader's new page appears about 300 ms after the tap, noface's about 60 ms after"></p>

**Turning a page: about 60 ms in noface, about 330 ms in the stock reader.** Measured on
the same Kindle Paperwhite 12th gen and the same public-domain book, eight page turns
each, from the moment of the tap until the new page is in the screen's memory (median;
recorded with `tools/fbrec`, frames 33 ms apart). The e‑ink panel then takes the same
time to show it in both, so what you see is the gap above plus the panel's own refresh.

<p align="center"><img src="docs/tour.gif" width="420" alt="A tour of noface: the library, a book's cover and an illustrated chapter, a page of text, a dictionary lookup, a picture shown full screen and zoomed, the light panel, text settings, searching as you type, the next book offered on finishing one of a series, the library sorted by series, and reading stats"></p>

## What it does

**Library**
- The current book on a "Continue reading" card, with progress and when you last read it.
- All, Unread and Read filters. Sort by Recent, Progress, A to Z, Author or Newest.
- Search by title, author or series, with matching books listed as you type.
- Series read from file names ("… -- Dune Chronicles #1, 1965 -- …") and Calibre's EPUB
  metadata. Books show their number and stay in order when sorted.
- Press and hold a cover to download, remove, or mark it read.
- EPUBs copied over USB show up next to Kindle books.

**Reading**
- KFX books and EPUBs without DRM, with pictures, footnotes and the table of contents.
  noface never removes or works around DRM. A protected book, as most bought from
  Amazon are, says it can't be opened here; read it in the Kindle's own reader (the
  Kindle button in the drag-down panel).
- Tap or swipe to turn pages. Tap the top of the page for the toolbar; drag down from
  the top for light, warmth, airplane mode, Bluetooth and sync.
- Hyphenation for English and Portuguese, so justified lines fill the width.
- Themes, four typefaces, bold, text size, line spacing, margins and justification.
- Time left in the chapter and the book, from a reading speed learned as you read.
- Press and hold a word for its definition. Hold and drag to highlight.
- Highlights and bookmarks sync with the Kindle apps for Amazon books; EPUB ones stay
  on the device.
- Search in the book, Go to page, and the cover of your book on the lock screen.

**Stats**
- Time read today and over the last seven days, your streak, books finished this year
  and your reading speed. A daily journal is kept from the first day noface runs.

## Before you install

- noface runs only on a **jailbroken** Kindle. Jailbreaking is your own choice, made
  under your own agreement with Amazon: it may go against Amazon's terms of use and
  void the warranty. noface doesn't jailbreak anything.
- It is tested on one Kindle, a Paperwhite 12th gen. On anything else, assume it won't
  work yet.
- It comes as is, with no warranty: see the license. Keep your own backups of anything
  you care about.

## Installing

noface runs from `/mnt/us/noface/` and opens from the home search bar with
`;kpm launch noface`.

1. `zig build` and copy `noface` and `jxr2pgm` from `zig-out/bin/` into `/mnt/us/noface/`.
2. Copy the scripts in `device/` there too, and `device/kpm/` into KPM's app folder.
3. To open noface when the Kindle starts, turn on Aa > More > "Open noface when the
   Kindle starts", and copy `device/noface-autostart.conf` into `/etc/upstart/` (with
   the root filesystem mounted read-write). Three failed starts in a row turn it off
   again by themselves. The Kindle button in the drag-down panel always returns to the
   stock home screen.

### Dictionaries

The Kindle's own dictionaries are DRM protected, so noface uses Wiktionary instead.
Build the files from the extracts at [kaikki.org](https://kaikki.org) and copy them next
to noface:

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
  check, and `tools/build_dictionary.py` builds the dictionaries.
- `third_party/`: stb libraries.

`zig build` builds the app, `zig build tools` the tools, `zig build test` runs unit tests,
`zig build check` checks ownership boundaries.

## License

noface is under the [PolyForm Noncommercial License 1.0.0](LICENSE.md). In short, and
the license itself is what counts:

- You may use it, change it and share it, for **noncommercial** purposes: personal use,
  hobby projects, study, research, and use by charities, schools and public bodies.
- You may not sell it, or use it in or for a commercial product or service.
- Anything you share must keep the license and its `Required Notice:` line.
- It comes with no warranty, and the author isn't liable for anything that happens
  from using it.

Contributions are welcome. By sending one, you agree it's licensed under the same terms.
The parts noface includes from others stay under their own licenses: see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The dictionaries are a separate
download under CC BY-SA 4.0.

"Kindle" is a trademark of Amazon.com, Inc. or its affiliates, used here only to say
which device noface runs on.

## Credits

- [stb](https://github.com/nothings/stb) for TrueType and pictures (public domain or MIT).
- Hyphenation patterns from the TeX hyphenation project, in `src/layout/hyphen/`:
  English by Gerard D.C. Kuiken (free to copy and change), Portuguese by Pedro J. de
  Rezende and others (BSD 3-clause). Their notices are in the `LICENSE-*` files there.
- Definitions from [Wiktionary](https://www.wiktionary.org), CC BY-SA 4.0, by way of
  [kaikki.org](https://kaikki.org). The dictionary files aren't in this repository.
- The tour above shows only public-domain books, in their Project Gutenberg editions:
  Austen, Doyle, Stoker, Wells and Carroll, with Hugh Thomson's 1894 illustrations
  for *Pride and Prejudice* and Arthur Rackham's 1907 ones for *Alice*. The definition
  shown is Wiktionary's (CC BY-SA 4.0).
