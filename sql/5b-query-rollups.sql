-- ============================================================================
-- ## 5b. What the rollups bought you
-- ============================================================================
--
--   tiger db query -f sql/5b-query-rollups.sql
--
-- Run this after scripts/refresh-rollups.sh has populated the rollups.
--
-- Read-only. Safe to re-run.
-- ============================================================================

-- ## The same questions, answered from the rollups
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
-- Measured on 0.5 CPU / 2 GB: 512 ms, from a 44 MB rollup holding 239,060
-- sketches. The data is tiny; merging that many probabilistic registers is what
-- costs. (On a smaller instance this was 5,590 ms -- no better than scanning the
-- raw table at all.)
--
-- The fix is not a faster sketch. It is a rollup shaped like the question.




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
--   Q1  p99 by agent          1554ms        651ms      215ms
--   Q2  cost by tenant         981ms        867ms      119ms
--   Q4  distinct convs/day    2482ms       3040ms      1.2ms
--
-- Accuracy: p99 sketch 9584 vs 9579 exact, 0.05% off. Conversations 20,000 vs
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
--    same grouping made the conversation count 400x slower, in a rollup 70x
--    larger, until we built a second one with a single column in the GROUP BY.
--
--    You do not get one magic aggregate. You get aggregates shaped like your
--    questions -- which is fine, because they are cheap. Notice also that the
--    three spans_* rollups together are larger than the compressed raw table.
--    Group by fewer dimensions than you think you need.
