# noface

A fast reader for a jailbroken Kindle Paperwhite 12th gen, written in Zig.

Open it from the home search bar with `;kpm launch noface`.

## Layout

- `src/`: the app. Entry point is `src/noface.zig`.
- `device/`: scripts installed on the Kindle.
- `tools/`: development tools, not part of the app.
- `third_party/`: stb libraries.

`zig build` builds the app, `zig build tools` the tools, `zig build test` runs unit tests.
