# <Workshop Name>

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/timescale/agent-observability-workshop)

<One paragraph. What they'll *build*, not what topics get covered. Name the thing they
walk away with.>

## What you'll learn

- **<Concept>** — <what it does for them, not what it is>
- **<Concept>** — <…>
- **<Concept>** — <…>
- **<Concept>** — <…>

## Before the workshop — setup checklist

**Budget <N> minutes, and do this the day before, not five minutes before.** <Say what
happens if they don't — e.g. "this session starts at step 4 and you won't be able to
follow along.">

### 1. Get a Tiger Cloud account

Sign up at <signup link>. <Mention trial credit if there is one.>

### 2. Open the Codespace

Click the badge above. First boot takes a few minutes — it installs the Tiger CLI. You'll
see a banner in the terminal when it's done.

### 3. Log in to the CLI

```bash
tiger auth login --headless
```

`--headless` prints a short code and a URL. Open the URL in any browser on any machine,
enter the code, pick your project. This is the flow designed for a terminal that can't
open your browser, which is exactly a Codespace.

```bash
tiger service list
```

### 4. Create your service

```bash
tiger service create --name <workshop>-workshop --cpu 500 --memory 2
```

<Say why this size. Free — `--cpu shared --memory shared` — is enough unless the workshop
needs real storage or compute.>

**Creating a service also makes it your default**, so nothing below needs a service ID.

### 5. Confirm you're ready

```bash
tiger db query -c "SELECT version()"
```

<End with one command whose output proves they're set, and say bluntly what to do if it
doesn't work.>

## During the workshop

<N> minutes. Each section is self-contained, so falling behind on one doesn't lock you out
of the next.

| File | What it does |
|------|--------------|
| `sql/1-<name>.sql` | <…> |
| `sql/2-<name>.sql` | <…> |

Run a whole file:

```bash
tiger db query -f sql/1-<name>.sql
```

Or one section at a time, so you can read the output as you go:

```bash
tiger db query -c "SELECT ..."
```

## Need help?

- **Workshop day:** ask in the chat.
- **Anytime:** [Tiger Data docs](https://www.tigerdata.com/docs) or
  [Community Slack](https://slack.timescale.com).

## Troubleshooting

<Every failure you actually hit while building this. This section earns its length — it is
the difference between an attendee unblocking themselves and an attendee going quiet.>

**<Symptom, in the words they'd use>**
<Cause and fix.>

## After the workshop

<What to try next.>

Don't leave services running you aren't using:

```bash
tiger service list
tiger service delete <service-id> --confirm
```

## License

MIT — see [LICENSE](./LICENSE).
