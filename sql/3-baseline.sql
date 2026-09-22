-- ============================================================================
-- ## 3. The questions you actually ask, on a plain Postgres table
-- ============================================================================
--
--   tiger db query -f sql/3-baseline.sql
--
-- Four questions any team with agents in production asks every week. Nothing
-- here is exotic. Time them, and read the plans -- the numbers are the point.
--
-- Read-only. Safe to re-run.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Q1. Which agents are slow? p99 latency by agent, last 30 days.
-- ----------------------------------------------------------------------------
-- percentile_cont has to sort every matching row. No index helps.

EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT agent_name,
       count(*)                                                         AS spans,
       percentile_cont(0.99) WITHIN GROUP (ORDER BY duration_ms)::int   AS p99_ms
FROM spans
WHERE operation = 'chat'
GROUP BY agent_name
ORDER BY p99_ms DESC
LIMIT 10;

-- ----------------------------------------------------------------------------
-- Q2. What is each customer costing us?
-- ----------------------------------------------------------------------------

EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT tenant,
       count(*) FILTER (WHERE parent_span_id IS NULL) AS runs,
       round(sum(cost_usd) FILTER (WHERE parent_span_id IS NULL), 2) AS cost_usd
FROM spans
GROUP BY tenant
ORDER BY cost_usd DESC;

-- ----------------------------------------------------------------------------
-- Q3. Which tools fail?
-- ----------------------------------------------------------------------------

EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT tool_name,
       count(*) AS calls,
       count(*) FILTER (WHERE status = 'error') AS errors,
       round(100.0 * count(*) FILTER (WHERE status = 'error') / count(*), 2) AS error_pct
FROM spans
WHERE operation = 'execute_tool'
GROUP BY tool_name
ORDER BY error_pct DESC
LIMIT 10;

-- ----------------------------------------------------------------------------
-- Q4. How many distinct conversations per day?
-- ----------------------------------------------------------------------------
-- count(DISTINCT) is the one that quietly eats your afternoon.

EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT date_trunc('day', start_time) AS day,
       count(DISTINCT conversation_id) AS conversations
FROM spans
GROUP BY 1
ORDER BY 1 DESC
LIMIT 7;

-- ============================================================================
-- ## The one that matters: find the runs that are eating the money
-- ============================================================================
-- Org-wide error rate is ~8%. That number is useless on its own -- it doesn't
-- tell you whether everything is slightly broken or a few things are very
-- broken. So ask a better question: which runs cost far more than a typical
-- run, and what do they have in common?

WITH runs AS (
    SELECT trace_id, agent_name, tenant,
           max(cost_usd) FILTER (WHERE parent_span_id IS NULL) AS run_cost,
           count(*)                                            AS spans,
           count(*) FILTER (WHERE status = 'error')            AS errors
    FROM spans
    GROUP BY trace_id, agent_name, tenant
),
median AS (
    SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY run_cost) AS med FROM runs
)
SELECT
    CASE WHEN run_cost > 40 * med THEN 'over 40x median' ELSE 'normal' END AS bucket,
    count(*)                                        AS runs,
    round(avg(spans), 0)                            AS avg_spans,
    round(avg(100.0 * errors / spans), 1)           AS avg_error_pct,
    round(sum(run_cost), 2)                         AS total_cost_usd,
    round(100.0 * sum(run_cost) / sum(sum(run_cost)) OVER (), 1) AS pct_of_spend
FROM runs, median
GROUP BY 1
ORDER BY total_cost_usd DESC;

-- Look at that split before moving on.
--
-- A normal run is ~28 spans and fails 1.5% of the time. The expensive bucket
-- averages ~344 spans and fails ~13% of the time. Those are retry storms: a
-- provider had a bad minute, the framework retried, and the bill went with it.
--
-- Your 8% org-wide error rate is not "everything is slightly broken".
-- It is a couple of hundred runs out of sixty thousand.
--
-- An average would have hidden this completely. Keep that in mind in step 5,
-- where we have to roll these numbers up without destroying the tail.
