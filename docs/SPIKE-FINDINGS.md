# Spike findings

What the prototype proved, measured between 2026-09-12 and 2026-09-19. The code is
preserved at the `spike` tag (`git checkout spike`); this document is what carries
forward into the real app.

Every number here was measured against the live services, not estimated. Where a
number came from a Mac or the iPad simulator rather than a device, it says so.

---

## 1. Data sources

| | Live vehicles | Static timetable |
|---|---|---|
| URL | `https://stops.lt/vilnius/gps_full.txt` | `https://www.stops.lt/vilnius/vilnius/gtfs.zip` |
| Format | Flat CSV, one row per vehicle | GTFS zip |
| Size | ~47 KB, ~15.5 KB gzipped | 3.7–4.2 MB zipped, ~36–39 MB unpacked |
| Freshness | `Last-Modified` seconds old on every check | Rebuilt when schedules change (seen 11 Sep and 19 Sep) |
| Conditional GET | `If-Modified-Since` → 304 works | `If-Modified-Since` / `ETag` → 304 works |
| Host | Cloudflare | Cloudflare |

- There is **no GTFS-RT protobuf feed**. That is why the spike needed no third-party
  dependencies at all.
- The only publisher reference found is <https://github.com/vilnius/transportas>.
  **No terms of use were found.** Check before shipping publicly.

### Fleet size

| When | Total | Bus | Trolleybus | Ferry | In service |
|---|---|---|---|---|---|
| Daytime, 12 Sep | 383–385 | 274–276 | 104–105 | 4 | ~379 |
| Midnight, 19 Sep | 300 | 238 | 58 | 4 | 120 |

At night most of the fleet is heading to depots with no trip. Anything that reports
a ratio must use **in-service** vehicles as the denominator: an all-vehicle ratio read
"119/300 joined" and looked like a regression when it was really 112/116.

---

## 2. Live feed format

17 columns plus a trailing comma. **No quoting, no escaping, no BOM.** 385 of 385 rows
had exactly 18 comma-separated fields.

| # | Column | Meaning | Notes |
|---|---|---|---|
| 0 | `Transportas` | Mode | `Autobusai`, `Troleibusai`, `Laivai` |
| 1 | `Marsrutas` | Route short name | `7`, `3G`, `N2`, `3G-A` |
| 3 | `MasinosNumeris` | Fleet number | Stable across polls; the identity to animate |
| 4 | `Ilguma` | **Longitude** × 10⁶ | Comes *before* latitude |
| 5 | `Platuma` | Latitude × 10⁶ | `54720649` → 54.720649 |
| 6 | `Greitis` | Speed, km/h | |
| 7 | `Azimutas` | Heading, ° clockwise from north | Stale when stationary |
| 9 | `NuokrypisSekundemis` | Schedule deviation, s | + late / − early; **empty = not scheduled** |
| 10 | `MatavimoLaikas` | Fix time | Seconds since midnight **Europe/Vilnius**; can exceed 86400 |
| 11 | `MasinosTipas` | Vehicle attribute code | `KWZ`, `KWNZD`… **undocumented**, kept opaque |
| 12 | `KryptiesTipas` | Direction code | `A>B`, `B>A`, `B1>A`… |
| 13 | `KryptiesPavadinimas` | Headsign | Lithuanian, UTF-8 |
| 14 | `ReisoIdGTFS` | GTFS `trip_id` | **The join key.** Empty when not on a trip |

An empty field is not the same as zero. A vehicle with an empty deviation is "not
scheduled", not "on time".

---

## 3. Timetable (GTFS) quirks

- **Every file starts with a UTF-8 BOM.** Without stripping it, `route_id` never
  matches.
- **`stops.txt` really does quote.** It contains embedded commas (`"visos kryptys,
  troleibusai"`) and doubled-quote escapes (`"""D"" stotelė"`). The live feed and the
  GTFS files need **separate parsers**, and using the wrong one gives silently wrong
  data rather than an error.
- **`route_type` for trolleybuses is 800** (extended GTFS), not 11.
- **`route_color` encodes service class, not route.** It can't tell routes apart,
  but it can tell service types apart:

  | Colour | Routes | Service |
  |---|---|---|
  | `#0073AC` | 82 | Regular bus |
  | `#DC3131` | 16 | Trolleybus |
  | `#000000` | 9 (N1–N9) | Night bus |
  | `#008000` | 7 (1G–6G, 3G-A) | Express |
  | `#00A59B` | 1 (L1) | Ferry |

- **Shape points are not guaranteed to be in sequence order.** Sort by
  `shape_pt_sequence` or the polyline zigzags.
- **Each direction is a separate stop.** 1,424 of 1,553 stops share a name with
  another, usually a pair ~26 m apart across a road. `stop_areas.txt` groups only 81
  stops, so it doesn't solve this.
- **Trip IDs embed a schedule version** (`…-260901-…`). One archive holds several
  versions, including future ones.
- File sizes (11 Sep archive): `stop_times.txt` 26 MB / 504k rows, `shapes.txt` 7.3 MB
  / 170k points over 945 shapes, `trips.txt` 4.2 MB / 25k trips, `stops.txt` 165 KB.

---

## 4. The join

`ReisoIdGTFS` (live) = `trips.trip_id` (static). From there: `route_id` gives the
name and colour, `shape_id` gives the path, and `stop_times` gives the stops.

| When | In service | Joined | Rate |
|---|---|---|---|
| Daytime, 12 Sep | 379 | 375 | 99% |
| Midnight, 19 Sep | 120 | 116 | 97% |

- Route labels in the feed and in `routes.txt` agree exactly: **zero disagreements**.
- **The ~1–3% that never join are operational movements** (driver breaks, layovers,
  depot runs). They carry GTFS-shaped trip IDs that aren't in the published
  timetable. Headsigns look like *"Pietūs Antakalnio žiede"* (lunch at the Antakalnis
  loop), with direction codes `ac`, `a1a`, `aa1`, `xd`, `da`. **Fall back to the feed's
  own labels; never hide these vehicles.**

---

## 5. Vehicle motion

### Feed cadence (7 polls, 5 s apart)

- 286 of 383 vehicles had a new fix on **every** poll; 2 had only one fix in 30 s.
- 51–65% of vehicles changed position between consecutive polls.
- Median move per 5 s: 24–36 m. Median displacement over 30 s: 100 m.

**Polling every 5 s is justified by the data.** Slower loses real movement; faster
mostly re-reads identical positions.

### How to animate

- **Interpolate between two known fixes; don't dead-reckon.** Projecting forward from
  speed and heading overshoots corners and drives buses through buildings.
  Interpolation lags reality by about one poll and never shows a vehicle somewhere it
  wasn't.
- **Judge plausibility against the vehicle's own clock (`MatavimoLaikas`), not the
  time between polls.** Bus 564 on route 120 sat stale at a terminus for 199 s, then
  appeared 811 m away having turned around. Measured by poll timing that is 584 km/h;
  by its own clock it is 15 km/h. It's real movement.
- **If a fix is more than 30 s stale, place the marker instead of animating it.** The
  path wasn't observed, so animating would invent one.
- Anything over 150 km/h measured against the vehicle's clock is noise: snap it.
- A vehicle turning round at a terminus keeps its fleet number but **starts a new
  trip**, so its route, colour and stops must be looked up again.

---

## 6. Rendering and performance (Mac)

**Use `MKMapView`, not SwiftUI's `Map`.** With ~385 vehicles moving every few seconds,
`Map` rebuilds its content on every change, can't reuse annotation views, and can't
move a marker from one coordinate to another.

Performance went from **53% CPU / 550 MB** to **~12% CPU / ~230 MB** with every vehicle
on screen. The causes, in order of cost:

1. **Recomputing marker appearance every frame.** A string cache key built with
   reflection-based enum interpolation, 7,660 times a second, only to find nothing had
   changed. Fix: split appearance (changes per poll) from motion (changes per frame).
2. **O(n) computed properties read during rendering.** SwiftUI re-evaluates them on
   every body pass. Fix: recompute once per snapshot or filter change.
3. **Moving markers by less than a pixel.** Each move costs a KVO round trip through
   MapKit. Fix: skip moves under half a point on screen.
4. **Re-rendering marker art.** Fix: draw each distinct marker once and cache it.
   Render directly to `CGImage`; `CALayer.contents` takes one on both platforms, so
   `NSImage`/`UIImage` was always a detour. That also saved ~40 MB.

### Timetable decode

- 0.29 s for routes, trips, shapes and stops; **0.75 s** once `stop_times` is included.
- The `stop_times` cost is CSV scanning, not allocation. Hashing trip IDs from raw
  bytes left the time unchanged but **cut ~90 MB of memory**.
- Plain dictionaries with **no database** were enough on Mac and iPad. The catalog
  costs ~55 MB resident.
- A minimal ZIP reader built on `Compression` lets the app decompress only the files
  it needs.

### Not measured

- **iPad device performance is unknown.** The simulator reported 396–479 MB, but it
  runs on Mac hardware with different memory accounting and no thermal limits. The
  20 fps animation tick moving ~250 markers is the most likely battery cost.

---

## 7. Stops

**Don't draw every stop.** Measured before building:

- 990 of the 1,553 stops fall inside the default city-wide viewport, 2.6× the number
  of vehicles.
- At that zoom (14 m per point) the median distance between neighbouring stops is
  76 m, so **~900 of the 990 would overlap**.

**Show only the selected vehicle's stops.** That's 13–40 stops, and each one means
something: this vehicle will call there. It also removes any need for a zoom
threshold, clustering or a show/hide toggle.

- **Stations:** same-named stops within 150 m merge into one station, reducing 1,553
  stops to 845. The median spread of a pair is 78 m.
- **Stop order:** reduce `stop_times` to one ordered station list per `shape_id` (945
  lists instead of 25k trips) and discard the rest while streaming.
- **Pick the representative trip deterministically** (the lowest-sorting trip ID).
  Taking whichever trip came out of an unordered dictionary first made the same
  archive decode differently between runs.

---

## 8. Platforms

- **Mac and iPad only; no iPhone.** The "no database" decision relies on Mac/iPad
  memory headroom. `TARGETED_DEVICE_FAMILY = 2` enforces iPad-only at build time.
- **iOS 26 / macOS 26**, per `AGENTS.md`.
- **UIKit kept to what MapKit forces:** the `UIViewRepresentable` wrapper and one
  `strokeColor` line. The bold font comes from Core Text and the display scale from
  SwiftUI's environment.
- The whole difference between Mac and iPad came down to: `make(NS|UI)View`,
  `MKAnnotationView.layer` being optional on `NSView`, zoom controls, toggle style,
  search placement, hit-target size (24 pt vs 44 pt) and "Click" vs "Tap" in on-screen
  text.
- SwiftPM can't build an iOS app bundle. The iPad app needs a real Xcode project that
  references the package.

---

## 9. Open questions for the real app

| Question | Why it's open |
|---|---|
| Device performance and battery | Never measured on hardware |
| Keep the dictionaries or add storage? | Fine on Mac; unconfirmed on a real iPad |
| Background and cellular behaviour | iPadOS suspends apps; 5 s polling is ~34 MB/hour |
| Proximity alerts ("bus is 2 stops away") | Need a server to push them; a local timer won't run in the background |
| Next-stop highlighting | Needs the vehicle's position projected onto its route line |
| Arrival predictions | Needs the `stop_times` timings the spike discarded |
| What `MasinosTipas` means | Undocumented; likely accessibility or amenity flags |
| Data licence and attribution | No terms found |

---

## 10. Finding the spike code

`git checkout spike`, then:

| Topic | File |
|---|---|
| Live feed parsing | `Sources/VilniusTransitKit/VehicleFeedParser.swift` |
| Polling, 304s, backoff | `Sources/VilniusTransitKit/VehicleFeedClient.swift` |
| Interpolation, plausibility checks | `Sources/VilniusTransitKit/VehicleTrack.swift` |
| ZIP reader | `Sources/VilniusTransitKit/ZIPArchive.swift` |
| GTFS CSV | `Sources/VilniusTransitKit/GTFSCSV.swift` |
| Stations, stop lists | `Sources/VilniusTransitKit/GTFSDecoder.swift` |
| Map, diffing, culling | `Sources/VilniusTransitUI/TransitMapView.swift` |
| Marker rendering | `Sources/VilniusTransitUI/MarkerImages.swift` |
| Mac/iPad differences | `Sources/VilniusTransitUI/Platform.swift` |
| Live diagnostics | `swift run feedcheck` / `swift run feedcheck gtfs` |
| Test fixtures | `Tests/VilniusTransitKitTests/Fixtures/` |
