# Agent observability on Postgres — talk track

Source for the deck, plus what to say. Slides are separated by `---`; the **Notes**
under each are speaker notes, not slide content.

Built for **60 minutes**: ~45 walkthrough, ~15 Q&A. Timings in the headers are cumulative.
If you're running long, cut Act V (retention) — it's the most self-explanatory in the
replay.

Terminal is on screen for most of this. Slides carry the things a terminal can't show.

---

## Slide 1 — Title  ·  0:00

**Agent observability on Postgres**

Monitoring AI agents when there are hundreds of them

AlphaSignal × Tiger Data

> **Notes:** Name the deliverable immediately: by the end there's a repo they can run, and
> a dashboard over two million agent spans. Say the repo link is in the chat now and will
> be again at the end.

---

## Slide 2 — One agent is easy  ·  0:01

One agent, you read the logs.

Hundreds of agent workflows across an org is a different system.

> **Notes:** Short. This is the setup, don't dwell. The audience already lives this —
> don't explain what an agent is, they know better than we do.

---

## Slide 3 — This is not logs  ·  0:02

Every agent run emits: prompts · tool calls · model responses · latency · tokens · cost ·
errors · retries · outcomes

Most teams put that in a log pipeline.

**It's time-series and events.** Timestamped, append-only, aggregated over windows,
queried by trend.

> **Notes:** The reframe the whole session hangs on. Logs are for reading one thing.
> This data is for aggregating millions of things. Different shape, different tool.

---

## Slide 4 — Where this sits  ·  0:04

You'll probably buy a trace tool. **Build this once anyway**, so you know what it's doing
and what it can't do for you.

| Live debugging | Durable aggregate layer |
|---|---|
| Langfuse, Braintrust, Logfire, Phoenix | what we build today |
| one trace, right now | every trace, over a year |
| 30-day retention | as long as you want |

> **Notes:** Say this one out loud, carefully — it's the credibility slide.
>
> We are NOT telling anyone to rip out their trace vendor. Those tools are good at what
> they do. Two reasons to be disciplined here: Tiger discontinued its own OTel backend
> (Promscale) in 2023 and the announcement is still public, and Tiger's own agent
> framework ships Logfire. If we overclaim, someone will find both inside two minutes.
>
> The honest claim is narrow and strong: trace tools are priced and designed for recent,
> individual traces. Aggregate questions over long horizons are a different job.

---

## Slide 5 — Three months from now  ·  0:06

- The bill tripled. Nobody can say which agent did it.
- The p99 has been climbing. Nobody knows when it started.
- Finance asks what agents cost per customer last quarter. The traces were deleted on
  day 30.

> **Notes:** These are the questions, and they're all *aggregate over time*. Ask for a
> show of hands / chat reaction on the first one — it's nearly universal and it wakes
> people up.

---

## Slide 6 — What to capture  ·  0:08

Don't invent column names. **OpenTelemetry GenAI semantic conventions:**

```
gen_ai.operation.name    chat | execute_tool | invoke_agent | plan
gen_ai.agent.name        which agent
gen_ai.conversation.id   session / thread
gen_ai.usage.input_tokens / output_tokens / cache_read.input_tokens
gen_ai.tool.name         which tool
error.type               why it failed
```

Two caveats: these are still **Development** status, and OTel defines **no cost
attribute** — that one's borrowed from Arize's OpenInference.

> **Notes:** Worth 30 seconds on why standards matter here: if your columns match the
> spec, an OTel collector can write into this schema with a mapping instead of a
> redesign. Mention the spec moved to its own repo, so the old page showing everything
> "Deprecated" is a migration artefact, not reality — someone will check.

---

## Slide 7 — The shape everyone converges on  ·  0:10

```
session  ─┐
          └── trace (one agent run)
                 ├── span  invoke_agent      ← root, carries the rolled-up cost
                 ├── span  chat              ← an LLM call
                 ├── span  execute_tool      ← a tool call
                 └── span  chat
```

One flat table. `parent_span_id`. That's it.

Langfuse, LangSmith, Phoenix, Weave, Braintrust — all the same. Nobody uses closure
tables. Nobody runs recursive CTEs on the hot path.

> **Notes:** Pre-empt the obvious objection: yes, this is denormalised, and yes, trace
> attributes get copied onto every span. That's deliberate — it's what makes the
> aggregate queries cheap, and it's what the real systems do.
>
> **→ Switch to terminal. Run `sql/1-schema.sql`.** Nine spans, one support ticket. Walk
> the parent_span_id column and point out the loop: chat decides, tool acts, chat reads
> the result. Note the failed `check_refund` and the retry right after it — plant that
> seed, it comes back in Act III.

---

## Slide 8 — Now make it an org  ·  0:14

300 agents · 12 tenants · 30 days · ~2 million spans

Generated server-side. Nothing to download.

> **Notes:** **→ Terminal: `sql/2-generate-data.sql`. This takes ~85 seconds — you need
> to talk through it.**
>
> Fill the time with the distribution, because it's the most important design decision
> in the dataset:
> - median run is 12 spans, p95 is ~126
> - about 1 in 330 runs is a *retry storm*: 500–1500 spans, mostly failing
> - that's not invented — there's a documented case of 847 spans in one conversation
>   during a provider outage, because the framework kept retrying
>
> If it finishes early, show `sql/2-generate-data.sql` and point at the lognormal.
> If it runs long, keep going — the tail is genuinely the interesting part.

---

## Slide 9 — Four questions  ·  0:16

1. Which agents are slow? (p99 latency)
2. What is each customer costing us?
3. Which tools fail?
4. How many distinct conversations per day?

Nothing exotic. Every team asks these.

> **Notes:** **→ Terminal: `sql/3-baseline.sql`.** Let the timings land:
> 3.2s / 2.0s / 1.6s / 5.6s. Four sequential scans.
>
> Then the money query at the bottom. Org-wide error rate is 8%. Useless number. Split
> runs by cost and it resolves: normal runs 28 spans and 1.5% errors, expensive runs 344
> spans and 13% errors. **Your 8% is a couple hundred runs out of sixty thousand.**
>
> This is the emotional peak of the first half. Slow down here.

---

## Slide 10 — Two different fixes  ·  0:22

**Hypertable** — partitions by time. Helps queries that *filter* by time.

**Columnstore** — stores each chunk column-by-column, compressed. Helps queries that
touch *few columns across many rows*.

They are not the same thing and they do not help the same queries.

> **Notes:** **→ Terminal: `sql/4-hypertable-columnstore.sql`. The conversion takes
> ~2 minutes — more dead air.**
>
> Talk through the segmentby choice: `agent_name, operation` because they're low
> cardinality and they're what we filter and group by. Rows sharing a segmentby value
> get stored together.
>
> Also worth saying while you wait: the syntax here is current as of 2.18+.
> `ALTER TABLE ... SET (timescaledb.compress ...)` is deprecated; most tutorials online
> are still on it. And `convert_to_columnstore` is a *procedure* — `CALL`, not `SELECT`.

---

## Slide 11 — Two out of four  ·  0:26

|  | plain | columnstore |
|---|---|---|
| storage | 320 MB | **102 MB** |
| tool error rates | 1,604 ms | **230 ms** |
| p99 by agent | 3,234 ms | 1,305 ms |
| cost by tenant | 1,999 ms | 1,897 ms |
| distinct conversations | 5,581 ms | **5,724 ms** ← worse |
| last 24h, time-filtered | full scan | **4.6 ms** |

> **Notes:** Be loud about the row that got worse. This is the most trust-building
> moment in the talk — everyone has sat through a vendor demo where every number
> improves.
>
> Why: `count(DISTINCT)` isn't waiting on I/O, it's hashing 20,000 values. Compressing
> the input doesn't make hashing cheaper. And cost-by-tenant scans nearly every row
> anyway.
>
> The 4.6 ms line is the hypertable, not the columnstore — 29 of 30 chunks excluded
> before reading anything. Only works because the query filters on the partition column.

---

## Slide 12 — You cannot average a p99  ·  0:30

```
   bucket 1: p99 = 900ms          avg(900, 400) = 650ms
   bucket 2: p99 = 400ms          the real p99  = 880ms      ✗ wrong
```

Store a **sketch**, not a number. Sketches merge.

```sql
percentile_agg(duration_ms)                       -- in the rollup
approx_percentile(0.99, rollup(latency))          -- reading it back
```

> **Notes:** This is the single best idea in the session. Spend a minute.
>
> The reason people don't pre-aggregate latency is that they think it makes the number a
> lie — and with a stored p99, they're right. A sketch is a small summary of the whole
> distribution, so merging two gives a correct percentile over the union.
>
> Same trick for distinct counts: hyperloglog instead of a hash set.
>
> **→ Terminal: `sql/5-rollups.sql`. Run it section by section with `-c` — cagg refreshes
> can't run inside the transaction `-f` uses.**

---

## Slide 13 — Rollups are shaped like questions  ·  0:36

First attempt: hyperloglog in the 5-minute rollup, grouped by agent × tenant × operation.

→ 178,000 sketches to merge. **5,590 ms.** No better than the raw table.

Second attempt: one rollup, grouped only by day.

→ **1.1 ms. 440 kB instead of 65 MB.**

> **Notes:** Tell this as a mistake, because it was one. It's more useful than any
> feature on its own.
>
> You don't get one magic aggregate. You get aggregates shaped like your questions —
> which is fine, because they're cheap. The corollary: group by fewer dimensions than you
> think you need. Our three `spans_*` rollups together are bigger than the compressed raw
> table.

---

## Slide 14 — The scoreboard  ·  0:40

|  | plain | columnstore | rollup |
|---|---|---|---|
| p99 by agent | 3,234 ms | 1,305 ms | **660 ms** |
| cost by tenant | 1,999 ms | 1,897 ms | **605 ms** |
| distinct conversations | 5,581 ms | 5,724 ms | **1.1 ms** |

Accuracy: p99 sketch 9,584 vs 9,487 exact. Conversations 20,000 vs 20,001.

> **Notes:** Say the accuracy numbers out loud. Anything labelled "approx" deserves the
> question "how wrong?", and having the answer ready is the difference between a demo and
> an argument.

---

## Slide 15 — Live  ·  0:42

*(Grafana on screen)*

> **Notes:** **→ Demo.** Every panel but one reads a continuous aggregate, which is why
> it's responsive on the smallest service Tiger Cloud sells.
>
> The exception is the retry-storm table — it scans raw spans on purpose. That's the one
> question worth paying a full scan for.
>
> Land on that panel and connect it back to Act III: these are the runs that were hiding
> inside the 8%.

---

## Slide 16 — Throw the raw data away  ·  0:48

Nobody debugs a specific agent run from six weeks ago.

Everybody asks what agents cost per customer last quarter.

```
raw spans     1,989,321 → 516,693      102 MB → 26 MB      keep 7 days
daily rollup  unchanged, back to day 1                     keep for years
```

> **Notes:** **→ Terminal: `sql/6-retention.sql`.** Then re-run the 30-day cost and p99
> queries and show they still answer — from data whose raw rows no longer exist.
>
> State the trade plainly: you keep the shape of history and give up inspecting an
> individual span from before the window. That's the same trade your trace vendor makes,
> except you chose the window.

---

## Slide 17 — What to take away  ·  0:52

- Agent telemetry is time-series, not logs. Model it that way.
- Match the OTel GenAI conventions so you're not inventing a schema.
- Storage tricks don't help every query. Measure, don't assume.
- Sketches are what make pre-aggregation honest.
- Rollups are shaped like questions. Build several; they're cheap.
- Keep the aggregates long after you drop the raw spans.

**github.com/timescale/agent-observability-workshop**

> **Notes:** The repo runs free end to end — the dataset is ~120 MB against a 750 MB free
> tier. Say that explicitly; it removes the last excuse not to try it.

---

## Slide 18 — Q&A  ·  0:55

**github.com/timescale/agent-observability-workshop**

> **Notes:** Questions worth pre-loading:
>
> *"Why not ClickHouse / a real observability backend?"* — Fair. If you already run one,
> use it. The case for Postgres is that agent telemetry is most valuable *joined to your
> application data* — customers, plans, feature flags — and that join is free here and
> expensive across systems.
>
> *"Does this replace Langfuse?"* — No. Slide 4. Different jobs.
>
> *"What about the prompt and response text?"* — Deliberately not in this schema. Big,
> sensitive, and rarely aggregated. Keep it in object storage or your trace tool and
> reference it by span id.
>
> *"How does data actually get in?"* — Out of scope today, and worth saying so plainly:
> an OTel collector with a Postgres exporter, or a batched writer in your agent
> framework. Batch it — row-at-a-time inserts will not keep up.
>
> *"Free tier really?"* — Yes, ~120 MB of 750 MB. Shared CPU, so timings vary.
