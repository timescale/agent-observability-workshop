#!/usr/bin/env bash
#
# Fill the rollups created by sql/5a-create-rollups.sql.
#
#   scripts/refresh-rollups.sh              # uses your default service
#   scripts/refresh-rollups.sh agent-obs    # or name one
#
# Why this is a script and not just another .sql file:
# refresh_continuous_aggregate() cannot run inside a transaction block, and
# `tiger db query -f` wraps an entire file in one. So each refresh gets its own
# invocation. That's the whole trick -- there is nothing clever in here.
#
# Order matters. spans_1h reads spans_5m and spans_1d reads spans_1h, so each
# layer has to be populated before the one above it.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

target="${1:-}"
if [ -n "$target" ] && ! [[ "$target" =~ ^[a-z0-9]{10}$ ]]; then
    target="$(tiger service list -o json \
              | jq -r --arg n "$target" '.[] | select(.name == $n) | .service_id' | head -1)"
    if [ -z "$target" ]; then
        echo "No Tiger Cloud service by that name. You have:" >&2
        tiger service list -o json | jq -r '.[] | "  \(.name)  (\(.service_id))"' >&2
        exit 1
    fi
fi

echo "Filling rollups. The first one reads every raw span, so give it a minute."

for view in spans_5m spans_1h spans_1d conversations_1d; do
    printf '  %-18s ' "$view"
    started=$SECONDS
    if tiger db query ${target:+"$target"} --timeout 0 \
         -c "CALL refresh_continuous_aggregate('$view', NULL, NULL)" >/dev/null 2>&1; then
        echo "ok  ($((SECONDS - started))s)"
    else
        echo "FAILED"
        echo "Run it by hand to see the error:" >&2
        echo "  tiger db query -c \"CALL refresh_continuous_aggregate('$view', NULL, NULL)\"" >&2
        exit 1
    fi
done

echo "Done. Now: tiger db query -f sql/5b-query-rollups.sql"
