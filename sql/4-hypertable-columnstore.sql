-- ============================================================================
-- ## 4. Model it as time-series
-- ============================================================================
--
--   tiger db query -f sql/4-hypertable-columnstore.sql
--
-- Two separate things happen here, and it matters that you don't conflate them:
--
--   1. HYPERTABLE  -- partitions the table by time into chunks. Helps queries
--      that filter by time, because the planner skips whole chunks.
--   2. COLUMNSTORE -- stores each chunk column-by-column, compressed. Helps
--      analytical queries that touch a few columns across many rows.
--
-- Step 3's queries mostly do NOT filter by time. So the hypertable alone will
-- barely move them. The columnstore is what does the work. Watch which is which.
--
-- Takes a couple of minutes on a small service.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Convert the existing table
-- ----------------------------------------------------------------------------
-- When you are CREATING a table, the modern form is
--     CREATE TABLE ... WITH (tsdb.hypertable, tsdb.partition_column = 'start_time')
-- available since TimescaleDB 2.20. We already have a table full of data, and
-- create_hypertable() is still the documented way to convert one in place.

SELECT create_hypertable(
    'spans',
    by_range('start_time', INTERVAL '1 day'),
    migrate_data  => true,
    if_not_exists => true
);

SELECT count(*) AS chunks FROM timescaledb_information.chunks
WHERE hypertable_name = 'spans';

-- ----------------------------------------------------------------------------
-- Enable the columnstore
-- ----------------------------------------------------------------------------
-- segmentby is the important choice. Pick the low-cardinality columns you
-- filter and group by -- here that is agent_name and operation. Rows sharing a
-- segmentby value are stored together, so a query for one agent reads only
-- that agent's compressed batches.
--
-- Note the syntax: ALTER TABLE ... SET (timescaledb.compress ...) was
-- DEPRECATED in 2.18. This is the current hypercore form.

ALTER TABLE spans SET (
    timescaledb.enable_columnstore,
    timescaledb.segmentby = 'agent_name, operation',
    timescaledb.orderby   = 'start_time DESC'
);

-- Size before.
SELECT pg_size_pretty(hypertable_size('spans')) AS rowstore_size;

-- Convert every chunk now. In production you would let a policy do this on a
-- delay -- see the bottom of this file.
--
-- convert_to_columnstore is a PROCEDURE, not a function, so it needs CALL and
-- cannot go in a SELECT. Hence the loop.
DO $$
DECLARE c regclass;
BEGIN
    FOR c IN SELECT show_chunks('spans') LOOP
        CALL convert_to_columnstore(c);
    END LOOP;
END $$;

-- Size after.
SELECT pg_size_pretty(hypertable_size('spans')) AS columnstore_size;

ANALYZE spans;

-- ============================================================================
-- ## Re-run the same questions
-- ============================================================================
-- Byte-for-byte the queries from step 3.

-- Q1. p99 latency by agent.
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT agent_name,
       count(*)                                                         AS spans,
       percentile_cont(0.99) WITHIN GROUP (ORDER BY duration_ms)::int   AS p99_ms
FROM spans
WHERE operation = 'chat'
GROUP BY agent_name
ORDER BY p99_ms DESC
LIMIT 10;

-- Q2. Cost by tenant.
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT tenant,
       count(*) FILTER (WHERE parent_span_id IS NULL) AS runs,
       round(sum(cost_usd) FILTER (WHERE parent_span_id IS NULL), 2) AS cost_usd
FROM spans
GROUP BY tenant
ORDER BY cost_usd DESC;

-- Q4. count(DISTINCT) per day -- the worst one in step 3.
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT date_trunc('day', start_time) AS day,
       count(DISTINCT conversation_id) AS conversations
FROM spans
GROUP BY 1
ORDER BY 1 DESC
LIMIT 7;

-- ----------------------------------------------------------------------------
-- And one the hypertable specifically helps: a time-bounded query
-- ----------------------------------------------------------------------------
-- This is where partitioning earns its keep. 24 hours out of 30 days means the
-- planner can ignore 29 chunks before reading anything. Look for
-- "Chunks excluded during planning" in the plan.

EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT agent_name, count(*) AS spans, round(avg(duration_ms)) AS avg_ms
FROM spans
WHERE start_time > now() - INTERVAL '24 hours'
GROUP BY agent_name
ORDER BY spans DESC
LIMIT 10;

-- ============================================================================
-- ## What actually changed -- and what didn't
-- ============================================================================
-- Measured on a free Tiger Cloud service, ~2M spans. Yours will differ; the
-- pattern won't.
--
--   storage                     320 MB -> 101 MB     3.2x smaller
--   Q1  p99 by agent            3234ms -> 1305ms     2.5x
--   Q3  tool error rates        1604ms ->  230ms     7x
--   Q2  cost by tenant          1999ms -> 1897ms     basically unchanged
--   Q4  count(DISTINCT) / day   5581ms -> 5724ms     no better. Slightly worse.
--   time-bounded, last 24h                 4.6ms     was a full scan before
--
-- Be suspicious of anyone who tells you a storage engine makes everything
-- faster. Read that list again:
--
--   * The columnstore wins big when a query touches a FEW columns across MANY
--     rows, because it only reads those columns. Q3 reads three. That's the 7x.
--   * It does nothing for Q4, because count(DISTINCT) is not waiting on I/O --
--     it is building a hash table of 200,000 distinct values. Compressing the
--     input doesn't make hashing cheaper.
--   * Q2 barely moves for the same reason: it scans nearly every row anyway.
--   * The hypertable is what makes the last query 4.6ms. Twenty-nine of thirty
--     chunks are excluded before a single row is read. That only works because
--     the query filters on the partition column.
--
-- So we are two for four. Step 5 fixes the other two, and neither fix is a
-- storage trick -- they are both about not doing the work twice.

-- ----------------------------------------------------------------------------
-- In production: let a policy do it
-- ----------------------------------------------------------------------------
-- Keep recent data in the rowstore where writes and single-row lookups are
-- cheap; age it into the columnstore once it has stopped changing.
-- add_columnstore_policy replaces the deprecated add_compression_policy.

-- Like convert_to_columnstore, this is a procedure. CALL, not SELECT.
CALL add_columnstore_policy('spans', after => INTERVAL '3 days', if_not_exists => true);

SELECT * FROM timescaledb_information.jobs WHERE proc_name = 'policy_compression';
