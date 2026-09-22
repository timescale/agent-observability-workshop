-- ============================================================================
-- ## 1. What one agent run looks like as data
-- ============================================================================
--
--   tiger db query -f sql/1-schema.sql
--
-- Before we talk about scale, look at a single run. One customer-support agent
-- handling one ticket. Nine spans.
--
-- The column names are not invented. They track the OpenTelemetry GenAI
-- semantic conventions, so what you learn here maps onto whatever emits your
-- telemetry:
--
--   gen_ai.operation.name  -> operation      gen_ai.usage.input_tokens -> input_tokens
--   gen_ai.agent.name      -> agent_name     gen_ai.conversation.id    -> conversation_id
--   gen_ai.tool.name       -> tool_name      error.type                -> error_type
--
-- Two caveats worth knowing. Those attributes are still "Development" status --
-- the spec is at open-telemetry/semantic-conventions-genai, and the older
-- opentelemetry.io page marks everything Deprecated purely because the spec
-- moved repos. And OTel deliberately defines no cost attribute at all, so
-- cost_usd borrows from Arize's OpenInference (llm.cost.total).
--
-- Note this is a PLAIN Postgres table. No hypertable yet. That's deliberate --
-- step 4 is where that earns its place, and you should see the problem first.
--
-- Safe to re-run.
-- ============================================================================

DROP TABLE IF EXISTS spans CASCADE;
DROP TABLE IF EXISTS model_prices CASCADE;

CREATE TABLE spans (
    -- when and how long
    start_time        timestamptz      NOT NULL,
    duration_ms       double precision NOT NULL,

    -- the tree. One flat table with a parent pointer is what Langfuse,
    -- LangSmith, Phoenix, Weave and Braintrust all converge on.
    span_id           text             NOT NULL,
    trace_id          text             NOT NULL,
    parent_span_id    text,

    -- who and what
    conversation_id   text,            -- gen_ai.conversation.id
    tenant            text             NOT NULL,   -- the cost-attribution axis
    agent_name        text             NOT NULL,   -- gen_ai.agent.name
    operation         text             NOT NULL,   -- gen_ai.operation.name
    tool_name         text,            -- gen_ai.tool.name, only on execute_tool

    -- the model call
    provider          text,            -- gen_ai.provider.name
    model             text,            -- gen_ai.request.model
    input_tokens      integer,         -- gen_ai.usage.input_tokens
    output_tokens     integer,         -- gen_ai.usage.output_tokens
    cache_read_tokens integer,         -- gen_ai.usage.cache_read.input_tokens
    cost_usd          numeric(12, 6),  -- llm.cost.total (OTel has no equivalent)

    -- how it went
    status            text             NOT NULL,   -- ok | error
    error_type        text,            -- error.type
    finish_reason     text             -- gen_ai.response.finish_reasons
);

-- Prices, so step 5 can show what it costs to reprice history.
-- Real systems materialise cost onto the span at write time -- changing a price
-- does NOT retroactively reprice anything. Keeping the table lets us prove that.
CREATE TABLE model_prices (
    provider           text NOT NULL,
    model              text NOT NULL,
    input_per_1m_usd   numeric(10, 4) NOT NULL,
    output_per_1m_usd  numeric(10, 4) NOT NULL,
    PRIMARY KEY (provider, model)
);

INSERT INTO model_prices VALUES
    ('anthropic', 'claude-sonnet-4',  3.0000, 15.0000),
    ('anthropic', 'claude-haiku-4',   0.8000,  4.0000),
    ('openai',    'gpt-5',            1.2500, 10.0000),
    ('openai',    'gpt-5-mini',       0.2500,  2.0000),
    ('google',    'gemini-2.5-pro',   1.2500, 10.0000);

-- ============================================================================
-- ## One run: "support-triage" handles ticket #4471
-- ============================================================================
-- Read the parent_span_id column. invoke_agent is the root; everything else
-- hangs off it. A chat span decides what to do, a tool span does it, another
-- chat span reads the result and decides again. That loop IS the agent.

INSERT INTO spans VALUES
--  start_time                    dur     span  trace  parent  conv      tenant    agent             operation       tool            provider     model              in    out  cache  cost      status  err   finish
('2026-09-22 14:00:00.000+00',  8420.0, 's01', 't001', NULL,   'c-4471', 'acme',   'support-triage', 'invoke_agent', NULL,           NULL,        NULL,              NULL, NULL, NULL, 0.012840, 'ok',   NULL, NULL),
('2026-09-22 14:00:00.120+00',   540.0, 's02', 't001', 's01',  'c-4471', 'acme',   'support-triage', 'plan',         NULL,           NULL,        NULL,              NULL, NULL, NULL, NULL,     'ok',   NULL, NULL),
('2026-09-22 14:00:00.700+00',  1180.0, 's03', 't001', 's01',  'c-4471', 'acme',   'support-triage', 'chat',         NULL,           'anthropic', 'claude-sonnet-4', 1840,  210,  1200, 0.008670, 'ok',   NULL, 'tool_calls'),
('2026-09-22 14:00:01.900+00',   310.0, 's04', 't001', 's01',  'c-4471', 'acme',   'support-triage', 'execute_tool', 'search_kb',    NULL,        NULL,              NULL, NULL, NULL, NULL,     'ok',   NULL, NULL),
('2026-09-22 14:00:02.230+00',   890.0, 's05', 't001', 's01',  'c-4471', 'acme',   'support-triage', 'chat',         NULL,           'anthropic', 'claude-sonnet-4',  920,   95,  1840, 0.002185, 'ok',   NULL, 'tool_calls'),
('2026-09-22 14:00:03.140+00',  2600.0, 's06', 't001', 's01',  'c-4471', 'acme',   'support-triage', 'execute_tool', 'fetch_order',  NULL,        NULL,              NULL, NULL, NULL, NULL,     'ok',   NULL, NULL),
('2026-09-22 14:00:05.760+00',   410.0, 's07', 't001', 's01',  'c-4471', 'acme',   'support-triage', 'execute_tool', 'check_refund', NULL,        NULL,              NULL, NULL, NULL, NULL,     'error','TimeoutError', NULL),
('2026-09-22 14:00:06.190+00',   380.0, 's08', 't001', 's01',  'c-4471', 'acme',   'support-triage', 'execute_tool', 'check_refund', NULL,        NULL,              NULL, NULL, NULL, NULL,     'ok',   NULL, NULL),
('2026-09-22 14:00:06.600+00',  1820.0, 's09', 't001', 's01',  'c-4471', 'acme',   'support-triage', 'chat',         NULL,           'anthropic', 'claude-sonnet-4', 1310,  240,  2760, 0.001985, 'ok',   NULL, 'stop');

-- ============================================================================
-- ## Read it
-- ============================================================================

-- The run, in order, indented by depth. This is the shape of every agent trace
-- you will ever look at.
SELECT
    to_char(start_time, 'HH24:MI:SS.MS')                  AS at,
    repeat('  ', CASE WHEN parent_span_id IS NULL THEN 0 ELSE 1 END)
        || operation
        || coalesce(' ' || tool_name, '')
        || coalesce(' [' || model || ']', '')             AS span,
    duration_ms::int                                      AS ms,
    input_tokens AS tok_in, output_tokens AS tok_out,
    cost_usd,
    status, error_type
FROM spans
ORDER BY start_time;

-- One line per run is what you actually want. Note the root span's cost is the
-- whole run -- rolled up at write time, so answering "what did this run cost"
-- is a single-row read rather than a recursive walk down the tree.
SELECT
    trace_id, agent_name, tenant,
    count(*)                                   AS spans,
    count(*) FILTER (WHERE operation = 'chat')         AS llm_calls,
    count(*) FILTER (WHERE operation = 'execute_tool') AS tool_calls,
    count(*) FILTER (WHERE status = 'error')           AS errors,
    sum(coalesce(input_tokens, 0) + coalesce(output_tokens, 0)) AS tokens,
    sum(cost_usd) FILTER (WHERE parent_span_id IS NULL)         AS run_cost_usd,
    max(duration_ms) FILTER (WHERE parent_span_id IS NULL)::int AS wall_ms
FROM spans
GROUP BY trace_id, agent_name, tenant;
