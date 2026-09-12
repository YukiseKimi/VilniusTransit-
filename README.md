# Vilnius Transit — spike

A macOS app showing Vilnius buses, trolleybuses and ferries moving live on a map.
Native frameworks only: MapKit, SwiftUI, AppKit, Foundation, Network, Core Animation.
**No third-party dependencies.**

```bash
swift test                  # 44 tests, no network
./Scripts/build-app.sh      # -> build/VilniusTransit.app
swift run feedcheck         # live feed diagnostic, no GUI
swift run feedcheck gtfs    # downloads the archive and reports the join
```

## What works

- ~385 vehicles polled every 5 s and drawn as route-numbered markers
- Markers **glide** between fixes instead of teleporting
- Joined to the static timetable: real route names, the city's own route colours,
  and the selected vehicle's actual path drawn from `shapes.txt`
- Fill colour = published route colour, outline = punctuality
- Sidebar with mode toggles, live per-route vehicle counts, route search
- Inspector showing the selected vehicle's speed, heading, schedule deviation, GTFS trip
- Menu bar extra with live fleet counts and fleet-wide on-time percentage
- Status bar reporting poll health, rows skipped, and how many polls returned 304

Measured on the full city view with all 383 vehicles and the timetable loaded:
**~8% CPU, ~267 MB**.

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

```
VilniusTransitKit      no UI, fully testable
  Vehicle              decoded row + punctuality bucketing
  VehicleFeedParser    byte-level CSV scan, never throws on a bad row
  VehicleFeedClient    actor; polls, replays If-Modified-Since, backs off, NWPathMonitor
  VehicleTrack         interpolation + teleport rejection
  FleetInterpolator    snapshot -> add/update/remove diff
  ZIPArchive           minimal ZIP reader on the Compression framework
  GTFSCSV              RFC 4180 reader (quotes, "" escapes, BOM, CRLF)
  GTFSCatalog          routes / trips / shapes / stops + the trip join
  GTFSStore            actor; download, disk cache, conditional refresh

VilniusTransitApp
  TransitMapView       NSViewRepresentable over MKMapView
  VehicleAnnotation    MKAnnotation + MKAnnotationView (appearance / motion split)
  MarkerImages         Core Graphics art, cached by appearance
  FleetModel           @Observable; owns data and filters
```

### Why MKMapView and not SwiftUI `Map`

SwiftUI's `Map` rebuilds its content tree on every change, offers no annotation view
reuse, and gives no way to move a marker from one coordinate to another. With 385
vehicles refreshing every few seconds that is the entire problem. `MKMapView` gives
view recycling, KVO-driven repositioning, and visible-rect culling. Everything
around the map stays SwiftUI.

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
not: **selective inflation**. `stop_times.txt` is 26 MB of the archive's 39 MB and
about a million rows, and a live map never reads it — it is only needed for per-stop
arrival predictions. Parsing the central directory means it is never decompressed at
all. The whole archive decodes in **0.28 s** into plain dictionaries, with no
database behind them.

The catalog costs about 55 MB resident. That is the deliberate trade for having no
storage layer to build, migrate or debug.

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

## Not done yet

- Stop annotations with `clusteringIdentifier` (1,553 stops are decoded already)
- Arrival predictions per stop, the one feature that needs `stop_times.txt`
- Sleep/wake handling via `NSWorkspace.notificationCenter`
- Favourites, `UserNotifications` proximity alerts, Swift Charts punctuality history

## Licence / etiquette

Transit data © Vilniaus miesto savivaldybė, republished via stops.lt. A 5 s poll is
~17k requests/day, so the client sends a descriptive User-Agent, replays
`If-Modified-Since`, and backs off exponentially on failure. Check the publisher's
terms before shipping this publicly.
