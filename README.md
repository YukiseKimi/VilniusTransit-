# Vilnius Transit — spike

A Mac and iPad app showing Vilnius buses, trolleybuses and ferries moving live on a
map. Native frameworks only: MapKit, SwiftUI, Foundation, Network, Core Graphics,
Core Animation, Core Text, Compression. **No third-party dependencies.**

```bash
swift test                  # 55 tests, no network
./Scripts/check-ipad.sh     # type-checks the shared targets for iPadOS
./Scripts/build-app.sh      # Mac -> build/VilniusTransit.app
swift run feedcheck         # live feed diagnostic, no GUI
swift run feedcheck gtfs    # downloads the archive and reports the join

# iPad — SwiftPM cannot emit an iOS app bundle, so this is a real Xcode project
# that references the package locally.
open iPad/VilniusTransitPad.xcodeproj
```

Both apps run the same `VilniusTransitUI` code. The iPad app target is 20 lines and
the Mac one is 44; if either grows much, something that should have been shared
was not.

## What works

- ~385 vehicles polled every 5 s and drawn as route-numbered markers
- Markers **glide** between fixes instead of teleporting
- Joined to the static timetable: real route names, the city's own route colours,
  and the selected vehicle's actual path drawn from `shapes.txt`
- Selecting a vehicle also shows **the stops it will call at**, in order, with the
  ordered list in the inspector
- Fill colour = published route colour, outline = punctuality
- Sidebar with mode toggles, live per-route vehicle counts, route search
- Inspector showing the selected vehicle's speed, heading, schedule deviation, GTFS trip
- Menu bar extra with live fleet counts and fleet-wide on-time percentage
- Status bar reporting poll health, rows skipped, and how many polls returned 304

Measured on a Mac, full city view, all 383 vehicles and the timetable loaded:
**~12% CPU, ~230 MB**.

The iPad build runs and joins correctly in the simulator (384 vehicles, 375 joined),
but **simulator numbers are not device numbers** — it executes on Mac hardware with
different memory accounting and no thermal limit. Treat iPad performance as
unmeasured until it runs on real hardware.

## Data

| | |
|---|---|
| Live feed | `https://stops.lt/vilnius/gps_full.txt` — CSV, 17 columns, ~47 KB |
| Static GTFS | `https://www.stops.lt/vilnius/vilnius/gtfs.zip` — 4.2 MB |
| Publisher | [github.com/vilnius/transportas](https://github.com/vilnius/transportas) |

There is **no GTFS-RT protobuf feed**, which is why this needs no dependencies.

The join between them is `ReisoIdGTFS` -> `trips.trip_id`. Measured against a live
poll: **375 of 379** in-service vehicles resolve to a timetable trip, and all 375 of
those have a route shape. Route labels agree perfectly — zero disagreements between
what the feed calls a route and what `routes.txt` does.

The ~1% that never join are **driver-break and layover movements** — headsigns like
"Pietūs Antakalnio žiede" (lunch at the Antakalnis loop) with direction codes (`ac`,
`a1a`, `aa1`) that do not appear in passenger GTFS. They are shown using the feed's
own labels, without a shape or published colour.

Feed quirks the code already handles, each verified against live data:

- Coordinates are integers scaled by 1e6 (`25292878` → `25.292878` E)
- Longitude comes *before* latitude
- `MatavimoLaikas` is seconds since local midnight in **Europe/Vilnius**, and can
  exceed 86400 because GTFS service days run past midnight
- Empty fields are meaningful: a vehicle between runs has no trip ID and no
  schedule deviation. Absent is not zero — "not scheduled" is not "on time"
- Every row carries a trailing comma; GTFS files (but not the live feed) have a BOM
- `route_type` for trolleybuses is the extended-GTFS **800**, not 11
- `route_color` encodes **service class, not route**: one blue for 82 regular bus
  routes, red for trolleybuses, black for the 9 night routes, green for the express
  "G" routes, teal for the ferry. Useless for telling routes apart, genuinely useful
  for telling service types apart — which our own palette had no way to know
- The live feed has no quoting at all; the GTFS files really do. `stops.txt` carries
  both embedded commas and `""`-escaped quotes, so the two get separate parsers

## Architecture

Three targets. The split is by platform reach, not by layer: everything that can be
shared is, and the Mac-only target is deliberately tiny.

```
VilniusTransitKit      no UI, fully testable, Mac + iPad
  Vehicle              decoded row + punctuality bucketing
  VehicleFeedParser    byte-level CSV scan, never throws on a bad row
  VehicleFeedClient    actor; polls, replays If-Modified-Since, backs off, NWPathMonitor
  VehicleTrack         interpolation + teleport rejection
  FleetInterpolator    snapshot -> add/update/remove diff
  ZIPArchive           minimal ZIP reader on the Compression framework
  GTFSCSV              RFC 4180 reader (quotes, "" escapes, BOM, CRLF)
  GTFSCatalog          routes / trips / shapes / stops + the trip join
  GTFSStore            actor; download, disk cache, conditional refresh

VilniusTransitUI       all the app, Mac + iPad
  FleetModel           @Observable; owns data and filters
  TransitMapView       NS/UIViewRepresentable over MKMapView, one shared Coordinator
  VehicleAnnotation    MKAnnotation + MKAnnotationView (appearance / motion split)
  StationAnnotation    stops on the selected vehicle's route
  MarkerImages         Core Graphics art -> CGImage, cached by appearance
  ContentView, SidebarView, VehicleInspector, StatusBar   one screen per file
  Platform             every platform difference in this target, in one file

VilniusTransitApp      Mac only — 60 lines
  @main App + MenuBarExtra
```

### What is actually platform-specific

Verified by type-checking both shared targets against the iOS SDK
(`Scripts/check-ipad.sh`), not by inspection. The entire divergence is:

| | |
|---|---|
| Representable | `makeNSView` / `makeUIView` — three lines each, same body |
| Polyline colour | `MKPolylineRenderer.strokeColor` is typed `NSColor`/`UIColor` |
| `MKAnnotationView.layer` | optional on `NSView`, not on `UIView` |
| Zoom controls | Mac shows buttons; iPad pinches |
| Toggle style | checkbox on Mac, switch on iPad |
| Search placement | `.sidebar` on Mac |
| Hit targets | 24 pt for a cursor, 44 pt for a fingertip |

UIKit is kept to what MapKit's own API forces: the representable wrapper and one
colour property. The bold font comes from Core Text
(`CTFontCreateUIFontForLanguage(.emphasizedSystem, …)`) and the display scale from
SwiftUI's environment, so neither needs `UIFont`/`UIScreen` or their AppKit twins.

Marker art is rendered straight to `CGImage` rather than through `NSImage` or
`UIImage`. That is not a portability workaround: `CALayer.contents` wants a
`CGImage` on both platforms anyway, so the platform image type was always a detour.
Removing it took AppKit out of the drawing layer entirely and dropped resident
memory by ~40 MB.

### Why MKMapView and not SwiftUI `Map`

SwiftUI's `Map` rebuilds its content tree on every change, offers no annotation view
reuse, and gives no way to move a marker from one coordinate to another. With 385
vehicles refreshing every few seconds that is the entire problem. `MKMapView` gives
view recycling, KVO-driven repositioning, and visible-rect culling. Everything
around the map stays SwiftUI, and the `Coordinator` holding the diffing,
interpolation, culling and overlay logic is identical on Mac and iPad.

### Three things that cost real CPU, and what fixed them

1. **Rebuilding marker artwork per frame.** Every distinct badge is drawn once with
   Core Graphics and cached. 383 vehicles share ~120 badges.
2. **Recomputing appearance per frame.** Appearance (route, mode, punctuality) only
   changes when a poll lands, so it is split from the 20 fps motion path. Leaving
   these joined cost 53% CPU, largely in reflection-based enum interpolation for a
   cache key that almost never changed.
3. **Moving markers by less than a pixel.** Each move is a KVO round trip through
   MapKit. Sub-half-point moves are skipped, which silences most of the fleet when
   zoomed out and changes nothing when zoomed in.
4. **O(n) computed properties read during rendering.** `filteredVehicles`,
   `routeSummaries` and `joinedCount` each walked all 383 vehicles, and SwiftUI
   re-evaluates a computed property on every body pass. They are now recomputed once
   per snapshot or filter change. Adding the timetable had pushed CPU back to ~20%
   and memory to ~390 MB purely through this churn.

Together: 53% CPU → ~8%.

### Why a hand-written ZIP reader

Foundation has no unzip API and the obvious packages are third-party. The format is
simple enough to read directly, and doing so buys something a convenience API would
not: **selective inflation**. `calendar_dates.txt`, `calendar.txt`, `agency.txt`,
`areas.txt` and `stop_areas.txt` are never decompressed at all — parsing the central
directory means we choose what to inflate.

The archive decodes in **0.75 s** into plain dictionaries, with no database behind
them. About 0.45 s of that is the `stop_times.txt` scan, which is CSV parsing rather
than allocation: hashing trip ids from raw bytes instead of building a `String` for
each of the 504k rows left decode time unchanged, but cut steady-state memory by
roughly 90 MB.

### Why stops are only shown for the selected vehicle

Drawing every stop was measured before it was built, and it does not work: **990 of
the 1,553 stops fall inside the app's default viewport**, outnumbering vehicles 2.6
to 1. At that zoom (14 m per point) the median nearest-neighbour distance is 76 m,
so roughly **900 of those 990 would overlap a neighbour**. Vilnius also lists each
direction as its own stop — 1,424 of 1,553 share a name with another, typically a
pair 26 m apart across a road — so a raw rendering is largely twin dots.

Scoping stops to the selected vehicle's trip gives 20–40 instead of 990, every one
of them meaningful: this vehicle will call there. It also removes the need for a
zoom threshold, clustering, and a visibility toggle.

Two pieces of the timetable make it work:

- **Stations.** Same-named stops within 150 m are merged into one place, collapsing
  1,553 stops into 845 stations. 150 m comfortably covers a pair either side of a
  road (median spread 78 m) without merging same-named stops a real walk apart.
- **`stop_times.txt`, collapsed.** The file is 26 MB and 504k rows and is the one
  thing a live map would otherwise never read. It is reduced during decode to a
  single ordered station list per `shape_id` — 945 lists rather than 25k trips —
  and everything else is discarded as it streams past. Only one representative trip
  per shape is read, chosen as the lowest-sorting trip id so the result is
  reproducible; taking whichever came first out of an unordered dictionary made the
  same archive decode differently between runs.

### Interpolation

Markers interpolate *between two known fixes* rather than dead-reckoning forward
from speed and heading. Dead reckoning overshoots corners and drives buses through
buildings; this trails reality by about one poll interval and never places a vehicle
somewhere it was not.

Plausibility is judged against the **vehicle's own clock** (`MatavimoLaikas`), not
wall-clock time between polls. This matters: only ~75% of vehicles refresh their fix
on any given 5 s poll. Bus 564 on route 120 was observed sitting stale at a terminus
for 199 s, then reappearing 811 m away having turned around. Wall-clock arithmetic
calls that 584 km/h and rejects it; its own clock calls it 15 km/h. It is real
movement — but since the path was never observed, the marker is *placed* there
rather than flown across the gap.

### Measured feed behaviour

Sampled 7 polls at 5 s intervals:

- 286 of 383 vehicles produced a new fix on every poll; 2 produced only one in 30 s
- 51–65% of vehicles changed position between consecutive polls
- Median move per 5 s: 24–36 m. Median displacement over 30 s: 100 m

So a 5 s poll is justified by the data rather than guessed at, and the 5 s glide
matches the interval.

## Known risks for iPad

None of these are ports; they are decisions that differ by platform.

- **Every performance number here is a Mac number.** The 20 fps tick driving ~250
  KVO-backed annotation moves is exactly the shape of thing that costs battery.
  The simulator cannot answer this; measure on real hardware before believing it.
- **Background execution.** macOS polls while the window is open; iPadOS suspends
  the app. A proximity alert cannot be a local timer there — it needs server push.
- **Cellular.** 47 KB every 5 s is ~34 MB/hour, and the GTFS archive is another
  4 MB. `NWPathMonitor` is already wired in; `isConstrained` / `isExpensive` should
  drive the poll interval and gate the first download.
- **Memory.** ~230 MB resident is comfortable on a Mac and on an iPad. It would not
  be on an iPhone, which is the main reason iPhone is out of scope: the "plain
  dictionaries, no database" decision only survives with that headroom.

## Not done yet

- Arrival predictions per stop — needs the timings from `stop_times.txt` that the
  decode currently discards
- Highlighting which stop the selected vehicle is approaching next
- Sleep/wake handling via `NSWorkspace.notificationCenter`
- Favourites, `UserNotifications` proximity alerts, Swift Charts punctuality history

## Licence / etiquette

Transit data © Vilniaus miesto savivaldybė, republished via stops.lt. A 5 s poll is
~17k requests/day, so the client sends a descriptive User-Agent, replays
`If-Modified-Since`, and backs off exponentially on failure. Check the publisher's
terms before shipping this publicly.
