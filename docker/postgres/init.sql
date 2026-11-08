-- =============================================================================
-- Step 1: Create additional databases
-- =============================================================================
-- In PostgreSQL, CREATE DATABASE cannot run inside a transaction block.
-- The official docker-entrypoint runs this file with psql without wrapping it
-- in a transaction by default (unless --single-transaction is passed).
-- We use \gexec to conditionally execute CREATE DATABASE if it doesn't exist.

SELECT 'CREATE DATABASE users_db'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'users_db')\gexec

SELECT 'CREATE DATABASE devices_db'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'devices_db')\gexec

-- =============================================================================
-- Step 2: Configure users_db
-- =============================================================================
\connect users_db

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS vector;

-- Users table
CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email VARCHAR(255) UNIQUE NOT NULL,
    full_name VARCHAR(255) NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Energy pattern embeddings table
CREATE TABLE IF NOT EXISTS energy_pattern_embeddings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    week_start DATE NOT NULL,
    pattern_description TEXT,
    embedding VECTOR(384),
    avg_daily_kwh DOUBLE PRECISION,
    peak_hour INT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT uq_user_week_start UNIQUE (user_id, week_start)
);

-- IVFFlat index on embedding
CREATE INDEX IF NOT EXISTS idx_energy_pattern_embedding
ON energy_pattern_embeddings
USING ivfflat (embedding vector_cosine_ops)
WITH (lists = 100);

-- =============================================================================
-- Step 3: Configure devices_db
-- =============================================================================
\connect devices_db

-- Devices table
CREATE TABLE IF NOT EXISTS devices (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL, -- Logical reference to users_db.users (cross-database FKs not supported)
    device_name VARCHAR(100) NOT NULL,
    device_type VARCHAR(50) NOT NULL,
    mqtt_username VARCHAR(100) UNIQUE NOT NULL,
    room VARCHAR(50),
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT chk_device_type CHECK (
        device_type IN ('AC', 'FRIDGE', 'TV', 'HEATER', 'LIGHT_BULB', 'WASHER')
    )
);