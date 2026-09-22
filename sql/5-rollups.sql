-- ============================================================================
-- ## 5. Stop doing the work twice
-- ============================================================================
--
-- ⚠ Run this one section at a time with -c, NOT with -f.
--
-- `tiger db query -f` wraps a whole file in one transaction, and
-- CREATE MATERIALIZED VIEW ... WITH DATA cannot run inside a transaction block
-- (SQLSTATE 25001). Everything here uses WITH NO DATA plus an explicit refresh
-- so it works either way -- but the refresh calls still need their own
-- transaction. Copy the sections.
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

CALL refresh_continuous_aggregate('spans_5m', NULL, NULL);

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

CALL refresh_continuous_aggregate('spans_1h', NULL, NULL);

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

CALL refresh_continuous_aggregate('spans_1d', NULL, NULL);

SELECT add_continuous_aggregate_policy('spans_1d',
    start_offset      => INTERVAL '3 days',
    end_offset        => INTERVAL '1 day',
    schedule_interval => INTERVAL '1 day',
    if_not_exists     => true);

-- ============================================================================
-- ## Now ask the same questions again
-- ============================================================================

-- Q2 revisited. Cost by tenant over 30 days -- from the daily rollup.
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT tenant, round(sum(cost_usd), 2) AS cost_usd
FROM spans_1d
GROUP BY tenant
ORDER BY cost_usd DESC;

-- ----------------------------------------------------------------------------
-- Q4 revisited -- and the lesson that actually matters
-- ----------------------------------------------------------------------------
-- First, the wrong way. Suppose we had put hyperloglog into spans_5m alongside
-- the latency sketch, grouped by agent + tenant + operation like everything
-- else. Asking for distinct conversations per day then has to merge every
-- sketch in every group: 300 agents x 12 tenants x 4 operations is ~14,400
-- sketches per bucket, ~178,000 of them across the range.
--
-- Measured: 5,590 ms. No better than the raw table. The data is tiny; merging
-- 178,000 probabilistic registers is what costs.
--
-- The fix is not a faster sketch. It is a rollup shaped like the question.

CREATE MATERIALIZED VIEW conversations_1d
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
SELECT time_bucket('1 day', start_time)        AS bucket,
       hyperloglog(16384, conversation_id)     AS conversations
FROM spans
GROUP BY 1
WITH NO DATA;

CALL refresh_continuous_aggregate('conversations_1d', NULL, NULL);

SELECT add_continuous_aggregate_policy('conversations_1d',
    start_offset      => INTERVAL '3 days',
    end_offset        => INTERVAL '1 day',
    schedule_interval => INTERVAL '1 hour',
    if_not_exists     => true);

-- One sketch per day instead of fourteen thousand.
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT bucket::date AS day, distinct_count(conversations) AS conversations
FROM conversations_1d
ORDER BY 1 DESC
LIMIT 7;

-- ----------------------------------------------------------------------------
-- The one you cannot do any other way
-- ----------------------------------------------------------------------------
-- p99 latency per agent across the full 30 days, computed from daily buckets.
-- You could not do this by storing a p99 per bucket and averaging them -- that
-- answer is simply wrong. Merging the sketches gives the real one.

EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT agent_name,
       sum(spans)                                    AS spans,
       approx_percentile(0.50, rollup(latency))::int AS p50_ms,
       approx_percentile(0.99, rollup(latency))::int AS p99_ms
FROM spans_1d
WHERE operation = 'chat'
GROUP BY agent_name
ORDER BY p99_ms DESC
LIMIT 10;

-- ----------------------------------------------------------------------------
-- How wrong are the approximations?
-- ----------------------------------------------------------------------------
-- Ask this of anything that says "approx". Then decide whether you care.

SELECT
    (SELECT approx_percentile(0.99, rollup(latency))::int
       FROM spans_1d WHERE operation = 'chat')                    AS sketch_p99,
    (SELECT percentile_cont(0.99) WITHIN GROUP (ORDER BY duration_ms)::int
       FROM spans WHERE operation = 'chat')                       AS exact_p99,
    (SELECT distinct_count(rollup(conversations)) FROM conversations_1d) AS hll_conversations,
    (SELECT count(DISTINCT conversation_id) FROM spans)           AS exact_conversations;

-- ----------------------------------------------------------------------------
-- What the rollups cost you
-- ----------------------------------------------------------------------------
SELECT view_name,
       pg_size_pretty(hypertable_size(format('%I.%I', materialization_hypertable_schema,
                                                      materialization_hypertable_name)::regclass)) AS size
FROM timescaledb_information.continuous_aggregates
ORDER BY view_name;

-- ============================================================================
-- ## Scoreboard
-- ============================================================================
-- Free Tiger Cloud service, ~2M spans. Same four questions, three times.
--
--                              plain    columnstore   rollup
--   Q1  p99 by agent          3234ms       1305ms      554ms
--   Q2  cost by tenant        1999ms       1897ms      303ms
--   Q4  distinct convs/day    5581ms       5724ms      1.1ms
--
-- Accuracy: p99 sketch 3255 vs 3270 exact, 0.5% off. Conversations 20,000 vs
-- 20,001 exact, which is luck on top of a ~0.8% expected error at 16,384
-- registers.
--
-- Two things to take away, and the second one is the one people miss.
--
-- 1. Sketches are what make pre-aggregation honest. A stored p99 per bucket
--    cannot be combined into a p99 over a month. A stored SKETCH can.
--
-- 2. A rollup is only fast for the question it was shaped for. spans_5m is
--    grouped four ways because that is what the dashboard slices by, and that
--    same grouping made the conversation count 5,000x slower until we built a
--    second rollup with one column in the GROUP BY.
--
--    You do not get one magic aggregate. You get aggregates shaped like your
--    questions -- which is fine, because they are cheap. Notice also that the
--    three spans_* rollups together are larger than the compressed raw table.
--    Group by fewer dimensions than you think you need.
