-- ============================================================================
-- ## 1. Example — delete this file
-- ============================================================================
--
-- Run it with:
--
--   tiger db query -f sql/1-example.sql
--
-- No service ID needed: `tiger service create` sets the new service as your
-- default. Pass one explicitly if you need a different service.
--
-- Conventions worth keeping in your real files:
--   * Numbered, so the order is obvious and the README can table them up.
--   * Self-contained, so someone who falls behind can skip ahead.
--   * Re-runnable, hence the DROP ... IF EXISTS.
--   * The banner comments above are how attendees find their place when you're
--     talking over a screen share.
-- ============================================================================

DROP TABLE IF EXISTS readings CASCADE;

CREATE TABLE readings (
    ts      timestamptz NOT NULL,
    device  text        NOT NULL,
    value   double precision
);

SELECT create_hypertable('readings', by_range('ts', INTERVAL '1 day'));

INSERT INTO readings
SELECT ts, 'device_' || (random() * 3)::int, random() * 100
FROM generate_series(now() - INTERVAL '7 days', now(), INTERVAL '1 minute') AS ts;

-- ============================================================================
-- ## Confirm it worked
-- ============================================================================

SELECT count(*) AS rows, min(ts) AS earliest, max(ts) AS latest FROM readings;
