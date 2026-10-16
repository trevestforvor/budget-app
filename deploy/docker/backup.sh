#!/bin/sh
# Dumps the ledger into backups/ beside compose.yaml and keeps the newest 14. The backup service runs it daily;
# "once" makes one dump and exits (./setup.sh does that before replacing the server).
# A dump is only useful with budget.env's BUDGET_TOKEN_KEY: bank tokens in it are sealed with that key.
set -eu
umask 077
export PGPASSWORD="$POSTGRES_PASSWORD"
dump() {
  out="/backups/budget-$(date +%Y%m%d-%H%M%S).dump"
  pg_dump -h db -U "${POSTGRES_USER:-budget}" -d "${POSTGRES_DB:-budget}" --format=custom > "$out.part"
  pg_restore --list "$out.part" > /dev/null   # it reads back, or this run fails
  mv "$out.part" "$out"
  ls -1t /backups/budget-*.dump | tail -n +15 | xargs -r rm -f
  echo "$(date '+%F %T') backed up to backups/$(basename "$out")"
}
until pg_isready -q -h db; do sleep 2; done
if [ "${1:-}" = once ]; then dump; exit; fi
while :; do dump || echo "$(date '+%F %T') the backup failed"; sleep 86400; done
