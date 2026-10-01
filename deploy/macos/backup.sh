#!/usr/bin/env bash
# Dumps the ledger to backups/ beside this script and keeps the newest 14. launchd runs it nightly.
# A dump is only useful with budget.env's BUDGET_TOKEN_KEY: bank tokens in it are sealed with that key.
set -euo pipefail
cd "$(dirname "$0")"
set -a; source ./budget.env; set +a
export PATH="/opt/homebrew/bin:/opt/homebrew/opt/postgresql@16/bin:/usr/local/bin:$PATH"
mkdir -p backups
out="backups/budget-$(date +%Y%m%d-%H%M%S).dump"
PGPASSWORD="${POSTGRES_PASSWORD:-}" pg_dump -h "$POSTGRES_HOST" -p "${POSTGRES_PORT:-5432}" -U "${POSTGRES_USER:-budget}" \
  -d "${POSTGRES_DB:-budget}" --format=custom > "$out.part"
pg_restore --list "$out.part" > /dev/null   # it reads back, or this run fails
mv "$out.part" "$out"
ls -1t backups/budget-*.dump | tail -n +15 | xargs rm -f
echo "$(date '+%F %T') backed up to $out"
