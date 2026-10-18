#!/usr/bin/env bash
# Installs the Budget server on this Mac as a launchd service, for a Mac that stays on (a Mac mini, say).
#
#   deploy/macos/install.sh              build, install, (re)start, check /health
#   deploy/macos/install.sh --no-launchd build and install only; start it yourself with "$BUDGET_HOME/run.sh"
#   deploy/macos/install.sh --uninstall  stop it and remove the launchd jobs, Caddy's and the tunnel's too
#                                        (keeps the data, settings and backups)
#
# Replacing an installed server backs up its database first, and stops if that backup fails.
#
# Everything lives in $BUDGET_HOME (default ~/Library/Application Support/BudgetServer):
#   budget.env (mode 600, secrets; created once, never overwritten), bin/budget-server, run.sh, backup.sh,
#   logs/server.log, backups/.
# Two LaunchAgents: local.budget.server (always on, restarted if it exits) and local.budget.backup (pg_dump nightly).
# LaunchAgents run while you're logged in: on a headless Mac, turn on automatic login and turn off sleep.
# Needs Xcode 26 (Swift 6.2) on macOS 26, and Postgres 16 on 127.0.0.1 (see docs/INSTALL-SERVER.md).
# ./setup.sh at the repo root runs this, with the tools, Postgres and the phone's address around it.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
BUDGET_HOME=${BUDGET_HOME:-"$HOME/Library/Application Support/BudgetServer"}
AGENTS="$HOME/Library/LaunchAgents"
SERVER_LABEL=local.budget.server
BACKUP_LABEL=local.budget.backup
DOMAIN="gui/$(id -u)"
export PATH="/opt/homebrew/bin:/opt/homebrew/opt/postgresql@16/bin:/usr/local/bin:$PATH"

unload() {
  for label in "$SERVER_LABEL" "$BACKUP_LABEL" "$@"; do
    launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
  done
}

case ${1:-} in
  --uninstall)
    unload local.budget.caddy local.budget.tunnel   # the HTTPS address, when ./setup.sh address set one up
    rm -f "$AGENTS/$SERVER_LABEL.plist" "$AGENTS/$BACKUP_LABEL.plist" "$AGENTS/local.budget.caddy.plist" "$AGENTS/local.budget.tunnel.plist"
    echo "Stopped and removed the launchd jobs. Data, settings and backups are still in $BUDGET_HOME."
    exit 0 ;;
  --no-launchd) LAUNCHD=0 ;;
  "") LAUNCHD=1 ;;
  *) echo "usage: $0 [--no-launchd | --uninstall]" >&2; exit 2 ;;
esac

[[ $(uname) == Darwin ]] || { echo "This installer is for macOS. On Linux, see docs/SERVER.md." >&2; exit 1; }
major=$(sw_vers -productVersion | cut -d. -f1)
(( major >= 26 )) || { echo "The server needs macOS 26 or later (this is $(sw_vers -productVersion))." >&2; exit 1; }
command -v swift >/dev/null || { echo "No swift: install Xcode 26 and run xcode-select --install." >&2; exit 1; }

echo "==> building the server (release)"
(cd "$REPO/Server" && swift build -c release --product BudgetServer)
if [[ -x $BUDGET_HOME/bin/budget-server && -x $BUDGET_HOME/backup.sh ]] && grep -q '^POSTGRES_HOST=.' "$BUDGET_HOME/budget.env" 2>/dev/null; then
  echo "==> backing up the ledger before replacing the server"
  "$BUDGET_HOME/backup.sh" || { echo "The backup failed, so the server wasn't replaced. Is Postgres running?" >&2; exit 1; }
fi
mkdir -p "$BUDGET_HOME/bin" "$BUDGET_HOME/logs" "$BUDGET_HOME/backups"
chmod 700 "$BUDGET_HOME"
cp "$REPO/Server/.build/release/BudgetServer" "$BUDGET_HOME/bin/budget-server.new"
mv "$BUDGET_HOME/bin/budget-server.new" "$BUDGET_HOME/bin/budget-server"
cp "$REPO/deploy/macos/run.sh" "$REPO/deploy/macos/backup.sh" "$BUDGET_HOME/"

ENV="$BUDGET_HOME/budget.env"
if [[ ! -f $ENV ]]; then
  echo "==> writing $ENV with new secrets"
  zone=$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')
  # Each value reaches awk through its environment, never an argument list (which other users can see).
  set_value() {  # set_value KEY VALUE
    local tmp; tmp=$(mktemp "$BUDGET_HOME/.env.XXXXXX")
    SET_KEY=$1 SET_VALUE=$2 awk 'BEGIN { k = ENVIRON["SET_KEY"]; v = ENVIRON["SET_VALUE"] }
      $0 ~ "^" k "=" && !done { print k "=" v; done = 1; next } { print } END { if (!done) print k "=" v }' "$ENV" > "$tmp"
    chmod 600 "$tmp"; mv "$tmp" "$ENV"
  }
  ( umask 077; cp "$REPO/deploy/macos/budget.env.example" "$ENV" )
  chmod 600 "$ENV"
  secret=$(openssl rand -hex 32); set_value BUDGET_API_TOKEN "$secret"
  secret=$(openssl rand -base64 32); set_value BUDGET_TOKEN_KEY "$secret"
  unset secret
  set_value BUDGET_TIMEZONE "${zone:-America/New_York}"
  echo "    Keep a copy of BUDGET_TOKEN_KEY: without it, every bank must be linked again. ./setup.sh save-key puts it in"
  echo "    your Keychain without showing it (or --clipboard, for a password manager)."
else
  echo "==> keeping the existing $ENV"
fi
chmod 600 "$ENV"
set -a; source "$ENV"; set +a

# Postgres: create the role and database when this Mac's Postgres (Homebrew's trusts local connections) lacks them.
if [[ -n ${POSTGRES_HOST:-} ]]; then
  if ! command -v psql >/dev/null; then
    echo "    psql isn't installed; make sure Postgres at $POSTGRES_HOST has role ${POSTGRES_USER:-budget} and database ${POSTGRES_DB:-budget}."
  elif ! pg_isready -q -h "$POSTGRES_HOST" -p "${POSTGRES_PORT:-5432}"; then
    echo "Postgres isn't answering on $POSTGRES_HOST:${POSTGRES_PORT:-5432}. Start it (brew services start postgresql@16) and run this again." >&2
    exit 1
  else
    admin=(psql -h "$POSTGRES_HOST" -p "${POSTGRES_PORT:-5432}" -d postgres -tAc)
    if "${admin[@]}" "select 1" >/dev/null 2>&1; then
      [[ $("${admin[@]}" "select 1 from pg_roles where rolname='${POSTGRES_USER:-budget}'") == 1 ]] \
        || { echo "==> creating Postgres role ${POSTGRES_USER:-budget}"; createuser -h "$POSTGRES_HOST" -p "${POSTGRES_PORT:-5432}" "${POSTGRES_USER:-budget}"; }
      [[ $("${admin[@]}" "select 1 from pg_database where datname='${POSTGRES_DB:-budget}'") == 1 ]] \
        || { echo "==> creating database ${POSTGRES_DB:-budget}"; createdb -h "$POSTGRES_HOST" -p "${POSTGRES_PORT:-5432}" -O "${POSTGRES_USER:-budget}" "${POSTGRES_DB:-budget}"; }
    fi
  fi
fi

if [[ $LAUNCHD == 0 ]]; then
  echo "Installed in $BUDGET_HOME. Start it with: \"$BUDGET_HOME/run.sh\""
  exit 0
fi

echo "==> installing the launchd jobs"
mkdir -p "$AGENTS"
cat > "$AGENTS/$SERVER_LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$SERVER_LABEL</string>
  <key>ProgramArguments</key><array><string>$BUDGET_HOME/run.sh</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$BUDGET_HOME/logs/server.log</string>
  <key>StandardErrorPath</key><string>$BUDGET_HOME/logs/server.log</string>
</dict>
</plist>
PLIST
cat > "$AGENTS/$BACKUP_LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$BACKUP_LABEL</string>
  <key>ProgramArguments</key><array><string>$BUDGET_HOME/backup.sh</string></array>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>3</integer><key>Minute</key><integer>30</integer></dict>
  <key>StandardOutPath</key><string>$BUDGET_HOME/logs/backup.log</string>
  <key>StandardErrorPath</key><string>$BUDGET_HOME/logs/backup.log</string>
</dict>
</plist>
PLIST
plutil -lint -s "$AGENTS/$SERVER_LABEL.plist" "$AGENTS/$BACKUP_LABEL.plist"
unload
launchctl bootstrap "$DOMAIN" "$AGENTS/$SERVER_LABEL.plist"
launchctl bootstrap "$DOMAIN" "$AGENTS/$BACKUP_LABEL.plist"

echo "==> waiting for http://127.0.0.1:${PORT:-8080}/health"
for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${PORT:-8080}/health" >/dev/null 2>&1; then
    echo "Running. API http://127.0.0.1:${PORT:-8080} · dashboard http://budget.localhost:${DASHBOARD_PORT:-8081} · logs $BUDGET_HOME/logs/server.log"
    exit 0
  fi
  sleep 1
done
echo "It didn't answer in 30 s. The end of the log:" >&2
tail -20 "$BUDGET_HOME/logs/server.log" >&2
exit 1
