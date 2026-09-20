# Sklandus

*Sklandus* is Lithuanian for "smooth, flowing", from the same root as *sklandyti*,
to glide.

A Mac and iPad app showing Vilnius buses, trolleybuses and ferries moving live on a
map. macOS 26 / iPadOS 26, native frameworks only.

![Icon](design/icon/sklandus-icon-512.png)

**Status:** being built step by step. The project skeleton exists and both apps
launch; no features yet.

```bash
./Scripts/check.sh          # tests + both app builds + lint. Run before committing.
swift run --package-path SklandusCore feedcheck   # poll the live feed, no GUI
open Sklandus.xcodeproj     # Mac and iPad targets
```

## Layout

```
Sklandus.xcodeproj     Mac + iPad app targets (com.yukisekimi.sklandus)
Apps/Mac, Apps/iPad    one @main App each; everything else is shared
SklandusCore/          local Swift package
  SklandusKit          data and logic, no UI, tested from the command line
  SklandusUI           shared SwiftUI + MapKit
Config/                entitlements (network client only)
```

## Setup

SwiftLint must match Xcode's architecture. On Apple Silicon that means installing
it from the Homebrew in `/opt/homebrew`; a copy from an Intel Homebrew in
`/usr/local` cannot load Xcode's SourceKit and dies at launch. `Scripts/check.sh`
puts `/opt/homebrew/bin` first for this reason.

Signing is unset, which is fine for the simulator and local Mac builds. Running on
a physical iPad needs a development team in the iPad target's settings.

- [`docs/SPIKE-FINDINGS.md`](docs/SPIKE-FINDINGS.md): what the prototype proved about
  the data, the feeds, rendering and performance. Read this first.
- [`AGENTS.md`](AGENTS.md): coding conventions for this project.
- [`design/icon/`](design/icon/): the working app icon.
- The prototype itself is preserved at the `spike` tag: `git checkout spike`.
