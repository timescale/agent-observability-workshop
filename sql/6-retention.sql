-- ============================================================================
-- ## 6. Throw the raw data away, keep the history
-- ============================================================================
--
--   tiger db query -f sql/6-retention.sql
--
-- This is the step that pays for the whole exercise.
--
-- Raw spans are expensive and lose value fast. Nobody debugs a specific agent
-- run from six weeks ago. But "what did agents cost us per customer last
-- quarter" and "when did the p99 start climbing" are questions people ask all
-- the time, and they are exactly the questions your trace vendor cannot answer
-- after its retention window closes.
--
-- Rollups are small. Keep them for years. Drop the raw spans on a schedule.
-- ============================================================================

-- Where we stand before.
SELECT
    (SELECT count(*) FROM spans)                                     AS raw_spans,
    (SELECT min(start_time)::date FROM spans)                        AS raw_oldest,
    pg_size_pretty(hypertable_size('spans'))                         AS raw_size,
    (SELECT count(*) FROM spans_1d)                                  AS daily_rows,
    (SELECT min(bucket)::date FROM spans_1d)                         AS daily_oldest;

-- ----------------------------------------------------------------------------
-- Drop raw spans older than 7 days
-- ----------------------------------------------------------------------------
-- Seven rather than thirty purely so you can watch it happen in a workshop.
-- In production this is the number your incident-response process needs, not
-- the number your analytics needs -- those are different questions with
-- different answers, which is the whole point.

SELECT add_retention_policy('spans', INTERVAL '7 days', if_not_exists => true);

-- The policy runs on a schedule. Don't wait -- do it now.
SELECT drop_chunks('spans', older_than => INTERVAL '7 days');

-- ============================================================================
-- ## What survived
-- ============================================================================

SELECT
    (SELECT count(*) FROM spans)                                     AS raw_spans,
    (SELECT min(start_time)::date FROM spans)                        AS raw_oldest,
    pg_size_pretty(hypertable_size('spans'))                         AS raw_size,
    (SELECT count(*) FROM spans_1d)                                  AS daily_rows,
    (SELECT min(bucket)::date FROM spans_1d)                         AS daily_oldest;

-- The 30-day questions still answer, from data whose raw rows no longer exist.
SELECT tenant, round(sum(cost_usd), 2) AS cost_usd_30d
FROM spans_1d
GROUP BY tenant
ORDER BY cost_usd_30d DESC
LIMIT 5;

SELECT agent_name,
       approx_percentile(0.99, rollup(latency))::int AS p99_ms_30d
FROM spans_1d
WHERE operation = 'chat'
GROUP BY agent_name
ORDER BY p99_ms_30d DESC
LIMIT 5;

SELECT bucket::date AS day, distinct_count(conversations) AS conversations
FROM conversations_1d
ORDER BY 1
LIMIT 5;

-- ----------------------------------------------------------------------------
-- And now try the same thing on raw spans
-- ----------------------------------------------------------------------------
-- Zero rows, because those chunks are gone. That is the trade, stated plainly:
-- you keep the shape of history forever and give up the ability to inspect an
-- individual span from before the window.

SELECT count(*) AS raw_spans_30_days_ago
FROM spans
WHERE start_time < now() - INTERVAL '20 days';

-- ============================================================================
-- ## Tear down when you're done
-- ============================================================================
-- Don't leave a service running you aren't using:
--
--   tiger service list
--   tiger service delete <service-id> --confirm
