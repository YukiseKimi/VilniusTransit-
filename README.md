# Vilnius Transit — spike

A macOS app showing Vilnius buses, trolleybuses and ferries moving live on a map.
Native frameworks only: MapKit, SwiftUI, AppKit, Foundation, Network, Core Animation.
**No third-party dependencies.**

```bash
swift test                  # 24 tests, no network
./Scripts/build-app.sh      # -> build/VilniusTransit.app
swift run feedcheck         # live feed diagnostic, no GUI
```

## What works

- ~385 vehicles polled every 5 s and drawn as route-numbered markers
- Markers **glide** between fixes instead of teleporting
- Fill colour = mode (bus / trolleybus / ferry), outline = punctuality
- Sidebar with mode toggles, live per-route vehicle counts, route search
- Inspector showing the selected vehicle's speed, heading, schedule deviation, GTFS trip
- Menu bar extra with live fleet counts and fleet-wide on-time percentage
- Status bar reporting poll health, rows skipped, and how many polls returned 304

Measured on the full city view with all 383 vehicles: **~9% CPU, ~210 MB**.

## Data

| | |
|---|---|
| Live feed | `https://stops.lt/vilnius/gps_full.txt` — CSV, 17 columns, ~47 KB |
| Static GTFS | `https://www.stops.lt/vilnius/vilnius/gtfs.zip` — 4.2 MB |
| Publisher | [github.com/vilnius/transportas](https://github.com/vilnius/transportas) |

There is **no GTFS-RT protobuf feed**, which is why this needs no dependencies.

Feed quirks the code already handles, each verified against live data:

- Coordinates are integers scaled by 1e6 (`25292878` → `25.292878` E)
- Longitude comes *before* latitude
- `MatavimoLaikas` is seconds since local midnight in **Europe/Vilnius**, and can
  exceed 86400 because GTFS service days run past midnight
- Empty fields are meaningful: a vehicle between runs has no trip ID and no
  schedule deviation. Absent is not zero — "not scheduled" is not "on time"
- Every row carries a trailing comma; GTFS files (but not the live feed) have a BOM
- `route_type` for trolleybuses is the extended-GTFS **800**, not 11

## Architecture

```
VilniusTransitKit      no UI, fully testable
  Vehicle              decoded row + punctuality bucketing
  VehicleFeedParser    byte-level CSV scan, never throws on a bad row
  VehicleFeedClient    actor; polls, replays If-Modified-Since, backs off, NWPathMonitor
  VehicleTrack         interpolation + teleport rejection
  FleetInterpolator    snapshot -> add/update/remove diff

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

Together: 53% CPU → ~9%.

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

- **GTFS static import.** The linchpin is that `ReisoIdGTFS` joins exactly to
  `trips.trip_id` (verified). That unlocks route polylines via `shape_id`, official
  route colours, and proper long names. `stop_times.txt` (27 MB, ~1M rows) is only
  needed for per-stop arrival predictions — skip it until then.
- Stop annotations with `clusteringIdentifier`
- Sleep/wake handling via `NSWorkspace.notificationCenter`
- Favourites, `UserNotifications` proximity alerts, Swift Charts punctuality history

## Licence / etiquette

Transit data © Vilniaus miesto savivaldybė, republished via stops.lt. A 5 s poll is
~17k requests/day, so the client sends a descriptive User-Agent, replays
`If-Modified-Since`, and backs off exponentially on failure. Check the publisher's
terms before shipping this publicly.
