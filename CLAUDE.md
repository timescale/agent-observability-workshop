# Building this workshop

Notes for whoever maintains this, including coding agents. Attendee-facing content is
`README.md`.

## What this is

A joint AlphaSignal x Tiger Data webinar, 30 September 2026. Audience is ~300K AI/ML
engineers: strong on agents, tokens, evals and tail latency; weak-to-indifferent on
databases. Don't explain what an agent is. Do explain why a continuous aggregate exists.

## Framing constraints -- these are not stylistic

**Never call this an "observability backend".** Tiger built an OpenTelemetry/Prometheus
backend called Promscale and discontinued it in 2023. The announcement is still live on
the site, and anyone who googles "Timescale observability" will find it.

**Never position against OTel or trace vendors.** `timescale/tiger-agents-for-work`,
Tiger's own agent framework, ships Logfire instrumentation. The honest and defensible
framing is the durable aggregate tier *underneath* a trace tool.

The line that holds both: *you'll probably buy a trace tool -- build this once anyway, so
you know what it's doing and what it can't do for you.*

## Things that will bite you

- `convert_to_columnstore` and `add_columnstore_policy` are **procedures**. `CALL`, not
  `SELECT`, or you get SQLSTATE 42809.
- `ALTER TABLE ... SET (timescaledb.compress ...)` was deprecated in 2.18. Use
  `timescaledb.enable_columnstore` and the hypercore functions.
- Continuous aggregate refreshes can't run in the transaction `tiger db query -f` wraps a
  file in (SQLSTATE 25001). `sql/5-rollups.sql` says so at the top.
- `::int` **rounds** in Postgres, so `(random() * 9.999)::int` can return 10 and index
  past the end of a 10-element array, silently producing NULL. Use `floor()`.
- `CREATE TABLE AS SELECT` over 2M rows kills the connection on a free service.

## Keep the numbers honest

Every figure in the README was measured on a free Tiger Cloud service with 2,003,180
spans, and several of them contradict what you'd assume:

- the columnstore made `count(DISTINCT)` *slightly worse*
- cost-by-tenant barely moved under the columnstore
- hyperloglog in the wrong-shaped rollup was 5,590ms; in a rollup grouped only by day it
  was 1.1ms and 440 kB instead of 65 MB

If you change the generator, re-measure and update the table. A wrong number is worse than
no number: it turns "this is slow" into "this is broken" and people kill the command.

## The README is the product

Assume someone lands on it cold, a week before the session, with none of your context.
The section order in the skeleton is the one that's worked across three workshops.

Two rules that keep biting us:

- **No hardcoded dates.** "Before workshop day", never "before May 28". These get reused,
  and a stale date is the first thing an attendee notices.
- **Every number is measured, not estimated.** If the README says a step takes two
  minutes, someone timed it. A wrong number is worse than no number — it turns "this is
  slow" into "this is broken", and attendees kill the command.

## SQL conventions

Numbered `sql/N-topic.sql`, each self-contained and re-runnable (lead with
`DROP ... IF EXISTS`), with `-- ===` banner comments so attendees can find their place
while you talk over a screen share.

## Run everything through `tiger db query`

No `psql`, no driver. Fewer dependencies, and it exercises the tool we ship. Three limits
to design around, all measured:

- **It can't stream a local file into a `COPY`.** There's no `tiger db copy`, and piping a
  CSV into `-c "COPY … FROM STDIN"` *hangs* rather than erroring
  ([tiger-cli#227](https://github.com/timescale/tiger-cli/issues/227)). If you need to
  load a local dataset, ship it as gzipped `INSERT` statements and pipe them in:
  `gunzip -c data/load/01.sql.gz | tiger db query`.
- **A multi-statement file runs in one implicit transaction.** Anything that can't run in
  a transaction block fails with `SQLSTATE 25001` and takes the whole file down — including
  `CREATE MATERIALIZED VIEW … WITH DATA` and `refresh_continuous_aggregate()`. Run those
  statements individually with `-c`, or split the file.
- **Very large `-f` files OOM the server.** ~146 MB of SQL in one file returns
  `ERROR: out of memory (SQLSTATE 53200)` on a small service. Chunk at roughly 15 MB.

There's no default query timeout, so a long `INSERT` is fine — a 70-second query survives.

Also: the table renderer trims leading whitespace, which flattens `EXPLAIN` plans so every
node sits at the left margin. If reading plans matters, `-o json` keeps the indentation.

## Devcontainer

Test it locally rather than iterating through real Codespaces:

```bash
npx --yes @devcontainers/cli up --workspace-folder . \
  --config .devcontainer/devcontainer.json --remove-existing-container
```

That builds the real image and runs `postCreateCommand` for real. Then:

```bash
CID=$(docker ps -aq --filter "label=devcontainer.local_folder=$PWD" | head -1)
docker exec -u vscode "$CID" bash -lc 'command -v tiger'
docker rm -f "$CID"
```

The workspace is bind-mounted, so anything a script writes lands in your checkout —
`git status` after testing.

**Do not remove the `password_storage pgpass` line** from `post-create.sh`. There is no
keyring in a container, so the default backend has nothing to write to and
`tiger auth login` reports success while leaving every later command unable to read
credentials back. It fails silently, which is the worst kind.

**Prefer apt or a tool's own installer over `ghcr.io/devcontainers-contrib/*` features** —
those have failed to resolve during container creation before, which is not something we
control.

### If your workshop needs a local service

Uncomment the `docker-in-docker` feature, `forwardPorts`/`portsAttributes`, the docker VS
Code extension, and `postStartCommand`, then add a `.devcontainer/docker-compose.yml`.
Label every forwarded port — attendees get a toast telling them what came up.

Two gotchas if you install a service natively via apt instead:

1. Packaged `service`/init.d scripts are unreliable in a devcontainer. Grafana's sources
   `/etc/default/grafana-server` but never `export`s it, so custom env vars never reach the
   daemon, and it hard-codes a 1-second pidfile wait that reports failure while the server
   is still starting. Launch the binary directly and poll its health endpoint.
2. Devcontainer sudoers usually only grants passwordless `sudo` to become `root`, so
   `sudo -u someservice …` hangs asking for a password that doesn't exist. Use
   `sudo runuser -u someservice -- …`.

### If your workshop needs a language runtime

Add the relevant first-party feature — `ghcr.io/devcontainers/features/node`,
`.../python` — rather than installing by hand. Commit the `devcontainer-lock.json` the CLI
generates; it pins features by digest, which matters when forty people build the same
container on the same morning.

## Before you ship

- Devcontainer builds clean from a fresh `--remove-existing-container`.
- Every SQL file runs end to end against a real service, and the timings in the README are
  the ones you measured.
- Every link in the README returns 200.
- `tiger service list` — delete everything you created while testing.
