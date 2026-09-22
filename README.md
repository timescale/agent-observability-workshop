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
console. **The free tier is enough for this entire workshop** — the dataset lands at
about 120 MB against a 750 MB cap.

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
tiger service create --name agent-obs --cpu shared --memory shared
```

Creating a service also makes it your **default**, which is why no command below needs a
service ID.

## The workshop

Six files. Run them in order.

| | File | What happens |
|---|------|--------------|
| 1 | `sql/1-schema.sql` | One agent run, nine spans, readable by eye |
| 2 | `sql/2-generate-data.sql` | 300 agents, 12 tenants, 30 days, ~2M spans |
| 3 | `sql/3-baseline.sql` | The obvious questions, on a plain table |
| 4 | `sql/4-hypertable-columnstore.sql` | Hypertable and columnstore. Two of four queries improve |
| 5 | `sql/5-rollups.sql` | Continuous aggregates, percentile sketches, hyperloglog |
| 6 | `sql/6-retention.sql` | Drop the raw spans, keep the history |

```bash
tiger db query -f sql/1-schema.sql
```

> **`sql/5-rollups.sql` is the exception.** Run it section by section with `-c`, not with
> `-f`. Continuous aggregate refreshes can't run inside the transaction that `-f` wraps a
> file in. There's a note at the top of the file.

### What you should see

Measured on a **free** Tiger Cloud service with 2,003,180 spans. A free service is
shared CPU, so your numbers will move around — the pattern is what matters.

| Question | Plain table | Columnstore | Rollup |
|---|---|---|---|
| p99 latency by agent | 3,234 ms | 1,305 ms | **660 ms** |
| Cost by tenant | 1,999 ms | 1,897 ms | **605 ms** |
| Tool error rates | 1,604 ms | **230 ms** | — |
| Distinct conversations/day | 5,581 ms | 5,724 ms | **1.1 ms** |
| Last 24 hours, time-filtered | full scan | **4.6 ms** | — |
| Table size | 320 MB | **102 MB** | — |

Data generation takes about 85 seconds.

That 4.6 ms row is the hypertable rather than the columnstore — 29 of 30 chunks are
excluded before a single row is read. It only works because the query filters on the
partition column, which is the whole point of choosing one.

Two rows in that table are the interesting ones. **The columnstore made distinct-count
slightly worse**, because `count(DISTINCT)` isn't waiting on disk — it's hashing 20,000
values, and compressing the input doesn't make hashing cheaper. And cost-by-tenant barely
moved, because it reads nearly every row anyway. Step 5 fixes both, and neither fix is a
storage trick.

### The villain

About 1 run in 330 is a **retry storm** — 500 to 1,500 spans instead of the usual 12,
mostly failing, because a provider had a bad minute and the framework kept retrying. That
is not invented for the workshop: a documented real case hit 847 spans in a single
conversation during an outage.

Org-wide the error rate looks like 8%. That number is useless. Normal runs fail 1.5% of
the time; the entire gap is a couple of hundred runs out of sixty thousand. An average
would have hidden it completely, which is the argument for keeping the tail.

## The dashboard

Grafana is already running on port 3000. Point it at your service:

```bash
scripts/grafana-env.sh agent-obs
```

That reads the connection string from the Tiger CLI, writes a gitignored `.env`, and
restarts Grafana. Open the forwarded port 3000 and the **Agent observability** dashboard
is provisioned and waiting.

Every panel but one reads a **continuous aggregate**, not the raw table. That's why it
stays responsive on the smallest service Tiger Cloud offers. The exception is the retry
storm hunt, which scans raw spans on purpose — it's the one question worth paying a full
scan for.

### Step 6, in numbers

Dropping raw spans older than 7 days:

```
raw spans     1,989,321 → 516,693       102 MB → 26 MB
daily rollup  unchanged, still back to day 1
```

The 30-day cost, p99 and conversation-count queries all still answer afterwards, from
data whose raw rows no longer exist. That is the trade, stated plainly: you keep the
shape of history and give up inspecting an individual span from before the window.

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

**Grafana says `database "tsdbadmin" does not exist`**
`.env` has an empty `TIGER_DATABASE`. Re-run `scripts/grafana-env.sh`.

**`conn closed` on a big query**
A free service is shared CPU and modest memory. `CREATE TABLE AS SELECT` over two million
rows will drop the connection. Nothing in the workshop does this, but it's worth knowing
where the ceiling is. `tiger db query --timeout 0` helps for merely-slow queries; it does
not help for this.

**The service went read-only**
You hit the 750 MB free-tier cap. The default dataset peaks around 120 MB, so this
normally means the generator was run repeatedly without the `TRUNCATE` at the top, or the
run count was raised. Check with `tiger service list`.

**Numbers don't match the table above**
Expected. Shared CPU, and your data is randomly generated. Compare the *ratios* between
columns, not the absolute milliseconds.

## After the workshop

- **Turn up the scale.** `sql/2-generate-data.sql` has a `run_count` at the top. 600,000
  gives you ~20M spans — you'll want a paid service, and every query and plan stays the
  same shape.
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
