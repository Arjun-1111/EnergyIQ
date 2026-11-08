-- =============================================================================
-- TimescaleDB Initialization Script: energy_db
-- =============================================================================

-- =============================================================================
-- What is a Hypertable? How does it differ from a normal table and 1-day chunks?
--Think of a Hypertable as an illusion created by TimescaleDB:
-- To you and your application, it looks, acts, and behaves like one single, normal PostgreSQL table. You write standard SELECT, INSERT, and JOIN queries against it.
-- Behind the scenes, TimescaleDB automatically slices that one big table into dozens or hundreds of small, standard PostgreSQL tables called chunks.
-- =============================================================================

-- =============================================================================
-- How it differs from a normal table:
-- Normal Table: As millions of rows pour in, the table and its indexes grow massive. Soon, they no longer fit into RAM. The database must constantly swap data between disk and RAM, causing insert speeds to plunge.
-- Hypertable: New data only ever touches the current chunk. Because a single chunk is small, it and its indexes fit entirely inside memory (RAM). When the chunk's time window ends, TimescaleDB freezes it and spins up a brand-new chunk automatically.
-- =============================================================================

-- =============================================================================
-- What does "Partitioned by time with 1-day chunks" mean?
-- It means every chunk holds exactly 24 hours of data.
-- =============================================================================


-- 1. Enable TimescaleDB extension
CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;

-- 2. Create the raw hypertable base schema
CREATE TABLE IF NOT EXISTS energy_readings (
    time         TIMESTAMPTZ      NOT NULL,
    device_id    UUID             NOT NULL,
    user_id      UUID             NOT NULL,
    watts        DOUBLE PRECISION NOT NULL,
    voltage      DOUBLE PRECISION,
    current_amp  DOUBLE PRECISION,
    message_id   UUID             NOT NULL,
    CONSTRAINT pk_energy_readings PRIMARY KEY (time, device_id)
);

-- 3. Convert table to a TimescaleDB hypertable partitioned by time (1-day chunks)
SELECT create_hypertable(
    'energy_readings',
    by_range('time', INTERVAL '1 day'),
    if_not_exists => TRUE
);

-- 4. Create compound indexes for analytical and dashboard access patterns
CREATE INDEX IF NOT EXISTS idx_energy_readings_device_time
    ON energy_readings (device_id, time DESC);

CREATE INDEX IF NOT EXISTS idx_energy_readings_user_time
    ON energy_readings (user_id, time DESC);

-- 5. Create Continuous Aggregate for 1-hour rollups
CREATE MATERIALIZED VIEW IF NOT EXISTS energy_hourly
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('1 hour', time) AS bucket,
    device_id,
    user_id,
    AVG(watts)                  AS avg_watts,
    MAX(watts)                  AS max_watts,
    MIN(watts)                  AS min_watts,
    SUM(watts) / 60.0           AS wh_consumed,
    COUNT(*)                    AS reading_count
FROM energy_readings
GROUP BY bucket, device_id, user_id
WITH NO DATA;

-- 6. Add continuous aggregate refresh policy
-- Refreshes every 30m over a sliding window: [NOW() - 3 hours, NOW() - 1 hour]
-- start_offset => INTERVAL '3 hours' (The Late-Data Catch-Up):
-- "Look back as far as 3 hours ago."
-- Why? IoT devices sometimes lose Wi-Fi. If a smart meter disconnects for 45 minutes, reconnects, and dumps backlogged data, this window ensures Timescale catches those delayed readings and updates the corresponding hourly bucket.
-- schedule_interval => INTERVAL '30 minutes':
-- "Wake up every 30 minutes to do work."
-- end_offset => INTERVAL '1 hour' (The Waiting Window):
-- "Do not calculate anything from the last 60 minutes."
-- Why? The current hour isn't finished yet. If it's 2:40 PM, the 2:00–3:00 PM bucket is incomplete, and devices are still streaming packets. Calculating too early forces unnecessary recalculations.
SELECT add_continuous_aggregate_policy(
    'energy_hourly',
    start_offset => INTERVAL '3 hours',
    end_offset   => INTERVAL '1 hour',
    schedule_interval => INTERVAL '30 minutes',
    if_not_exists => TRUE
);

-- 7. Add raw data retention policy
-- Automatically drops underlying data chunks older than 7 days
-- We're in dev. In production this would be 90-365 days. The continuous aggregate preserves the hourly rollups even after raw data is dropped.
SELECT add_retention_policy(
    'energy_readings',
    drop_after => INTERVAL '7 days',
    if_not_exists => TRUE
);