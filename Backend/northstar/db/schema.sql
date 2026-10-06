-- North Star database tables.
-- Safe to run more than once: every statement uses "if not exists".
-- Sizes are kept small on purpose (smallint ids, 4-byte real numbers, one
-- row per station-hour) to stay well inside the Supabase free plan's 500 MB.

create extension if not exists postgis;

-- Where a reading came from. One row per data provider.
create table if not exists data_sources (
    source_id   smallint primary key,
    name        text not null unique,
    description text
);

insert into data_sources (source_id, name, description) values
    (1, 'openaq',    'OpenAQ (archive and API)'),
    (2, 'datagovin', 'Government of India open data portal, real-time air quality'),
    (3, 'waqi',      'World Air Quality Index project')
on conflict (source_id) do nothing;

-- Weather grid squares. Open-Meteo snaps every location to its nearest
-- grid point, so nearby stations share one square and one weather series.
create table if not exists weather_cells (
    cell_id     smallint primary key,
    location    geography(Point, 4326) not null unique,
    elevation_m real
);

-- One row per physical monitoring station.
create table if not exists stations (
    station_id      smallint primary key,
    name            text not null,
    operator        text not null,
    location        geography(Point, 4326) not null,
    weather_cell_id smallint references weather_cells (cell_id),
    first_reading   timestamptz,
    last_reading    timestamptz,
    is_active       boolean not null default true,
    notes           text
);

-- Spatial index: makes "nearest stations to this point" fast.
create index if not exists stations_location_idx on stations using gist (location);

-- Maps each provider's own station ids to our stations. One physical
-- station can have several ids (old and new feeds, different providers).
create table if not exists station_sources (
    source_id          smallint not null references data_sources (source_id),
    source_location_id text not null,
    station_id         smallint not null references stations (station_id),
    primary key (source_id, source_location_id)
);

-- Cleaned hourly pollution: one row per station per hour, one column per
-- pollutant, in micrograms per cubic metre. ts is the start of the hour, in UTC.
create table if not exists air_readings_hourly (
    station_id smallint not null references stations (station_id),
    ts         timestamptz not null,
    pm25       real,
    pm10       real,
    no2        real,
    no         real,
    nox        real,
    o3         real,
    co         real,
    so2        real,
    -- One bit per pollutant (in the column order above): 1 = filled or adjusted by cleaning.
    qc_flags   smallint not null default 0,
    source_id  smallint not null references data_sources (source_id),
    primary key (station_id, ts)
);

-- Raw values from every live source for the last 48 hours. The collector
-- compares sources here, picks the best value per station-hour, and writes
-- it to air_readings_hourly. Old rows are deleted, so this stays tiny.
create table if not exists air_readings_recent (
    source_id  smallint not null references data_sources (source_id),
    station_id smallint not null references stations (station_id),
    ts         timestamptz not null,
    pm25       real,
    pm10       real,
    no2        real,
    no         real,
    nox        real,
    o3         real,
    co         real,
    so2        real,
    fetched_at timestamptz not null default now(),
    primary key (source_id, station_id, ts)
);

-- Hourly weather per grid square. ts is the start of the hour, in UTC.
create table if not exists weather_hourly (
    cell_id                 smallint not null references weather_cells (cell_id),
    ts                      timestamptz not null,
    temperature_c           real,
    relative_humidity       real,
    dew_point_c             real,
    precipitation_mm        real,
    pressure_hpa            real,
    cloud_cover             real,
    wind_speed_ms           real,
    wind_dir_deg            real,
    wind_gust_ms            real,
    shortwave_radiation     real,
    boundary_layer_height_m real,
    primary key (cell_id, ts)
);

-- Supabase publishes tables in the public schema through its web API.
-- Row Level Security with no policies blocks that API completely; our
-- backend connects as the database owner, which is not affected.
alter table data_sources        enable row level security;
alter table weather_cells       enable row level security;
alter table stations            enable row level security;
alter table station_sources     enable row level security;
alter table air_readings_hourly enable row level security;
alter table air_readings_recent enable row level security;
alter table weather_hourly      enable row level security;

-- CAMS (Copernicus Atmosphere Monitoring Service) air quality model, through
-- Open-Meteo. A coarse global pollution model that is always available and
-- forecasts 5 days ahead. Our model learns to correct it using the stations.
create table if not exists cams_cells (
    cell_id  smallint primary key,
    location geography(Point, 4326) not null unique
);

alter table stations add column if not exists cams_cell_id smallint references cams_cells (cell_id);

-- Hourly CAMS values per grid square, in µg/m³. ts is the start of the hour,
-- in UTC. Past hours hold CAMS's best estimate; future hours hold its latest
-- forecast and are overwritten as newer forecasts arrive.
create table if not exists cams_hourly (
    cell_id smallint not null references cams_cells (cell_id),
    ts      timestamptz not null,
    pm25    real,
    pm10    real,
    no2     real,
    o3      real,
    co      real,
    so2     real,
    dust    real,
    primary key (cell_id, ts)
);

alter table cams_cells  enable row level security;
alter table cams_hourly enable row level security;

-- One row per source per collector run: did it work, and how fresh is its
-- newest Mumbai reading? Shows when a broken feed comes back.
create table if not exists source_checks (
    checked_at         timestamptz not null default now(),
    source_id          smallint not null references data_sources (source_id),
    ok                 boolean not null,
    newest_reading     timestamptz,
    stations_reporting smallint,
    message            text,
    primary key (source_id, checked_at)
);

alter table source_checks enable row level security;

-- The map's hexagons (H3 resolution 9, about 350 m across), with the weather
-- and CAMS squares each one uses and its city-layout features.
-- Features are stored as JSON so the list can grow without changing the table.
create table if not exists grid_cells (
    h3_index        text primary key,
    location        geography(Point, 4326) not null,
    area_name       text,
    weather_cell_id smallint references weather_cells (cell_id),
    cams_cell_id    smallint references cams_cells (cell_id),
    features        jsonb not null
);

create index if not exists grid_cells_location_idx on grid_cells using gist (location);

-- The same city-layout features measured at each station.
create table if not exists station_features (
    station_id smallint primary key references stations (station_id),
    features   jsonb not null
);

alter table grid_cells       enable row level security;
alter table station_features enable row level security;

-- Festival and event calendar (refreshed automatically by the collector).
-- Each festival type's first big day; the model measures days before and after.
create table if not exists events (
    event_date date not null,
    event_type text not null,
    name       text,
    source     text,
    fetched_at timestamptz not null default now(),
    primary key (event_date, event_type)
);

alter table events enable row level security;

-- Fire detections from NASA FIRMS satellites in a ~500 km box around Mumbai.
-- frp = fire radiative power in megawatts (how big the fire is).
create table if not exists fires (
    satellite   text not null,
    detected_at timestamptz not null,
    latitude    real not null,
    longitude   real not null,
    frp         real,
    confidence  text,
    primary key (satellite, detected_at, latitude, longitude)
);

create index if not exists fires_detected_at_idx on fires (detected_at);

alter table fires enable row level security;
