# noface

A fast reader for a jailbroken Kindle Paperwhite 12th gen, written in Zig.

Open it from the home search bar with `;kpm launch noface`.

## Layout

Code is split by who owns it. `zig build check` fails if a file imports across these lines.

- `src/kindle/`: everything that knows Amazon: the KFX format, lipc services, the
  store, annotation sync, the catalog export, fonts, the screen and input devices.
- `src/linux/`: Linux itself: files, processes with timeouts, time.
- `src/model/`: our data, with no I/O: books, settings, the library, highlights,
  bookmarks, search, reading stats.
- `src/gfx/`: pixels, fonts and pictures.
- `src/layout/`: setting a book's text into pages.
- `src/ui/`: drawing screens and mapping taps to controls.
- `src/screens/`: the flow of each screen. The only place that calls into `kindle/`.
- `src/app.zig`, `src/main.zig`: what screens share, and startup.
- `src/core.zig`: the parts the tools share. `src/tests.zig` runs every test.
- `device/`: scripts installed on the Kindle, and `jxr2pgm`, the picture helper that
  decodes JPEG XR with the Kindle's own library. Install both `noface` and `jxr2pgm`
  from `zig-out/bin` into `/mnt/us/noface/`.
- `tools/`: development tools, not part of the app. `tools/check/` holds the boundary check.
- `third_party/`: stb libraries.

`zig build` builds the app, `zig build tools` the tools, `zig build test` runs unit tests,
`zig build check` checks ownership boundaries.
