"""Build the hexagon grid and measure city-layout features for every hexagon
and every station, then save them to the database.

Downloads OpenStreetMap data once (cached in data/raw/osm). Safe to re-run.

Run from the Backend folder:
    .venv/bin/python -m scripts.build_grid_features
"""

import json

import geopandas as gpd
import pandas as pd
from shapely.geometry import Point

from northstar.db.connection import connect
from northstar.model.features import METRIC_CRS, compute_features, download_osm
from northstar.model.grid import app_area, build_cells


def main() -> None:
    area = app_area()
    cells = build_cells(area)
    # Name the city each hexagon is in.
    named = gpd.sjoin(cells, area, predicate="within", how="left")
    cells["area_name"] = named.groupby(level=0).name.first()
    print(f"{len(cells):,} hexagons")

    with connect() as conn:
        stations = pd.DataFrame(
            conn.execute(
                "select station_id, ST_Y(location::geometry) as latitude, ST_X(location::geometry) as longitude "
                "from stations order by station_id"
            ).fetchall(),
            columns=["station_id", "latitude", "longitude"],
        )
    stations = gpd.GeoDataFrame(
        stations, geometry=[Point(x, y) for x, y in zip(stations.longitude, stations.latitude)], crs=4326
    )

    # Download OpenStreetMap for the map area plus every station, with 1.5 km
    # spare around the edges so circles at the boundary are measured fully.
    download_area = pd.concat([area.geometry, stations.geometry]).to_crs(METRIC_CRS).buffer(1500).union_all()
    download_area = gpd.GeoSeries([download_area], crs=METRIC_CRS).to_crs(4326).iloc[0]
    print("Downloading OpenStreetMap data (first run takes several minutes)...")
    osm = download_osm(download_area)
    print({name: len(table) for name, table in osm.items()})

    print("Measuring features for stations and hexagons...")
    station_features = compute_features(stations, osm)
    cell_features = compute_features(cells, osm)

    with connect() as conn:
        for station_id, (_, row) in zip(stations.station_id, station_features.iterrows()):
            conn.execute(
                "insert into station_features (station_id, features) values (%s, %s) "
                "on conflict (station_id) do update set features = excluded.features",
                (int(station_id), json.dumps(row.round(4).to_dict())),
            )
        with conn.cursor() as cursor:
            cursor.executemany(
                """
                insert into grid_cells (h3_index, location, area_name, features)
                values (%s, ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography, %s, %s)
                on conflict (h3_index) do update set
                    location = excluded.location, area_name = excluded.area_name, features = excluded.features
                """,
                [
                    (cell.h3_index, cell.longitude, cell.latitude, cell.area_name, json.dumps(feat.round(4).to_dict()))
                    for (_, cell), (_, feat) in zip(cells.iterrows(), cell_features.iterrows())
                ],
            )
        # Each hexagon uses its nearest weather and CAMS square.
        conn.execute("""
            update grid_cells g set
                weather_cell_id = (select cell_id from weather_cells w order by w.location <-> g.location limit 1),
                cams_cell_id = (select cell_id from cams_cells c order by c.location <-> g.location limit 1)
        """)
        conn.commit()
        size = conn.execute("select pg_size_pretty(pg_total_relation_size('grid_cells'))").fetchone()[0]
        print(f"Saved {len(cells):,} hexagons ({size}) and {len(stations)} station feature rows.")

    # A quick look at the stations, to check the numbers make sense.
    summary = station_features[["major_road_m_500", "dist_major_road_m", "industrial_share_1000",
                                "green_share_1000", "dist_coast_m"]].round(2)
    summary.insert(0, "station_id", stations.station_id.values)
    print(summary.to_string(index=False))


if __name__ == "__main__":
    main()
