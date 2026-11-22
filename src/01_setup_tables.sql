CREATE CATALOG IF NOT EXISTS IDENTIFIER(:catalog_name);
USE CATALOG IDENTIFIER(:catalog_name);

CREATE SCHEMA IF NOT EXISTS config;
CREATE SCHEMA IF NOT EXISTS bronze;
CREATE SCHEMA IF NOT EXISTS silver;
CREATE SCHEMA IF NOT EXISTS gold;
CREATE SCHEMA IF NOT EXISTS audit;
CREATE SCHEMA IF NOT EXISTS quarantine;

-- 1. Config: Locations (At least 5 locations)
CREATE OR REPLACE TABLE config.locations (
    location_id STRING NOT NULL,
    city_name STRING NOT NULL,
    country STRING,
    latitude DOUBLE NOT NULL,
    longitude DOUBLE NOT NULL,
    is_active BOOLEAN
) USING DELTA;

INSERT INTO config.locations VALUES
('LOC_SG', 'Singapore', 'Singapore', 1.3521, 103.8198, TRUE),
('LOC_TYO', 'Tokyo', 'Japan', 35.6762, 139.6503, TRUE),
('LOC_LDN', 'London', 'United Kingdom', 51.5072, -0.1276, TRUE),
('LOC_NYC', 'New York', 'USA', 40.7128, -74.0060, TRUE),
('LOC_SYD', 'Sydney', 'Australia', -33.8688, 151.2093, TRUE);

-- 2. Config: Pipeline Parameters
CREATE OR REPLACE TABLE config.pipeline_params (
    param_key STRING NOT NULL,
    param_value STRING NOT NULL
) USING DELTA;

INSERT INTO config.pipeline_params VALUES
('base_url', 'https://api.open-meteo.com/v1/forecast'),
('hourly_vars', 'temperature_2m,relative_humidity_2m,precipitation,wind_speed_10m'),
('forecast_days', '5'),
('max_retries', '3'),
('expected_hourly_schema', '{"time": "str", "temperature_2m": "float", "relative_humidity_2m": "int", "precipitation": "float", "wind_speed_10m": "float"}');

-- 3. Bronze: Append-only raw API responses
CREATE TABLE IF NOT EXISTS bronze.weather_raw (
    ingestion_id STRING NOT NULL,
    run_id STRING NOT NULL,
    ingestion_ts TIMESTAMP NOT NULL,
    location_id STRING NOT NULL,
    city_name STRING,
    request_url STRING,
    http_status INT,
    raw_response STRING
) USING DELTA;

-- 4. Silver: Deduplicated, typed hourly forecast
CREATE TABLE IF NOT EXISTS silver.weather_hourly (
    location_id STRING NOT NULL,
    city_name STRING,
    forecast_ts TIMESTAMP NOT NULL,
    temperature_2m DOUBLE,
    relative_humidity_2m DOUBLE,
    precipitation DOUBLE,
    wind_speed_10m DOUBLE,
    run_id STRING,
    updated_at TIMESTAMP
) USING DELTA;

-- 5. Gold: Daily City Summary & Weather Alerts
CREATE TABLE IF NOT EXISTS gold.daily_weather_summary (
    forecast_date DATE NOT NULL,
    location_id STRING NOT NULL,
    city_name STRING,
    min_temp_c DOUBLE,
    max_temp_c DOUBLE,
    avg_temp_c DOUBLE,
    min_humidity_pct DOUBLE,
    max_humidity_pct DOUBLE,
    avg_humidity_pct DOUBLE,
    total_precipitation_mm DOUBLE,
    max_wind_speed_kmh DOUBLE,
    is_rainy_day BOOLEAN,
    weather_alert STRING,
    updated_at TIMESTAMP
) USING DELTA;

-- 6. Audit: Run-level summary
CREATE TABLE IF NOT EXISTS audit.pipeline_runs (
    run_id STRING NOT NULL,
    start_time TIMESTAMP,
    end_time TIMESTAMP,
    status STRING,
    parameters STRING,
    locations_attempted INT,
    locations_succeeded INT,
    silver_rows_merged LONG,
    quarantined_rows LONG,
    error_message STRING
) USING DELTA;

-- 7. Audit: Per-location execution & schema drift logs
CREATE TABLE IF NOT EXISTS audit.location_audit (
    run_id STRING NOT NULL,
    location_id STRING,
    city_name STRING,
    status STRING,
    http_status INT,
    rows_extracted INT,
    schema_changes STRING,
    error_message STRING,
    logged_at TIMESTAMP
) USING DELTA;

-- 8. Quarantine: Invalid API payloads & out-of-range Silver records
CREATE TABLE IF NOT EXISTS quarantine.weather_quarantine (
    quarantine_id STRING NOT NULL,
    run_id STRING NOT NULL,
    stage STRING,
    location_id STRING,
    forecast_ts STRING,
    quarantine_reason STRING,
    raw_record STRING,
    quarantined_at TIMESTAMP
) USING DELTA;

--9. Create a Department-to-Location Mapping Table
CREATE OR REPLACE TABLE config.department_locations (
    department STRING NOT NULL,
    location_id STRING NOT NULL,
    allowed_user_email STRING -- Optional: ties specific logins to departments
) USING DELTA;

INSERT INTO config.department_locations VALUES
-- APAC Logistics monitors Singapore, Tokyo, Sydney
('APAC Logistics', 'LOC_SG', 'srilanth.450@gmail.com'),
('APAC Logistics', 'LOC_TYO', 'srilanth.450@gmail.com'),
('APAC Logistics', 'LOC_SYD', 'srilanth.450@gmail.com'),

-- Western Operations monitors London & New York
('Western Operations', 'LOC_LDN', 'srilanth.451@gmail.com'),
('Western Operations', 'LOC_NYC', 'srilanth.451@gmail.com'),

-- Global Risk monitors Singapore & London
('Global Risk', 'LOC_SG', 'srilanth.452@gmail.com'),
('Global Risk', 'LOC_LDN', 'srilanth.452@gmail.com');

--10. Update Your Row-Level Filter
CREATE OR REPLACE FUNCTION config.location_row_filter(loc_id STRING)
RETURNS BOOLEAN
RETURN (
  -- Admin login sees all cities & departments
  CURRENT_USER() = 'srikanth.449@gmail.com'
  OR
  -- Test logins only see cities mapped to their email
  EXISTS (
    SELECT 1
    FROM config.department_locations d
    WHERE d.allowed_user_email = CURRENT_USER()
      AND d.location_id = loc_id
  )
);

ALTER TABLE config.locations
SET ROW FILTER config.location_row_filter ON (location_id);

