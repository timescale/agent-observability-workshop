# Agent observability on Postgres

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/timescale/agent-observability-workshop)

One agent is easy to watch. Hundreds of agent workflows across an org is a different
system — and the data it throws off is not logs. It's time-series and events: prompts,
tool calls, latency, tokens, cost, errors, retries, outcomes.

In this workshop you build the monitoring layer for that, on Postgres, from an empty
table to a live dashboard, in six steps.

**You'll probably buy a trace tool. Build this once anyway, so you know what it's doing
and what it can't do for you.** The moment that matters is three months out: the bill
triples and you can't explain why, the p99 walks and you can't see when it started, or
finance asks what agents cost per customer last quarter and your vendor deleted the
traces on day 30. This isn't a pitch to rip anything out. Langfuse, Braintrust, Logfire
and friends are good at live debugging. This is the durable aggregate layer underneath.

## What you'll learn

- **What to capture on every agent run**, using the OpenTelemetry GenAI semantic
  conventions rather than invented column names
- **How to model agent activity as events and time-series** — one flat table, an
  adjacency list, and why nobody runs recursive CTEs on the hot path
- **Which storage tricks help which queries**, including two that don't help at all
- **Percentile sketches**, because you cannot average a p99 and get a p99
- **Real-time dashboards** on continuous aggregates, not raw spans
- **What to throw away**, and how to keep answering 30-day questions after you do

## Before the workshop

Two things, and only the first one has an unpredictable tail. Do it the day before.

### 1. Create a Tiger Cloud service

Sign up at [tigerdata.com](https://www.tigerdata.com/) and create a service in the
console. **Pick the smallest paid size — 0.5 CPU / 2 GB.** New accounts get trial credit
that covers this many times over, and it matters: the free tier is shared CPU, which makes
every timing in this workshop noisy and roughly doubles the waiting.

### 2. Open the Codespace

Click the badge. First boot installs the Tiger CLI and starts Grafana; it takes a few
minutes and you'll see a banner when it's done. You can do this during the session — it's
the account signup that you don't want to be doing live.

Then:

```bash
tiger auth login --headless
```

`--headless` prints a short code and a URL to open in any browser. It's the flow designed
for a terminal that can't open your browser, which is exactly a Codespace.

If you'd rather create the service from the terminal than the console:

```bash
tiger service create --name agent-obs --cpu 500 --memory 2
```

Creating a service also makes it your **default**, which is why no command below needs a
service ID.

## The workshop

Six steps. Run them in order — each builds on the last. Every step below tells you what
it is, why you're doing it, and what you should see.

```bash
tiger db query -f sql/1-schema.sql
```

No service ID needed: creating a service made it your default.

> **One exception.** `sql/5-rollups.sql` must be run section by section with `-c`, not
> with `-f`. Continuous aggregate refreshes cannot run inside the transaction that `-f`
> wraps a file in. There's a note at the top of that file.

---

### Step 1 — One agent run, nine spans

```bash
tiger db query -f sql/1-schema.sql
```

**What this is.** The table, and a single hand-written agent run: one support agent
handling one ticket.

**Why start here.** Before anything about scale, you need to know what one run *is* as
data. Also note the table is plain Postgres — no hypertable, no compression. You should
see the problem before you see the fix.

**What you should see.** The run rendered as a tree, and then collapsed to one row:

```
 at           │ span                      │ ms   │ tok_in │ cost_usd │ status │ error_type
 14:00:00.000 │ invoke_agent              │ 8420 │        │ 0.012840 │ ok     │
 14:00:00.120 │   plan                    │  540 │        │          │ ok     │
 14:00:00.700 │   chat [claude-sonnet-4]  │ 1180 │   1840 │ 0.008670 │ ok     │
 14:00:01.900 │   execute_tool search_kb  │  310 │        │          │ ok     │
 14:00:02.230 │   chat [claude-sonnet-4]  │  890 │    920 │ 0.002185 │ ok     │
 14:00:03.140 │   execute_tool fetch_order│ 2600 │        │          │ ok     │
 14:00:05.760 │   execute_tool check_refund│ 410 │        │          │ error  │ TimeoutError
 14:00:06.190 │   execute_tool check_refund│ 380 │        │          │ ok     │
 14:00:06.600 │   chat [claude-sonnet-4]  │ 1820 │   1310 │ 0.001985 │ ok     │
```

**The point.** Read the `parent_span_id` column and you can see the agent loop: a `chat`
span decides what to do, an `execute_tool` span does it, another `chat` reads the result
and decides again. Note rows 7 and 8 — a tool timed out and was retried. Hold onto that;
it comes back in step 3 at a scale that costs real money.

The column names track the OpenTelemetry GenAI conventions (`gen_ai.operation.name`,
`gen_ai.usage.input_tokens`, `gen_ai.agent.name`), so this schema maps onto whatever
emits your telemetry instead of being something we invented.

---

### Step 2 — Make it an org

```bash
tiger db query -f sql/2-generate-data.sql
```

**What this is.** 300 agents, 12 tenants, 30 days of traffic. Generated entirely
server-side — nothing to download, nothing to upload.

**Why.** One run teaches you the shape. The questions that matter only get hard at
volume, and you can't feel that with nine rows.

**What you should see.** About **30 seconds**, then:

```
 spans   │ runs  │ agents │ tenants │ spans_per_day │ error_pct │ total_cost_usd
 2013057 │ 60000 │ 300    │ 12      │ 67102         │ 8.43      │ 4733.42
```

**The point.** The distribution matters more than the row count. Runs are lognormal —
median 12 spans, p95 around 126 — and roughly **1 in 330 is a retry storm**: 500 to 1500
spans, mostly failing, because a provider had a bad minute and the framework kept
retrying. That isn't a synthetic flourish; there's a documented case of 847 spans in one
conversation during an outage.

Hold that 8.43% error rate in your head. It's about to turn out to be misleading.

---

### Step 3 — Ask the obvious questions

```bash
tiger db query -f sql/3-baseline.sql
```

**What this is.** Four questions every team with agents in production asks weekly, run
against the plain table, with `EXPLAIN ANALYZE` on each.

**Why.** To establish the baseline honestly, and to see *why* it's slow rather than just
that it is.

**What you should see.** Four sequential scans, and these timings:

| | |
|---|---|
| Which agents are slow? (p99 latency) | **1,554 ms** |
| What is each customer costing us? | **981 ms** |
| Which tools fail? | **733 ms** |
| Distinct conversations per day | **2,482 ms** |

Then the query at the bottom of the file, which is the one that matters:

```
 bucket          │ runs  │ avg_spans │ avg_error_pct │ total_cost_usd │ pct_of_spend
 normal          │ 58993 │ 28        │ 1.5           │ 3204.91        │ 67.7
 over 40x median │  1007 │ 350       │ 12.5          │ 1528.50        │ 32.3
```

(Your exact figures will differ — the data is randomly generated. The shape won't.)

**The point.** That 8.43% org-wide error rate told you nothing useful — it couldn't
distinguish "everything is slightly broken" from "a few things are very broken." Split
runs by cost and it resolves immediately: normal runs are 28 spans and fail 1.5% of the
time, while **1,007 runs out of 60,000 average 350 spans, fail 12.5% of the time, and
take a third of total spend.**

An average would have hidden this completely. Remember that in step 5, where we have to
pre-aggregate these numbers without destroying the tail.

---

### Step 4 — Model it as time-series

```bash
tiger db query -f sql/4-hypertable-columnstore.sql
```

**What this is.** Two distinct changes that people routinely conflate. A **hypertable**
partitions by time so the planner can skip whole chunks. A **columnstore** stores each
chunk column-by-column, compressed, so analytical queries read less.

**Why.** Because they help different queries, and knowing which is which is the actual
skill.

**What you should see.** About 40 seconds of work, 31 chunks, and:

```
 rowstore_size:     329 MB
 columnstore_size:  105 MB
```

Then the same queries re-run:

| | plain | columnstore | |
|---|---|---|---|
| Which tools fail? | 733 ms | **148 ms** | 4.9× |
| p99 latency by agent | 1,554 ms | 651 ms | 2.4× |
| Cost by tenant | 981 ms | 867 ms | *~nothing* |
| Distinct conversations/day | 2,482 ms | **3,040 ms** | *worse* |
| Last 24 hours, time-filtered | full scan | **4.5 ms** | chunk exclusion |

**The point.** Be suspicious of anyone who tells you a storage engine makes everything
faster. Two of four queries barely moved, and one got *worse*.

The columnstore wins when a query touches a few columns across many rows — "which tools
fail" reads three columns, hence 4.9×. It does nothing for `count(DISTINCT)`, because that
query isn't waiting on disk, it's building a hash table of 20,000 values; compressing the
input doesn't make hashing cheaper. Cost-by-tenant scans nearly every row anyway.

The 4.5 ms row is the **hypertable**, not the columnstore — 29 of 30 chunks excluded
before reading a single row. That only works because the query filters on the partition
column, which is the whole reason you choose one.

Two out of four. Step 5 fixes the rest, and neither fix is a storage trick.

---

### Step 5 — Stop doing the work twice

```bash
# section by section with -c, NOT -f (see the note at the top of the file)
```

**What this is.** Continuous aggregates: 5-minute rollups, then hourly built on those,
then daily built on those. Plus two things that aren't ordinary SQL — percentile sketches
and hyperloglog.

**Why.** Cost-by-tenant and distinct-conversations didn't improve in step 4 because
neither is a storage problem. Both recompute yesterday's answer every single time you
ask. Stop doing that.

**What you should see.** Three rollups, then:

| | plain | columnstore | rollup |
|---|---|---|---|
| p99 latency by agent | 1,554 ms | 651 ms | **215 ms** |
| Cost by tenant | 981 ms | 867 ms | **119 ms** |
| Distinct conversations/day | 2,482 ms | 3,040 ms | **1.2 ms** |

And the accuracy comparison the file runs for you:

| | approximate | exact | |
|---|---|---|---|
| p99 latency | 9,584 ms | 9,579 ms | 0.05% high |
| distinct conversations | 20,000 | 20,001 | 0.005% low |

**The point — two of them, and the second is the one people miss.**

**Sketches are what make pre-aggregation honest.** You cannot average two p99s and get a
p99; that answer is simply wrong. `percentile_agg` stores a *sketch* — a small summary of
the distribution — and `rollup()` merges sketches, so a 30-day p99 computed from
5-minute buckets is correct. Without that, every pre-aggregated latency number is a lie.

**A rollup is only fast for the question it was shaped for.** Our first attempt put
hyperloglog in the 5-minute rollup alongside the latency sketch, grouped by agent ×
tenant × operation — which is what the dashboard slices by. Asking it for distinct
conversations per day then meant merging **239,060 sketches: 512 ms, out of a 44 MB
rollup.** A second rollup grouped only by day holds **31 sketches, answers in 1.2 ms, and
occupies 632 kB** — 400× faster and 70× smaller, for the same number.

Worth knowing how much the instance matters: on shared CPU that same wrong-shaped rollup
took **5,590 ms** — no better than scanning the raw table at all. Better hardware hid the
mistake rather than fixing it.

You don't get one magic aggregate. You get several, shaped like your questions, and
they're cheap. Note also that the three `spans_*` rollups together are larger than the
compressed raw table — group by fewer dimensions than you think you need.

---

### Step 6 — Throw the raw data away

```bash
tiger db query -f sql/6-retention.sql
```

**What this is.** A retention policy that drops raw spans older than 7 days, while the
rollups keep everything.

**Why.** This is the step that pays for the whole exercise. Nobody debugs a specific
agent run from six weeks ago. Everybody asks what agents cost per customer last quarter —
and that's exactly the question a trace vendor can't answer once its window closes.

**What you should see.**

```
                 before          after
 raw spans       2,013,057   →   494,988
 raw size        102 MB      →   26 MB
 raw oldest      2026-08-31  →   2026-09-23
 daily rollup    178,052 rows, still back to 2026-08-31
```

Then the 30-day cost, p99 and conversation-count queries **still answering** — from data
whose raw rows no longer exist. And a final query against raw spans older than 20 days
returning `0`.

**The point.** State the trade plainly: you keep the shape of history indefinitely and
give up the ability to inspect an individual span from before the window. That is the same
trade your trace vendor makes on your behalf — except here you chose the window, and the
aggregates are yours.

---

### Step 7 — The dashboard

Grafana is already running on port 3000. Point it at your service:

```bash
scripts/grafana-env.sh agent-obs
```

**What this is.** Six panels over the continuous aggregates: throughput, error rate, p99
by agent, spend by tenant, distinct conversations, and a retry-storm hunt.

**Why.** Everything so far has been a terminal. "Real-time" has to mean something you
can watch.

**What you should see.** The script reads your connection string from the Tiger CLI,
writes a gitignored `.env`, and restarts Grafana. Open the forwarded port 3000 — the
**Agent observability** dashboard is already provisioned, refreshing every 10 seconds.

**The point.** Every panel but one reads a **continuous aggregate**, not the raw table.
That's why it stays responsive on the smallest service Tiger Cloud offers. The exception
is the retry-storm table, which scans raw spans on purpose — that's the one question
worth paying a full scan for, and it's where the 940 runs from step 3 show up by name.

---

## Scoreboard

Measured on **0.5 CPU / 2 GB** with 2,013,057 spans, median of three runs. Compare the
*ratios* between columns rather than the milliseconds — your numbers will differ.

| | plain | columnstore | rollup |
|---|---|---|---|
| p99 latency by agent | 1,554 ms | 651 ms | **215 ms** |
| Cost by tenant | 981 ms | 867 ms | **119 ms** |
| Tool error rates | 733 ms | **148 ms** | — |
| Distinct conversations/day | 2,482 ms | 3,040 ms | **1.2 ms** |
| Last 24 hours, time-filtered | full scan | **4.5 ms** | — |
| Table size | 329 MB | **105 MB** | 26 MB after retention |

Step timings: generation ~30 s, columnstore conversion ~40 s, rollups ~40 s.

## Need help?

- **During the session:** ask in the chat.
- **Any other time:** [Tiger Data docs](https://www.tigerdata.com/docs) or
  [Community Slack](https://slack.timescale.com).

## Troubleshooting

**`... is a procedure (SQLSTATE 42809)`**
`convert_to_columnstore` and `add_columnstore_policy` are procedures, not functions. They
need `CALL`, and fail inside a `SELECT`. The workshop files already do this correctly; if
you're adapting them, watch for it.

**`cannot run inside a transaction block (SQLSTATE 25001)`**
You ran `sql/5-rollups.sql` with `-f`. `tiger db query -f` wraps a file in one
transaction, and continuous aggregate refreshes need their own. Run the sections with
`-c`.

**No port 3000 in the Ports tab / Grafana isn't there**
Grafana runs as a sibling container, and `postStartCommand` can fire before the Docker
daemon inside the Codespace is accepting connections — in which case nothing ever binds
3000 and there is no obvious error. Bring it up by hand:

```bash
docker compose -f .devcontainer/docker-compose.yml up -d
```

Then check `docker ps` shows `grafana`, and `curl -sf localhost:3000/api/health`. The
port should appear in the Ports tab within a few seconds. `.devcontainer/post-start.sh`
waits for the daemon to avoid this, but a slow start can still outrun it.

**Grafana says `database "tsdbadmin" does not exist`**
`.env` has an empty `TIGER_DATABASE`. Re-run `scripts/grafana-env.sh`.

**A long query drops with `conn closed`**
Use `tiger db query --timeout 0` for the slow ones. On small instances, very heavy
operations — `CREATE TABLE AS SELECT` over two million rows, say — can drop the connection
regardless. Nothing in the workshop does that, but it's where the ceiling is.

**The service went read-only**
You ran out of storage. The default dataset needs about 350 MB before the columnstore
converts it; if you raised `run_count` in `sql/2-generate-data.sql`, raise the instance
size too. Check with `tiger service list`.

**Numbers don't match the table above**
Expected — your data is randomly generated, and instance size moves everything. Compare
the *ratios* between columns, not the absolute milliseconds. On the free tier instead of
0.5 CPU / 2 GB, expect roughly double across the board.

## After the workshop

- **Turn up the scale.** `sql/2-generate-data.sql` has a `run_count` at the top. 600,000
  gives you ~20M spans — you'll want more than 2 GB of memory, and every query and plan
  stays the same shape.
- **Point it at real telemetry.** The column names track the OpenTelemetry GenAI semantic
  conventions (`gen_ai.operation.name`, `gen_ai.usage.input_tokens`, `gen_ai.agent.name`),
  so an OTel collector can write into this schema with a mapping rather than a redesign.
  Note those attributes are still *Development* status and the spec now lives at
  [open-telemetry/semantic-conventions-genai](https://github.com/open-telemetry/semantic-conventions-genai)
  — the older opentelemetry.io page marks them all Deprecated purely because it moved.
- **Work out what your trace vendor keeps, and for how long.** Then decide which questions
  you want to still be able to ask a year from now.

Don't leave services running you aren't using:

```bash
tiger service list
tiger service delete <service-id> --confirm
```

## License

MIT — see [LICENSE](./LICENSE).
