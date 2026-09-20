#!/usr/bin/env python3
"""Regenerates gtfs_sample.zip.

Built with Python's zipfile rather than our own code, so the ZIP reader is
validated against an independent producer. Every awkward feature the real Vilnius
archive contains is reproduced deliberately: a UTF-8 BOM, quoted fields holding
commas and doubled-quote escapes, shape points out of sequence order, CRLF line
endings, a STORED (uncompressed) entry, and a large file that must never be
inflated.
"""
import os, zipfile

here = os.path.dirname(os.path.abspath(__file__))
BOM = "﻿"

routes = BOM + """route_id,agency_id,route_short_name,route_long_name,route_desc,route_type,route_url,route_color,route_text_color,route_sort_order
vilnius_bus_7,vilnius,"7","Stotis-Šiaurės miestelis",,3,,0073AC,FFFFFF,1
vilnius_trolley_2,vilnius,"2","Centras-Žirmūnai",,800,,DC3131,FFFFFF,2
vilnius_ferry_L1,vilnius,"L1","Žirmūnų paplūdimys-Verslo trikampis",,4,,00A59B,FFFFFF,3
vilnius_night_N1,vilnius,"N1","Centras-Antakalnis",,3,,000000,FFFFFF,4
"""

# CRLF throughout, and one trip with no shape_id at all.
trips = BOM + "route_id,service_id,trip_id,trip_headsign,direction_id,block_id,shape_id\r\n" + "\r\n".join([
    'vilnius_bus_7,1,A7-01-6-260901-ba-1300,"Šiaurės miestelis",0,blk1,shape_7_ba',
    'vilnius_bus_7,1,A7-02-6-260901-ba-1400,"Šiaurės miestelis",0,blk5,shape_7_ba',
    'vilnius_trolley_2,1,T2-13-6-260907-ba-1320,"Žirmūnai",1,blk2,shape_2_ba',
    'vilnius_ferry_L1,1,AL1-01-1-260901-ab-0820,"Verslo trikampis",0,blk3,',
    'vilnius_night_N1,1,N1-01-6-260901-ab-0030,"Antakalnis",0,blk4,shape_7_ba',
]) + "\r\n"

# Sequence 1,2,3 deliberately shuffled in file order.
shapes = BOM + """shape_id,shape_pt_lat,shape_pt_lon,shape_pt_sequence,shape_dist_traveled
shape_7_ba,54.6900,25.2800,3,
shape_7_ba,54.6872,25.2797,1,
shape_7_ba,54.6885,25.2799,2,
shape_2_ba,54.7000,25.3000,2,
shape_2_ba,54.6950,25.2900,1,
"""

# stop_desc carries an embedded comma on one row and doubled-quote escapes on another.
stops = BOM + '''stop_id,stop_code,stop_name,stop_desc,stop_lat,stop_lon,stop_url,location_type,parent_station,platform_code
9483,,"1-asis Lentvaris","iš miesto",54.64437,25.06552,,,,
18327,,"Broniaus Laurinavičiaus skveras","",54.70223,25.28355,,,,
16291,,"Geležinio Vilko st.","visos kryptys, troleibusai",54.75762,25.27183,,,,
16292,,"Kalvarijų","""D"" stotelė",54.70000,25.28000,,,,
16293,,"Kalvarijų","priešinga kryptis",54.70018,25.28004,,,,
16294,,"Kalvarijų","kitas rajonas",54.79000,25.40000,,,,
'''

# Real calls for the two shaped trips, deliberately out of sequence order, then
# padding from a trip that shares shape_7_ba so the "one representative trip per
# shape" rule is exercised rather than assumed.
stop_times = "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n" + "".join([
    "A7-01-6-260901-ba-1300,13:10:00,13:10:00,16291,3\n",
    "A7-01-6-260901-ba-1300,13:00:00,13:00:00,9483,1\n",
    "A7-01-6-260901-ba-1300,13:05:00,13:05:00,16292,2\n",
    # Same station as sequence 2, reached again on the loop back.
    "A7-01-6-260901-ba-1300,13:20:00,13:20:00,16293,4\n",
    "T2-13-6-260907-ba-1320,14:00:00,14:00:00,18327,1\n",
    "T2-13-6-260907-ba-1320,14:06:00,14:06:00,16294,2\n",
]) + "".join(
    # Padding under trips that are NOT the representative for their shape, so the
    # "read one trip per shape" rule is exercised rather than assumed. If these
    # were ever read, the stop lists below would be wrong.
    f"{tid},00:{m//60:02d}:{m%60:02d},00:{m//60:02d}:{m%60:02d},9483,{m}\n"
    for tid in ("N1-01-6-260901-ab-0030", "A7-02-6-260901-ba-1400")
    for m in range(2000)
)

path = os.path.join(here, "gtfs_sample.zip")
with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("routes.txt", routes)
    z.writestr("trips.txt", trips)
    z.writestr("shapes.txt", shapes)
    z.writestr("stop_times.txt", stop_times)
    # STORED exercises the uncompressed branch of the reader.
    z.writestr(zipfile.ZipInfo("stops.txt"), stops, compress_type=zipfile.ZIP_STORED)
    z.writestr("agency.txt", "agency_id,agency_name\nvilnius,Vilnius\n")

print(f"wrote {path} ({os.path.getsize(path)} bytes)")
with zipfile.ZipFile(path) as z:
    for i in z.infolist():
        print(f"  {i.filename:16} {i.file_size:7d} -> {i.compress_size:6d}  method={i.compress_type}")
