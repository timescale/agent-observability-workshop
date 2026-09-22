-- ============================================================================
-- ## 2. Now make it an org
-- ============================================================================
--
--   tiger db query -f sql/2-generate-data.sql
--
-- 300 agents, 12 tenants, 30 days. Generated server-side, so there is nothing
-- to download and nothing to upload -- it runs in well under a minute.
--
-- The shape matters more than the size. Span counts per run are lognormal:
-- median 12, p95 ~126. And about 1 in 330 runs is a RETRY STORM -- 500 to 1500
-- spans, mostly failing, because a provider had a bad minute and the framework
-- kept retrying. That is not a synthetic flourish: a documented real case hit
-- 847 spans in a single conversation during an outage.
--
-- Those runs are the villain of this workshop. Averages hide them completely.
--
-- ----------------------------------------------------------------------------
-- SCALE: edit run_count below.
--   60000  -> ~2M spans. Fits a free Tiger Cloud service. Default.
--   600000 -> ~20M spans. Needs a paid service. Same queries, same plans.
-- ----------------------------------------------------------------------------
--
-- Safe to re-run: truncates first.
-- ============================================================================

TRUNCATE spans;

INSERT INTO spans
WITH params AS (
    SELECT 60000 AS run_count
),
pools AS (
    SELECT
        ARRAY['support','sales','finance','engineering','ops',
              'research','legal','people','marketing','security']            AS domains,
        ARRAY['triage','summarize','enrich','classify','route',
              'draft','review','extract','monitor','reconcile']              AS functions,
        ARRAY['acme','globex','initech','umbrella','soylent','hooli',
              'stark','wayne','cyberdyne','tyrell','aperture','wonka']       AS tenants,
        ARRAY['search_kb','fetch_order','check_refund','send_email','query_db',
              'call_api','read_file','write_file','list_tickets','update_crm',
              'geocode','translate','summarize_doc','fetch_invoice','post_slack',
              'create_task','check_inventory','validate_address','run_report',
              'fetch_contract']                                              AS tools,
        ARRAY['claude-sonnet-4','claude-haiku-4','gpt-5','gpt-5-mini','gemini-2.5-pro'] AS models,
        ARRAY['anthropic','anthropic','openai','openai','google']            AS providers,
        ARRAY[3.00, 0.80, 1.25, 0.25, 1.25]                                  AS in_price,
        ARRAY[15.00, 4.00, 10.00, 2.00, 10.00]                               AS out_price
),
runs AS (
    SELECT
        g                                                           AS run_no,
        'tr-' || lpad(g::text, 8, '0')                              AS trace_id,
        now() - (random() * interval '30 days')                     AS t0,
        (random() < 0.003)                                          AS is_storm,
        -- which agent, tenant, model this run uses
        1 + floor(random() * 10)::int                               AS d_i,
        1 + floor(random() * 10)::int                               AS f_i,
        1 + floor(random() * 3)::int                                AS v_i,
        1 + floor(random() * 12)::int                               AS t_i,
        -- model mix: cheap models do most of the volume, as in real life
        CASE WHEN random() < 0.35 THEN 2
             WHEN random() < 0.55 THEN 4
             WHEN random() < 0.80 THEN 1
             WHEN random() < 0.93 THEN 3
             ELSE 5 END                                             AS m_i
    FROM generate_series(1, (SELECT run_count FROM params)) g
),
sized AS (
    SELECT r.*,
           CASE WHEN r.is_storm
                THEN 500 + (random() * 1000)::int
                ELSE least(400, greatest(3, (12 * exp(1.4 * random_normal()))::int))
           END AS span_count
    FROM runs r
),
raw AS (
    SELECT
        s.*,
        seq,
        -- first span of a run is the agent invocation; the rest alternate
        CASE WHEN seq = 1 THEN 'invoke_agent'
             WHEN seq = 2 THEN 'plan'
             WHEN seq % 2 = 1 THEN 'chat'
             ELSE 'execute_tool' END                                AS operation,
        random()                                                    AS r_err,
        random()                                                    AS r_tool,
        random()                                                    AS r_tok
    FROM sized s, LATERAL generate_series(1, s.span_count) seq
),
built AS (
    SELECT
        -- spread spans across the run; storms are slow because they retry
        raw.t0 + (seq * (CASE WHEN is_storm THEN 180 ELSE 420 END
                         + random() * 600) * interval '1 millisecond')       AS start_time,
        -- Agents are not interchangeable. A handful are genuinely slow -- bigger
        -- prompts, worse tools, a model that thinks longer. Derive a stable
        -- multiplier from the agent so "which agents are slow" has a real answer.
        (CASE WHEN operation = 'chat'         THEN 300 + random() * 3000
              WHEN operation = 'execute_tool' THEN  40 + random() * 2500
              WHEN operation = 'plan'         THEN 100 + random() * 600
              ELSE 0 END)
        * (CASE WHEN (d_i * 10 + f_i) % 17 = 0 THEN 3.2      -- ~6% of agents are slow
                WHEN (d_i * 10 + f_i) % 7  = 0 THEN 1.8
                ELSE 0.7 + ((d_i * 10 + f_i) % 5) * 0.15 END)
        * (CASE WHEN is_storm THEN 1.6 ELSE 1.0 END)                         AS duration_ms,
        'sp-' || run_no || '-' || seq                                        AS span_id,
        trace_id,
        CASE WHEN seq = 1 THEN NULL ELSE 'sp-' || run_no || '-1' END         AS parent_span_id,
        'cv-' || (run_no / 3)                                                AS conversation_id,
        p.tenants[t_i]                                                       AS tenant,
        p.domains[d_i] || '-' || p.functions[f_i] || '-v' || v_i             AS agent_name,
        operation,
        CASE WHEN operation = 'execute_tool'
             THEN p.tools[1 + floor(r_tool * 20)::int] END                    AS tool_name,
        CASE WHEN operation = 'chat' THEN p.providers[m_i] END               AS provider,
        CASE WHEN operation = 'chat' THEN p.models[m_i] END                  AS model,
        CASE WHEN operation = 'chat' THEN (400 + r_tok * 4000)::int END      AS input_tokens,
        CASE WHEN operation = 'chat' THEN (50 + r_tok * 600)::int END        AS output_tokens,
        CASE WHEN operation = 'chat' THEN (r_tok * 3000)::int END            AS cache_read_tokens,
        -- storms fail most of the way; healthy runs fail ~1.5% of spans
        CASE WHEN is_storm AND seq > 3 THEN (r_err < 0.75)
             ELSE (r_err < 0.015) END                                        AS failed,
        m_i, is_storm, seq, run_no, span_count, r_err,
        p.in_price[m_i]  AS in_price,
        p.out_price[m_i] AS out_price
    FROM raw, pools p
),
priced AS (
    SELECT *,
        CASE WHEN operation = 'chat'
             THEN round(((input_tokens  * in_price)
                       + (output_tokens * out_price)) / 1000000.0, 6)
        END AS span_cost
    FROM built
)
SELECT
    start_time,
    duration_ms,
    span_id, trace_id, parent_span_id, conversation_id,
    tenant, agent_name, operation, tool_name, provider, model,
    input_tokens, output_tokens, cache_read_tokens,
    -- Real systems roll the run's cost onto the root span at write time, so
    -- "what did this run cost" is a single-row read. We do the same.
    CASE WHEN seq = 1
         THEN sum(span_cost) OVER (PARTITION BY trace_id)
         ELSE span_cost END                                  AS cost_usd,
    CASE WHEN failed THEN 'error' ELSE 'ok' END              AS status,
    CASE WHEN failed THEN
        CASE (r_err * 1000)::int % 4
             WHEN 0 THEN 'TimeoutError'
             WHEN 1 THEN 'RateLimitError'
             WHEN 2 THEN 'UpstreamError'
             ELSE 'ToolExecutionError' END
    END                                                      AS error_type,
    CASE WHEN operation = 'chat'
         THEN CASE WHEN failed THEN 'error'
                   WHEN seq = span_count THEN 'stop'
                   ELSE 'tool_calls' END END                 AS finish_reason
FROM priced;

-- ============================================================================
-- ## What did we just make?
-- ============================================================================

SELECT
    count(*)                                        AS spans,
    count(DISTINCT trace_id)                        AS runs,
    count(DISTINCT agent_name)                      AS agents,
    count(DISTINCT tenant)                          AS tenants,
    round(count(*)::numeric / 30)                   AS spans_per_day,
    round(100.0 * count(*) FILTER (WHERE status = 'error') / count(*), 2) AS error_pct,
    round(sum(cost_usd) FILTER (WHERE parent_span_id IS NULL), 2)         AS total_cost_usd
FROM spans;
