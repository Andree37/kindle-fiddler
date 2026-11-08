# noface

A fast reader for a jailbroken Kindle Paperwhite 12th gen, written in Zig.

Open it from the home search bar with `;kpm launch noface`.

## Layout

- `src/main.zig`: starts the app: opens the screen, input and fonts.
- `src/app.zig`: what every screen shares: screen, input, fonts, settings, page buffers.
- `src/screens/`: one file per screen: library, reader (with its parts in `reader/`), panel, lock.
- `src/platform/`: talks to the Kindle: screen, touch, power and system services, files.
- `src/book/`: reads and lays out books, highlights and their sync records. No hardware.
- `src/ui/`: draws screens and maps taps to controls.
- `src/core.zig`: the parts the tools share. `src/tests.zig` runs every test.
- `device/`: scripts installed on the Kindle.
- `tools/`: development tools, not part of the app.
- `third_party/`: stb libraries.

`zig build` builds the app, `zig build tools` the tools, `zig build test` runs unit tests.
