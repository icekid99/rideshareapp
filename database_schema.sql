-- ============================================================
-- RideZW PostgreSQL Schema
-- ============================================================

-- Extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "postgis";  -- for geospatial queries

-- ============================================================
-- APP CONFIG (all API keys stored here, DB-configurable)
-- ============================================================
CREATE TABLE app_config (
    key         VARCHAR(120) PRIMARY KEY,
    value       TEXT         NOT NULL,
    description TEXT,
    is_secret   BOOLEAN      DEFAULT TRUE,
    updated_at  TIMESTAMPTZ  DEFAULT NOW()
);

-- Seed default config keys
INSERT INTO app_config (key, value, description, is_secret) VALUES
('GOOGLE_MAPS_API_KEY',      '',  'Google Maps / Places / Directions API key', TRUE),
('FIREBASE_PROJECT_ID',      '',  'Firebase project ID', FALSE),
('OPENAI_API_KEY',           '',  'OpenAI GPT-4o Vision key for doc verification', TRUE),
('GEMINI_API_KEY',           '',  'Google Gemini Vision API key (alt to OpenAI)', TRUE),
('PAYNOW_INTEGRATION_ID',    '',  'Paynow integration ID', TRUE),
('PAYNOW_INTEGRATION_KEY',   '',  'Paynow integration key', TRUE),
('ECOCASH_MERCHANT_CODE',    '',  'EcoCash merchant code', TRUE),
('STRIPE_SECRET_KEY',        '',  'Stripe secret key', TRUE),
('STRIPE_PUBLISHABLE_KEY',   '',  'Stripe publishable key', FALSE),
('AGORA_APP_ID',             '',  'Agora App ID for VoIP/chat', TRUE),
('AGORA_APP_CERTIFICATE',    '',  'Agora App Certificate', TRUE),
('FCM_SERVER_KEY',           '',  'Firebase Cloud Messaging server key', TRUE),
('DRIVER_DAILY_FEE_USD',     '2.00', 'Daily subscription fee for drivers (USD)', FALSE),
('RIDE_SEARCH_RADIUS_KM',    '5',    'Radius to broadcast ride requests to drivers', FALSE),
('AI_VERIFY_PROVIDER',       'openai', 'AI doc verification provider: openai | gemini', FALSE);


-- ============================================================
-- USERS (unified — role switches between PASSENGER / DRIVER)
-- ============================================================
CREATE TYPE user_role AS ENUM ('passenger', 'driver', 'admin');
CREATE TYPE account_status AS ENUM ('active', 'suspended', 'pending_verification', 'banned');

CREATE TABLE users (
    id                  UUID         PRIMARY KEY DEFAULT uuid_generate_v4(),
    firebase_uid        VARCHAR(128) UNIQUE NOT NULL,
    email               VARCHAR(255) UNIQUE NOT NULL,
    full_name           VARCHAR(255) NOT NULL,
    phone_number        VARCHAR(20)  UNIQUE NOT NULL,
    profile_picture_url TEXT,
    role                user_role    NOT NULL DEFAULT 'passenger',
    account_status      account_status NOT NULL DEFAULT 'active',
    average_rating      NUMERIC(3,2) DEFAULT 5.00,
    total_trips         INTEGER      DEFAULT 0,
    created_at          TIMESTAMPTZ  DEFAULT NOW(),
    updated_at          TIMESTAMPTZ  DEFAULT NOW()
);


-- ============================================================
-- DRIVER PROFILES
-- ============================================================
CREATE TYPE driver_verification_status AS ENUM (
    'pending', 'ai_verified', 'manually_approved', 'rejected'
);

CREATE TABLE driver_profiles (
    id                          UUID         PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id                     UUID         UNIQUE NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    vehicle_make                VARCHAR(100),
    vehicle_model               VARCHAR(100),
    vehicle_year                INTEGER,
    vehicle_color               VARCHAR(50),
    vehicle_plate               VARCHAR(20)  UNIQUE,
    vehicle_exterior_photo_url  TEXT,
    vehicle_interior_photo_url  TEXT,
    registration_doc_url        TEXT,
    verification_status         driver_verification_status DEFAULT 'pending',
    ai_verification_result      JSONB,       -- { "verified": bool, "reason": "string" }
    ai_verified_at              TIMESTAMPTZ,
    manually_reviewed_by        UUID REFERENCES users(id),
    manually_reviewed_at        TIMESTAMPTZ,
    rejection_reason            TEXT,
    is_online                   BOOLEAN      DEFAULT FALSE,
    current_lat                 NUMERIC(10,8),
    current_lng                 NUMERIC(11,8),
    last_location_update        TIMESTAMPTZ,
    created_at                  TIMESTAMPTZ  DEFAULT NOW(),
    updated_at                  TIMESTAMPTZ  DEFAULT NOW()
);


-- ============================================================
-- DRIVER WALLET & SUBSCRIPTION
-- ============================================================
CREATE TYPE wallet_tx_type AS ENUM (
    'topup', 'daily_deduction', 'refund', 'adjustment'
);

CREATE TABLE driver_wallets (
    id              UUID         PRIMARY KEY DEFAULT uuid_generate_v4(),
    driver_id       UUID         UNIQUE NOT NULL REFERENCES driver_profiles(id) ON DELETE CASCADE,
    balance_usd     NUMERIC(10,2) DEFAULT 0.00,
    currency        VARCHAR(10)  DEFAULT 'USD',
    updated_at      TIMESTAMPTZ  DEFAULT NOW()
);

CREATE TABLE driver_subscription_cycles (
    id                  UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    driver_id           UUID        NOT NULL REFERENCES driver_profiles(id) ON DELETE CASCADE,
    cycle_start         TIMESTAMPTZ NOT NULL,
    cycle_end           TIMESTAMPTZ NOT NULL,        -- cycle_start + 24h
    amount_deducted_usd NUMERIC(10,2) NOT NULL DEFAULT 2.00,
    auto_renew          BOOLEAN     DEFAULT TRUE,    -- FALSE = suspend after this cycle
    is_active           BOOLEAN     DEFAULT TRUE,
    created_at          TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE wallet_transactions (
    id              UUID         PRIMARY KEY DEFAULT uuid_generate_v4(),
    driver_id       UUID         NOT NULL REFERENCES driver_profiles(id) ON DELETE CASCADE,
    tx_type         wallet_tx_type NOT NULL,
    amount_usd      NUMERIC(10,2) NOT NULL,
    balance_after   NUMERIC(10,2) NOT NULL,
    reference       VARCHAR(255),
    description     TEXT,
    payment_gateway VARCHAR(50),  -- paynow | ecocash | stripe
    gateway_ref     VARCHAR(255),
    created_at      TIMESTAMPTZ  DEFAULT NOW()
);


-- ============================================================
-- RIDES
-- ============================================================
CREATE TYPE ride_status AS ENUM (
    'searching',       -- passenger waiting for bids
    'negotiating',     -- bids received, passenger choosing
    'accepted',        -- passenger accepted a bid
    'driver_en_route', -- driver heading to pickup
    'in_progress',     -- trip underway
    'completed',
    'cancelled'
);

CREATE TYPE payment_method AS ENUM ('cash', 'ecocash', 'paynow', 'stripe', 'innbucks');

CREATE TABLE rides (
    id                      UUID         PRIMARY KEY DEFAULT uuid_generate_v4(),
    passenger_id            UUID         NOT NULL REFERENCES users(id),
    driver_id               UUID         REFERENCES users(id),

    -- Locations
    pickup_lat              NUMERIC(10,8) NOT NULL,
    pickup_lng              NUMERIC(11,8) NOT NULL,
    pickup_address          TEXT         NOT NULL,
    dropoff_lat             NUMERIC(10,8) NOT NULL,
    dropoff_lng             NUMERIC(11,8) NOT NULL,
    dropoff_address         TEXT         NOT NULL,

    -- Pricing
    reference_price_usd     NUMERIC(10,2),  -- hidden Google Distance Matrix price
    passenger_offer_usd     NUMERIC(10,2) NOT NULL,
    final_agreed_price_usd  NUMERIC(10,2),
    distance_km             NUMERIC(8,2),
    duration_minutes        INTEGER,

    -- Route
    encoded_polyline        TEXT,

    -- State
    status                  ride_status  NOT NULL DEFAULT 'searching',
    payment_method          payment_method DEFAULT 'cash',
    payment_status          VARCHAR(50)  DEFAULT 'pending',

    -- Timestamps
    search_started_at       TIMESTAMPTZ  DEFAULT NOW(),
    accepted_at             TIMESTAMPTZ,
    pickup_at               TIMESTAMPTZ,
    completed_at            TIMESTAMPTZ,
    cancelled_at            TIMESTAMPTZ,
    cancelled_by            UUID REFERENCES users(id),
    cancel_reason           TEXT,

    created_at              TIMESTAMPTZ  DEFAULT NOW(),
    updated_at              TIMESTAMPTZ  DEFAULT NOW()
);


-- ============================================================
-- RIDE BIDS (P2P Negotiation)
-- ============================================================
CREATE TYPE bid_status AS ENUM ('pending', 'countered', 'accepted', 'rejected', 'expired');

CREATE TABLE ride_bids (
    id              UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    ride_id         UUID        NOT NULL REFERENCES rides(id) ON DELETE CASCADE,
    driver_id       UUID        NOT NULL REFERENCES users(id),
    offer_usd       NUMERIC(10,2) NOT NULL, -- driver's counter-offer
    status          bid_status  NOT NULL DEFAULT 'pending',
    counter_percent INTEGER,    -- 10 | 20 | 30 (the % pill driver tapped)
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(ride_id, driver_id)  -- one bid per driver per ride
);


-- ============================================================
-- LIVE DRIVER LOCATIONS (streaming, TTL managed by backend)
-- ============================================================
CREATE TABLE driver_locations (
    driver_id       UUID        PRIMARY KEY REFERENCES driver_profiles(id) ON DELETE CASCADE,
    lat             NUMERIC(10,8) NOT NULL,
    lng             NUMERIC(11,8) NOT NULL,
    heading         NUMERIC(5,2),
    speed_kmh       NUMERIC(6,2),
    updated_at      TIMESTAMPTZ  DEFAULT NOW()
);


-- ============================================================
-- RATINGS & REVIEWS
-- ============================================================
CREATE TABLE ratings (
    id              UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    ride_id         UUID        NOT NULL REFERENCES rides(id),
    rater_id        UUID        NOT NULL REFERENCES users(id),
    ratee_id        UUID        NOT NULL REFERENCES users(id),
    stars           SMALLINT    NOT NULL CHECK (stars BETWEEN 1 AND 5),
    tags            TEXT[],     -- e.g. {"Polite", "On Time", "Clean Car"}
    comment         TEXT,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(ride_id, rater_id)
);


-- ============================================================
-- IN-APP MESSAGES (per ride)
-- ============================================================
CREATE TABLE ride_messages (
    id          UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    ride_id     UUID        NOT NULL REFERENCES rides(id) ON DELETE CASCADE,
    sender_id   UUID        NOT NULL REFERENCES users(id),
    message     TEXT        NOT NULL,
    is_read     BOOLEAN     DEFAULT FALSE,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);


-- ============================================================
-- PUSH NOTIFICATION LOG
-- ============================================================
CREATE TABLE notification_log (
    id          UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id     UUID        NOT NULL REFERENCES users(id),
    title       VARCHAR(255),
    body        TEXT,
    data        JSONB,
    sent_at     TIMESTAMPTZ DEFAULT NOW(),
    success     BOOLEAN     DEFAULT TRUE
);


-- ============================================================
-- INDEXES
-- ============================================================
CREATE INDEX idx_rides_passenger        ON rides(passenger_id);
CREATE INDEX idx_rides_driver           ON rides(driver_id);
CREATE INDEX idx_rides_status           ON rides(status);
CREATE INDEX idx_bids_ride              ON ride_bids(ride_id);
CREATE INDEX idx_bids_driver            ON ride_bids(driver_id);
CREATE INDEX idx_bids_status            ON ride_bids(status);
CREATE INDEX idx_driver_locations_pos   ON driver_locations(lat, lng);
CREATE INDEX idx_wallet_tx_driver       ON wallet_transactions(driver_id);
CREATE INDEX idx_subscription_driver    ON driver_subscription_cycles(driver_id);
CREATE INDEX idx_ratings_ratee          ON ratings(ratee_id);
CREATE INDEX idx_messages_ride          ON ride_messages(ride_id);
