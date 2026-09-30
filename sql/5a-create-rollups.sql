-- ============================================================================
-- ## 5a. Create the rollups
-- ============================================================================
--
--   tiger db query -f sql/5a-create-rollups.sql
--   scripts/refresh-rollups.sh
--   tiger db query -f sql/5b-query-rollups.sql
--
-- Three commands rather than one, for a reason worth knowing:
-- refresh_continuous_aggregate() cannot run inside a transaction block, and
-- `tiger db query -f` wraps a whole file in one. So this file creates the
-- rollups empty (WITH NO DATA), the script fills them one transaction at a
-- time, and 5b asks the questions.
--
-- Two problems left from step 4: cost-by-tenant didn't improve, and
-- count(DISTINCT) got worse. Neither is a storage problem. Both are the same
-- problem: we recompute yesterday's answer every single time we ask.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 5m rollup -- the base layer
-- ----------------------------------------------------------------------------
-- Two things in here are not ordinary SQL, and they are the reason this works.
--
-- percentile_agg() does not store a percentile. It stores a SKETCH -- a small
-- summary you can merge with other sketches. That matters enormously: you
-- cannot average two p99s and get a p99, but you CAN merge two sketches and
-- read a correct p99 off the result. Without that, a pre-aggregated latency
-- number is a lie.
--
-- hyperloglog() is the same trick for distinct counts. It keeps a fixed-size
-- probabilistic register instead of every value it has seen.
--
-- materialized_only = false turns on real-time aggregation: reads transparently
-- union the materialised buckets with the raw rows that arrived since the last
-- refresh. It has defaulted to TRUE since 2.13, so you have to ask for this.

CREATE MATERIALIZED VIEW spans_5m
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
SELECT
    time_bucket('5 minutes', start_time)              AS bucket,
    agent_name,
    tenant,
    operation,
    count(*)                                          AS spans,
    count(*) FILTER (WHERE status = 'error')          AS errors,
    sum(coalesce(input_tokens, 0))                    AS input_tokens,
    sum(coalesce(output_tokens, 0))                   AS output_tokens,
    sum(coalesce(cost_usd, 0))                        AS cost_usd,
    percentile_agg(duration_ms)                       AS latency
FROM spans
GROUP BY bucket, agent_name, tenant, operation
WITH NO DATA;


SELECT add_continuous_aggregate_policy('spans_5m',
    start_offset      => INTERVAL '1 hour',
    end_offset        => INTERVAL '5 minutes',
    schedule_interval => INTERVAL '5 minutes',
    if_not_exists     => true);

-- ----------------------------------------------------------------------------
-- 1h and 1d -- built on the layer below, not on the raw table
-- ----------------------------------------------------------------------------
-- A hierarchical continuous aggregate reads the aggregate beneath it. The daily
-- rollup never touches two million raw rows; it reads 288 five-minute buckets
-- per day per group.
--
-- rollup() is what makes this legal for the sketches. It merges them.

CREATE MATERIALIZED VIEW spans_1h
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
SELECT
    time_bucket('1 hour', bucket)  AS bucket,
    agent_name, tenant, operation,
    sum(spans)                     AS spans,
    sum(errors)                    AS errors,
    sum(input_tokens)              AS input_tokens,
    sum(output_tokens)             AS output_tokens,
    sum(cost_usd)                  AS cost_usd,
    rollup(latency)                AS latency
FROM spans_5m
GROUP BY 1, 2, 3, 4
WITH NO DATA;


SELECT add_continuous_aggregate_policy('spans_1h',
    start_offset      => INTERVAL '6 hours',
    end_offset        => INTERVAL '1 hour',
    schedule_interval => INTERVAL '1 hour',
    if_not_exists     => true);

CREATE MATERIALIZED VIEW spans_1d
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
SELECT
    time_bucket('1 day', bucket)   AS bucket,
    agent_name, tenant, operation,
    sum(spans)                     AS spans,
    sum(errors)                    AS errors,
    sum(input_tokens)              AS input_tokens,
    sum(output_tokens)             AS output_tokens,
    sum(cost_usd)                  AS cost_usd,
    rollup(latency)                AS latency
FROM spans_1h
GROUP BY 1, 2, 3, 4
WITH NO DATA;


SELECT add_continuous_aggregate_policy('spans_1d',
    start_offset      => INTERVAL '3 days',
    end_offset        => INTERVAL '1 day',
    schedule_interval => INTERVAL '1 day',
    if_not_exists     => true);


-- ----------------------------------------------------------------------------
-- A fourth rollup, shaped for one question only
-- ----------------------------------------------------------------------------
-- The three above are grouped by agent + tenant + operation, because that is
-- what a dashboard slices by. That grouping makes them close to useless for
-- counting distinct conversations -- 5b shows exactly how useless, with numbers.
--
-- So: a second rollup, grouped only by day. One sketch per day instead of
-- fourteen thousand.

CREATE MATERIALIZED VIEW conversations_1d
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
SELECT time_bucket('1 day', start_time)        AS bucket,
       hyperloglog(16384, conversation_id)     AS conversations
FROM spans
GROUP BY 1
WITH NO DATA;

SELECT add_continuous_aggregate_policy('conversations_1d',
    start_offset      => INTERVAL '3 days',
    end_offset        => INTERVAL '1 day',
    schedule_interval => INTERVAL '1 hour',
    if_not_exists     => true);

-- ============================================================================
-- ## Nothing in them yet
-- ============================================================================
-- WITH NO DATA means these are empty. Fill them:
--
--   scripts/refresh-rollups.sh

SELECT view_name,
       CASE WHEN materialized_only THEN 'materialized only' ELSE 'real-time' END AS mode
FROM timescaledb_information.continuous_aggregates
ORDER BY view_name;
