#!/usr/bin/env bash
# Sets up Budget from a fresh clone: the tools, the server, an HTTPS address for the phone, and the app.
# Every step checks first and skips what's already done, so it's safe to run again (and to update: git pull, then this).
#
#   ./setup.sh                    everything, in order, asking before each step
#   ./setup.sh check              what's installed and answering; changes nothing
#   ./setup.sh tools              what the chosen server and the app need (Homebrew: xcodegen, postgresql@16)
#   ./setup.sh server [where]     where the server runs:
#                                   mac     this Mac: launchd, Homebrew's Postgres, nightly backups (deploy/macos)
#                                   docker  Docker Compose: server, Postgres, daily backups (deploy/docker); Linux, a NAS,
#                                           or a Mac with Docker
#                                   olares  an Olares: builds this checkout and updates the budgetapi app installed there
#   ./setup.sh address [how]      the phone's HTTPS address for the API, saved as BUDGET_PUBLIC_URL and checked:
#                                   tailscale   Tailscale Serve: private to your devices (Tailscale must be installed)
#                                   caddy       Caddy on your domain, ports 80 and 443 forwarded here
#                                   cloudflare  a Cloudflare Tunnel on your domain, no open ports (on a Mac)
#                                   url         an address you already have
#   ./setup.sh app                Config/Local.xcconfig, xcodegen, and with an iPhone connected: build, install, launch
#
# Answers can come from the environment instead of prompts (for an agent):
#   BUDGET_SERVER         mac | docker | olares                BUDGET_ADDRESS        tailscale | caddy | cloudflare | url
#   BUDGET_DOMAIN         the API's hostname, for caddy or cloudflare (budget.example.com)
#   BUDGET_PUBLIC_URL     the phone's address, for url         BUDGET_ACME_EMAIL     optional, for Caddy's certificates
#   BUDGET_TEAM_ID        Apple Developer team ID              BUDGET_BUNDLE_PREFIX  com.yourname (app = <prefix>.budget)
#   BUDGET_DEVICE         the iPhone's UDID or name            BUDGET_YES=1          yes to every question (needed
#                                                                                    without a terminal: there, no is the default)
#   BUDGET_BANKS          plaid | simplefin | later            which provider's steps to print at the end (either works;
#                                                              docs/INSTALL-SERVER.md §6 compares them)
#
# Secrets are never printed. The phone's token is on the dashboard: Settings → Connect your phone → Show.
# Guides: docs/SETUP.md (start here), docs/INSTALL-SERVER.md, docs/INSTALL-APP.md.
set -euo pipefail

REPO=$(cd "$(dirname "$0")" && pwd)
BUDGET_HOME=${BUDGET_HOME:-"$HOME/Library/Application Support/BudgetServer"}
DOCKER_DIR="$REPO/deploy/docker"
OLARES_DIR="$REPO/deploy/olares/budgetapi"
AGENTS="$HOME/Library/LaunchAgents"
GUI="gui/$(id -u)"
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/Budget-setup"
OS=$(uname)
KIND='' ENV_FILE='' ADDRESS='' CHECK_TRIES=12
export PATH="/opt/homebrew/bin:/opt/homebrew/opt/postgresql@16/bin:/usr/local/bin:$PATH"

if [[ -t 1 ]]; then B=$'\e[1m' G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' N=$'\e[0m'; else B='' G='' Y='' R='' N=''; fi
step() { printf '\n%s==> %s%s\n' "$B" "$*" "$N"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$R" "$N" "$*"; }
die()  { printf '%s%s%s\n' "$R" "$*" "$N" >&2; exit 1; }

# Yes/no with a default. BUDGET_YES=1 answers yes; with no terminal to ask on and no BUDGET_YES, the answer is no.
ask() {  # ask "Question?" [Y|n]
  local default=${2:-Y} reply
  [[ ${BUDGET_YES:-} == 1 ]] && return 0
  [[ -t 0 ]] || { warn "skipped, no terminal to ask on: $1 (BUDGET_YES=1 says yes)"; return 1; }
  read -r -p "  $1 [$([[ $default == Y ]] && echo Y/n || echo y/N)] " reply
  reply=${reply:-$default}
  [[ $reply =~ ^[Yy] ]]
}
prompt() {  # prompt VAR "Question" [default] — keeps VAR when it's already set
  local var=$1 question=$2 default=${3:-} reply
  [[ -n ${!var:-} ]] && return 0
  [[ -t 0 ]] || die "$question: set $var (no terminal to ask on)."
  read -r -p "  $question${default:+ [$default]}: " reply
  printf -v "$var" '%s' "${reply:-$default}"
}
choose() {  # choose VAR "Question" default "key|what it is"... — keeps VAR when it's set; with no terminal, the default
  local _var=$1 _question=$2 _default=$3 _reply _o _i=1 _keys=()
  shift 3
  [[ -n ${!_var:-} ]] && return 0
  if [[ ! -t 0 ]]; then
    [[ -n $_default ]] || die "$_question: set $_var (no terminal to ask on)."
    printf -v "$_var" '%s' "$_default"; return 0
  fi
  echo "  $_question"
  for _o in "$@"; do _keys+=("${_o%%|*}"); printf '    %d) %-11s %s\n' $_i "${_o%%|*}" "${_o#*|}"; _i=$((_i + 1)); done
  read -r -p "  Pick 1-$#${_default:+ [$_default]}: " _reply || die "No answer."
  [[ -z $_reply ]] && _reply=$_default
  [[ $_reply =~ ^[0-9]+$ ]] && (( _reply >= 1 && _reply <= $# )) && _reply=${_keys[_reply - 1]}
  [[ " ${_keys[*]} " == *" $_reply "* ]] || die "Not one of the choices: $_reply"
  printf -v "$_var" '%s' "$_reply"
}

# MARK: - which server

# Where the server's settings live, by where it runs. An Olares keeps its settings in the app, not here.
use_kind() {
  KIND=$1
  case $KIND in
    mac)    ENV_FILE="$BUDGET_HOME/budget.env" ;;
    docker) ENV_FILE="$DOCKER_DIR/budget.env" ;;
    olares) ENV_FILE='' ;;
    *) die "BUDGET_SERVER is mac, docker or olares ($KIND)." ;;
  esac
}
installed_kind() {  # the install this machine already has, if any
  if [[ -f $BUDGET_HOME/budget.env ]]; then echo mac
  elif [[ -f $DOCKER_DIR/budget.env ]]; then echo docker
  elif [[ -f $OLARES_DIR/deploy.env || -n ${OLARES_SSH:-} ]]; then echo olares
  fi
}
pick_server() {  # pick_server [where] [skip] — the argument, BUDGET_SERVER, the install that's here, or a choice
  local want=${1:-${BUDGET_SERVER:-}} found opts=() default=docker
  found=$(installed_kind)
  if [[ -z $want && -n $found ]]; then want=$found; ok "the server here: $found"; fi
  if [[ -z $want ]]; then
    if [[ $OS == Darwin ]]; then
      opts+=("mac|this Mac, as a launchd service with Homebrew's Postgres (a Mac that stays on)"); default=mac
    fi
    opts+=("docker|Docker Compose: the server, Postgres and backups in containers (Linux, a NAS, a Mac with Docker)")
    opts+=("olares|an Olares: update the budgetapi app installed there")
    [[ ${2:-} == skip ]] && opts+=("none|no server here: the app will use one somewhere else")
    choose BUDGET_SERVER "Where should the server run?" "$default" "${opts[@]}"
    want=$BUDGET_SERVER
  fi
  [[ $want == none ]] && { KIND=none; return 0; }
  [[ -n $found && $found != "$want" ]] && warn "a server is also set up here for $found; this step works on $want"
  use_kind "$want"
}

env_get() {  # env_get KEY — a value from the server's settings file, without sourcing it into this shell
  [[ -n $ENV_FILE && -f $ENV_FILE ]] || return 0
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -1
}
env_set() {  # env_set KEY VALUE — replaces KEY's line (commented or not), or appends it
  local tmp
  tmp=$(mktemp "$(dirname "$ENV_FILE")/.env.XXXXXX")
  awk -v k="$1" -v v="$2" '
    $0 ~ "^#? *" k "=" { if (!done) print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }' "$ENV_FILE" > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$ENV_FILE"
}
mode_of()   { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }
api_port()  { local p=''; [[ $KIND == mac ]] && p=$(env_get PORT); echo "${p:-8080}"; }
dash_port() { local p=''; [[ $KIND == mac ]] && p=$(env_get DASHBOARD_PORT); echo "${p:-8081}"; }
healthy()   { curl -fsS --max-time "${2:-3}" "$1/health" 2>/dev/null | grep -q '"ok"'; }
version_at() { curl -fsS --max-time 3 "$1/health" 2>/dev/null | sed -n 's/.*"version":"\([^"]*\)".*/\1/p'; }
docker_ready() { command -v docker >/dev/null && docker compose version >/dev/null 2>&1; }
# Compose, with the caddy profile on once ./setup.sh address caddy has written its Caddyfile.
dc() {
  local profiles=''
  [[ -f $DOCKER_DIR/Caddyfile ]] && profiles=caddy
  COMPOSE_PROFILES=$profiles docker compose -f "$DOCKER_DIR/compose.yaml" "$@"
}
restart_server() {
  case $KIND in
    mac)
      if launchctl print "$GUI/local.budget.server" >/dev/null 2>&1; then
        launchctl kickstart -k "$GUI/local.budget.server" >/dev/null && ok "restarted the server"
      else warn "the server isn't a launchd job here; restart it yourself so it picks up the change"; fi ;;
    docker) dc up -d --force-recreate --no-deps server >/dev/null 2>&1 && ok "restarted the server" \
              || warn "restarting the server failed: docker compose -f deploy/docker/compose.yaml up -d" ;;
  esac
}
wait_healthy() {  # wait_healthy URL TRIES — every 2 s
  for _ in $(seq 1 "$2"); do healthy "$1" && return 0; sleep 2; done
  return 1
}

# A LaunchAgent that runs PROGRAM at login and keeps it running: launch_agent LABEL LOG [NAME=VALUE...] -- PROGRAM ARGS...
launch_agent() {
  local label=$1 log=$2 envs='' args='' plist="$AGENTS/$1.plist"
  shift 2
  while [[ $1 != -- ]]; do envs+="<key>${1%%=*}</key><string>${1#*=}</string>"; shift; done
  shift
  for arg in "$@"; do args+="<string>$arg</string>"; done
  mkdir -p "$AGENTS" "$(dirname "$log")"
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array>$args</array>
  <key>EnvironmentVariables</key><dict>$envs</dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$log</string>
  <key>StandardErrorPath</key><string>$log</string>
</dict>
</plist>
PLIST
  plutil -lint -s "$plist"
  launchctl bootout "$GUI/$label" 2>/dev/null || true
  launchctl bootstrap "$GUI" "$plist"
}
agent_loaded() { [[ $OS == Darwin ]] && launchctl print "$GUI/$1" >/dev/null 2>&1; }

# Connected iPhones (not simulators), one "udid<TAB>name" per line.
phones() {
  local json
  json=$(mktemp)
  xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1 || { rm -f "$json"; return 0; }
  /usr/bin/python3 -I - "$json" <<'PY'
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    p = d.get("properties", {})
    hw = p.get("hardware") or d.get("hardwareProperties", {})
    conn = p.get("connection") or d.get("connectionProperties", {})
    name = p.get("state", {}).get("name") or d.get("deviceProperties", {}).get("name", "iPhone")
    if hw.get("reality") == "physical" and hw.get("platform") == "iOS" and conn.get("pairingState") == "paired":
        print(f"{hw.get('udid')}\t{name}")
PY
  rm -f "$json"
}

# MARK: - check

bank_counts() {  # bank_counts DASHBOARD_URL — "Banks: N linked (Plaid M, SimpleFIN K)", counts only, nothing else from the links
  curl -fsS --max-time 3 "$1/v1/links" 2>/dev/null | /usr/bin/python3 -I -c '
import collections, json, sys
try: links = json.load(sys.stdin)
except ValueError: sys.exit()
names = {"plaid": "Plaid", "simplefin": "SimpleFIN"}
count = collections.Counter(names.get(l.get("provider"), "other") for l in links if isinstance(l, dict))
parts = ["%s %d" % (n, count[n]) for n in ("Plaid", "SimpleFIN")]
if count["other"]: parts.append("other %d" % count["other"])
print("Banks: %d linked (%s)" % (sum(count.values()), ", ".join(parts)))' 2>/dev/null || true
}

check_installed() {  # what a Mac or Docker install has in common: settings, API, dashboard, backups
  local backups=$1
  [[ $(mode_of "$ENV_FILE") == 600 ]] && ok "budget.env is private (600)" || { bad "$ENV_FILE isn't mode 600"; fails=1; }
  for key in BUDGET_API_TOKEN BUDGET_TOKEN_KEY; do
    [[ -n $(env_get $key) ]] && ok "$key is set" || { bad "$key is empty in budget.env"; fails=1; }
  done
  if healthy "http://127.0.0.1:$(api_port)"; then ok "API answers on 127.0.0.1:$(api_port) ($(version_at "http://127.0.0.1:$(api_port)"))"
  else bad "API isn't answering on 127.0.0.1:$(api_port)"; fails=1; fi
  curl -fsS --max-time 3 -o /dev/null "http://127.0.0.1:$(dash_port)/" 2>/dev/null \
    && ok "dashboard: http://budget.localhost:$(dash_port)" || warn "the dashboard isn't answering on $(dash_port)"
  local banks; banks=$(bank_counts "http://127.0.0.1:$(dash_port)")
  [[ -n $banks ]] && ok "$banks"
  local latest; latest=$(ls -1t "$backups"/budget-*.dump 2>/dev/null | head -1 || true)
  if [[ -n $latest ]]; then ok "latest backup: $(basename "$latest")"; else warn "no backup in $backups yet"; fi
}

cmd_check() {
  fails=0
  local found; found=$(installed_kind)
  [[ -n ${BUDGET_SERVER:-} ]] && found=$BUDGET_SERVER
  [[ -n $found ]] && use_kind "$found"

  if [[ $OS == Darwin ]]; then
    step "This Mac"
    local major; major=$(sw_vers -productVersion | cut -d. -f1)
    if (( major >= 26 )); then ok "macOS $(sw_vers -productVersion)"
    elif [[ $KIND == mac ]]; then bad "macOS $(sw_vers -productVersion): the server needs 26 or later"; fails=1
    else warn "macOS $(sw_vers -productVersion): a server on this Mac would need 26 or later"; fi
    if xcode-select -p >/dev/null 2>&1 && xcodebuild -version >/dev/null 2>&1; then
      ok "$(xcodebuild -version | head -1), $(swift --version 2>&1 | grep -o 'Swift version [0-9.]*')"
    else bad "Xcode isn't installed (or xcode-select points at the Command Line Tools)"; fails=1; fi
    if command -v brew >/dev/null; then ok "Homebrew"; else bad "Homebrew isn't installed"; fails=1; fi
    for tool in xcodegen psql caddy cloudflared; do
      if command -v $tool >/dev/null; then ok "$tool"
      elif [[ $tool == xcodegen || ($tool == psql && $KIND != docker && $KIND != olares) ]]; then warn "$tool isn't installed (./setup.sh tools)"; fi
    done
  else
    step "This machine"
    ok "$(uname -sr)"
  fi
  if docker_ready; then ok "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "(not running)")"
  elif [[ $KIND == docker ]]; then bad "Docker with Compose isn't installed"; fails=1; fi
  local ts; ts=$(tailscale_cli || true)
  [[ -n $ts ]] && ok "Tailscale"

  step "Server"
  case $KIND in
    mac)
      if [[ -x $BUDGET_HOME/bin/budget-server ]]; then ok "on this Mac, in $BUDGET_HOME"; else bad "budget.env is there, but no server binary: ./setup.sh server"; fails=1; fi
      local host; host=$(env_get HOST)
      [[ ${host:-127.0.0.1} == 127.0.0.1 || $host == localhost ]] && ok "listens on loopback only" \
        || { bad "HOST=$host: the dashboard has no login, set HOST=127.0.0.1"; fails=1; }
      local pg; pg=$(env_get POSTGRES_HOST)
      if [[ -z $pg ]]; then warn "no POSTGRES_HOST: the ledger is in memory and lost on restart"
      elif pg_isready -q -h "$pg" -p "$(env_get POSTGRES_PORT | grep . || echo 5432)" 2>/dev/null; then ok "Postgres answers on $pg"
      else bad "Postgres isn't answering on $pg"; fails=1; fi
      agent_loaded local.budget.server && ok "launchd job local.budget.server" || warn "the launchd job isn't loaded"
      check_installed "$BUDGET_HOME/backups"
      [[ $(pmset -g 2>/dev/null | awk '$1 == "sleep" {print $2}') == 0 ]] && ok "this Mac doesn't sleep" \
        || warn "this Mac can sleep, and the server sleeps with it (System Settings → Energy, or sudo pmset -a sleep 0)"
      ;;
    docker)
      ok "in Docker (deploy/docker/compose.yaml)"
      local running; running=$(dc ps --status running --services 2>/dev/null || true)
      for svc in server db backup; do
        grep -qx $svc <<<"$running" && ok "container $svc is running" || { bad "container $svc isn't running (./setup.sh server docker)"; fails=1; }
      done
      local published; published=$(dc port server 8081 2>/dev/null || true)
      [[ -z $published || $published == 127.0.0.1:* ]] && ok "the dashboard is published on 127.0.0.1 only" \
        || { bad "the dashboard is published on $published: it has no login, publish it on 127.0.0.1"; fails=1; }
      check_installed "$DOCKER_DIR/backups"
      ;;
    olares)
      ok "on an Olares: deploy/olares/budgetapi/deploy.sh builds and installs it (its settings are in the Olares app)"
      if [[ -n ${BUDGET_PUBLIC_URL:-} ]]; then
        healthy "$BUDGET_PUBLIC_URL" 8 && ok "$BUDGET_PUBLIC_URL answers ($(version_at "$BUDGET_PUBLIC_URL"))" || { bad "$BUDGET_PUBLIC_URL doesn't answer /health"; fails=1; }
      else warn "to check it from here: BUDGET_PUBLIC_URL=https://<its API entrance> ./setup.sh check"; fi
      ;;
    *) warn "no server set up here (./setup.sh server)" ;;
  esac

  if [[ $KIND == mac || $KIND == docker ]]; then
    step "The phone's address"
    local url; url=$(env_get BUDGET_PUBLIC_URL)
    if [[ -z $url ]]; then warn "no BUDGET_PUBLIC_URL: the phone has no address yet (./setup.sh address)"
    elif healthy "$url" 8; then ok "answers: $url"
    else bad "$url doesn't answer /health"; fails=1; fi
    agent_loaded local.budget.caddy && ok "Caddy (launchd job local.budget.caddy; log $BUDGET_HOME/logs/caddy.log)"
    [[ $KIND == docker && -f $DOCKER_DIR/Caddyfile ]] && { grep -qx caddy <<<"$(dc ps --status running --services 2>/dev/null)" \
      && ok "Caddy container is running" || { bad "the Caddy container isn't running (docker compose ... logs caddy)"; fails=1; }; }
    agent_loaded local.budget.tunnel && ok "Cloudflare Tunnel (launchd job local.budget.tunnel; log $BUDGET_HOME/logs/tunnel.log)"
    [[ -n $ts ]] && "$ts" serve status 2>/dev/null | grep -q "127.0.0.1:$(api_port)" && ok "Tailscale Serve forwards to 127.0.0.1:$(api_port)"
  fi

  if [[ $OS == Darwin ]]; then
    step "App"
    local local_cfg="$REPO/Config/Local.xcconfig"
    if [[ -f $local_cfg ]] && ! grep -Eq '^(DEVELOPMENT_TEAM *= *ABCDE12345|BUDGET_BUNDLE_PREFIX *= *com\.(yourname|example)) *$' "$local_cfg"; then
      ok "Config/Local.xcconfig: app $(sed -n 's/^BUDGET_BUNDLE_PREFIX *= *//p' "$local_cfg").budget"
    else warn "no Config/Local.xcconfig with your team (./setup.sh app); the app builds for the simulator only"; fi
    [[ -d $REPO/Budget.xcodeproj ]] && ok "Budget.xcodeproj generated" || warn "Budget.xcodeproj not generated yet (xcodegen generate)"
    local phone; phone=$(phones)
    if [[ -n $phone ]]; then ok "iPhone connected: $(cut -f2 <<<"$phone" | paste -sd, - )"; else warn "no iPhone connected (USB, or the same Wi-Fi once paired)"; fi
  fi

  echo
  (( fails == 0 )) && printf '%sNothing is broken.%s\n' "$G" "$N" || printf '%sSomething above needs fixing.%s\n' "$R" "$N"
  return $fails
}

# MARK: - tools

cmd_tools() {
  step "Tools"
  [[ -n $KIND ]] || { local found; found=${BUDGET_SERVER:-$(installed_kind)}; [[ -n $found ]] && use_kind "$found"; }
  if [[ $OS != Darwin ]]; then
    [[ $KIND == olares ]] && { ok "nothing to install here for an Olares deploy (ssh and rsync)"; return 0; }
    docker_ready || die "Install Docker Engine with the Compose plugin (https://docs.docker.com/engine/install/), then run this again.
On this machine the server runs in Docker; the app is built on a Mac."
    ok "Docker $(docker compose version --short 2>/dev/null)"
    return 0
  fi

  local major; major=$(sw_vers -productVersion | cut -d. -f1)
  if (( major < 26 )); then
    [[ $KIND == mac || -z $KIND ]] && die "A server on this Mac needs macOS 26 or later (this is $(sw_vers -productVersion)). Docker works on older ones: ./setup.sh server docker"
    warn "macOS $(sw_vers -productVersion): fine for Docker; the app needs Xcode 26, which may need a newer macOS"
  fi
  if ! xcodebuild -version >/dev/null 2>&1; then
    die "Install Xcode 26 or later from the App Store (https://apps.apple.com/app/xcode/id497799835), open it once, then run:
  sudo xcode-select -s /Applications/Xcode.app
and run this again."
  fi
  ok "$(xcodebuild -version | head -1)"
  xcodebuild -license check >/dev/null 2>&1 || die "Accept Xcode's license first: sudo xcodebuild -license accept"

  if ! command -v brew >/dev/null; then
    warn "Homebrew isn't installed: https://brew.sh"
    ask "Install Homebrew now with its official installer?" || die "Install Homebrew, then run this again."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    export PATH="/opt/homebrew/bin:$PATH"
  fi
  local missing=() formulas=(xcodegen)
  [[ $KIND == mac || -z $KIND ]] && formulas+=(postgresql@16)
  for formula in "${formulas[@]}"; do
    brew list --formula "$formula" >/dev/null 2>&1 && ok "$formula" || missing+=("$formula")
  done
  if (( ${#missing[@]} )); then
    ask "brew install ${missing[*]}?" || die "Those are needed: brew install ${missing[*]}"
    brew install "${missing[@]}"
  fi
  if [[ $KIND == docker ]]; then
    docker_ready && ok "Docker" || die "Install Docker Desktop (https://www.docker.com/products/docker-desktop/) or OrbStack (https://orbstack.dev), start it, then run this again."
  fi
}

# MARK: - server

cmd_server() {
  [[ -n ${1:-} ]] || step "Where the server runs"
  pick_server "${1:-}"
  case $KIND in
    mac)    server_mac ;;
    docker) server_docker ;;
    olares) server_olares ;;
  esac
}

server_mac() {
  [[ $OS == Darwin ]] || die "That's for a Mac. Here, use: ./setup.sh server docker"
  step "Postgres"
  if [[ -f $ENV_FILE && -z $(env_get POSTGRES_HOST) ]]; then
    warn "budget.env has no POSTGRES_HOST, so the ledger lives in memory"
  elif pg_isready -q -h 127.0.0.1 -p 5432 2>/dev/null; then
    ok "answering on 127.0.0.1:5432"
  else
    brew list --formula postgresql@16 >/dev/null 2>&1 || die "Postgres 16 isn't installed: ./setup.sh tools"
    echo "  starting postgresql@16 (now and at login)"
    brew services start postgresql@16 >/dev/null
    for _ in $(seq 1 20); do pg_isready -q -h 127.0.0.1 -p 5432 && break; sleep 1; done
    pg_isready -q -h 127.0.0.1 -p 5432 || die "Postgres didn't come up; see: brew services info postgresql@16"
    ok "answering on 127.0.0.1:5432"
  fi

  step "Server"
  if [[ -x $BUDGET_HOME/bin/budget-server ]]; then
    ask "The server is installed. Rebuild from this checkout and restart it (it backs up first)?" || { ok "left as it is"; return 0; }
  fi
  "$REPO/deploy/macos/install.sh"

  step "Staying up"
  [[ $(pmset -g | awk '$1 == "sleep" {print $2}') == 0 ]] && ok "this Mac doesn't sleep" \
    || warn "this Mac sleeps, and the server with it: System Settings → Energy → Prevent automatic sleeping, or sudo pmset -a sleep 0"
  defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser >/dev/null 2>&1 && ok "automatic login is on" \
    || warn "the server runs while you're logged in; on a Mac without a screen, turn on automatic login (System Settings → Users & Groups)"
  echo "  Dashboard: http://budget.localhost:$(dash_port) (from another computer: ssh -L $(dash_port):127.0.0.1:$(dash_port) <this mac>)"
}

server_docker() {
  docker_ready || die "Docker with Compose v2 isn't installed: https://docs.docker.com/engine/install/ on Linux, Docker Desktop or OrbStack on a Mac."
  docker info >/dev/null 2>&1 || die "Docker isn't running, or this user can't reach it (on Linux: sudo usermod -aG docker \$USER, then log in again)."

  step "Settings"
  if [[ -f $ENV_FILE ]]; then
    ok "keeping deploy/docker/budget.env"
  else
    local zone; zone=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||' || true)
    ( umask 077
      sed -e "s|^BUDGET_API_TOKEN=.*|BUDGET_API_TOKEN=$(openssl rand -hex 32)|" \
          -e "s|^BUDGET_TOKEN_KEY=.*|BUDGET_TOKEN_KEY=$(openssl rand -base64 32)|" \
          -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$(openssl rand -hex 24)|" \
          -e "s|^BUDGET_TIMEZONE=.*|BUDGET_TIMEZONE=${zone:-America/New_York}|" \
          "$DOCKER_DIR/budget.env.example" > "$ENV_FILE" )
    ok "wrote deploy/docker/budget.env (mode 600) with new secrets"
    warn "save BUDGET_TOKEN_KEY from it in a password manager: without it, every bank must be linked again"
  fi
  chmod 600 "$ENV_FILE"
  mkdir -p "$DOCKER_DIR/backups"

  step "Server"
  if grep -qx server <<<"$(dc ps --status running --services 2>/dev/null)"; then
    ask "The server is running. Rebuild from this checkout and restart it (it backs up first)?" || { ok "left as it is"; return 0; }
    echo "  backing up the ledger before replacing the server"
    dc run --rm -T backup once || die "The backup failed, so the server wasn't replaced."
  fi
  echo "  building and starting (the first build takes several minutes)"
  dc up -d --build
  echo "  waiting for http://127.0.0.1:8080/health"
  wait_healthy http://127.0.0.1:8080 60 || { dc logs --tail 20 server >&2; die "It didn't answer in 2 minutes; the end of its log is above."; }
  ok "running: API http://127.0.0.1:8080 ($(version_at http://127.0.0.1:8080)), dashboard http://budget.localhost:8081"
  echo "  It restarts with Docker. Logs: docker compose -f deploy/docker/compose.yaml logs -f server"
  echo "  Dashboard from another computer: ssh -L 8081:127.0.0.1:8081 <this machine>"
}

server_olares() {
  step "Olares"
  [[ -f $OLARES_DIR/deploy.env || -n ${OLARES_SSH:-} ]] || die "Say which Olares: put OLARES_SSH=user@host and APP_NS=budgetapi-<user> in deploy/olares/budgetapi/deploy.env (never committed).
The budgetapi app must already be installed there from your own Market repo (docs/SERVER.md → Deploy)."
  echo "  deploy.sh builds this checkout on the Olares, backs up the ledger (it stops if that fails), installs the"
  echo "  binary and restarts the app, which is down for about 15 s. Its settings stay in the Olares app."
  ask "Deploy this checkout to the Olares now?" n || { ok "left as it is"; return 0; }
  "$OLARES_DIR/deploy.sh"
}

# MARK: - address

cmd_address() {
  local how=${1:-${BUDGET_ADDRESS:-}} current
  step "The phone's HTTPS address"
  [[ -n $KIND && $KIND != none ]] || pick_server
  if [[ $KIND == olares ]]; then
    ok "on an Olares, the budgetapi app's API entrance is the address: nothing to set up here"
    echo "  Find it in the Olares app's entrances; the dashboard shows it under Settings → Connect your phone."
    return 0
  fi
  [[ -f $ENV_FILE ]] || die "Set up the server first: ./setup.sh server"
  current=$(env_get BUDGET_PUBLIC_URL)
  [[ -z $how && -n ${BUDGET_PUBLIC_URL:-} ]] && how=url
  if [[ -z $how && -n $current ]] && healthy "$current" 8 && ask "$current answers. Keep it?"; then
    ok "keeping $current"; return 0
  fi
  if [[ -z $how ]]; then
    echo "  The phone reaches the API over HTTPS: an address that forwards to 127.0.0.1:$(api_port) and nothing else."
    echo "  The dashboard ($(dash_port)) has no login. More on each way: docs/INSTALL-SERVER.md, step 5."
  fi
  local ts_note=''
  tailscale_cli >/dev/null || ts_note=' (not installed here)'
  [[ -n $how ]] && BUDGET_ADDRESS=$how
  choose BUDGET_ADDRESS "How should the phone reach it?" "" \
    "tailscale|Tailscale Serve: private, only your own devices; the phone runs Tailscale too$ts_note" \
    "caddy|Caddy: public, on a domain you own, with ports 80 and 443 forwarded to this machine" \
    "cloudflare|Cloudflare Tunnel: public, on a domain you have on Cloudflare, no open ports" \
    "url|an address you already have (another proxy, VPN or tunnel)"
  how=$BUDGET_ADDRESS
  case $how in
    tailscale)  address_tailscale ;;
    caddy)      address_caddy ;;
    cloudflare) address_cloudflare ;;
    url)        prompt BUDGET_PUBLIC_URL "The address (https://…)"; ADDRESS=$BUDGET_PUBLIC_URL ;;
    *) die "BUDGET_ADDRESS is tailscale, caddy, cloudflare or url ($how)." ;;
  esac

  local url=${ADDRESS%/}
  [[ $url == https://* ]] || die "The phone needs https:// ($url)."
  env_set BUDGET_PUBLIC_URL "$url"
  ok "saved BUDGET_PUBLIC_URL=$url"
  restart_server
  echo "  checking $url/health"
  for _ in $(seq 1 "$CHECK_TRIES"); do healthy "$url" 5 && { ok "the phone's address answers"; return 0; }; sleep 5; done
  warn "$url doesn't answer yet. Check it later with ./setup.sh check"
}

tailscale_cli() {
  if command -v tailscale >/dev/null; then command -v tailscale
  elif [[ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]]; then echo /Applications/Tailscale.app/Contents/MacOS/Tailscale
  else return 1; fi
}

address_tailscale() {
  local ts name
  ts=$(tailscale_cli) || die "Tailscale isn't installed here, and this script doesn't install it (two Tailscale-based VPN clients on one
machine conflict). Get it from https://tailscale.com/download, sign in, then: ./setup.sh address tailscale"
  name=$("$ts" status --json --peers=false 2>/dev/null | sed -n 's/^[[:space:]]*"DNSName": *"\([^"]*\)\.".*/\1/p' | head -1)
  [[ -n $name ]] || die "Tailscale isn't signed in here: $ts up"
  echo "  serving https://$name → 127.0.0.1:$(api_port), to your own devices only"
  "$ts" serve --bg "$(api_port)" >/dev/null || die "tailscale serve failed. It needs MagicDNS and HTTPS certificates on for your tailnet
(https://login.tailscale.com/admin/dns); on Linux, also sudo tailscale set --operator=\$USER."
  ok "Tailscale Serve is on, and stays on across restarts"
  echo "  The phone needs the Tailscale app, signed in to the same account, to sync. The morning push comes from Apple without it."
  ADDRESS="https://$name"
}

ask_domain() {  # ask_domain "for what" — sets BUDGET_DOMAIN to a hostname
  prompt BUDGET_DOMAIN "The API's hostname $1 (such as budget.example.com)"
  BUDGET_DOMAIN=${BUDGET_DOMAIN#https://}; BUDGET_DOMAIN=${BUDGET_DOMAIN%%/*}
  [[ $BUDGET_DOMAIN =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || die "That isn't a hostname ($BUDGET_DOMAIN)."
}

caddy_file() {  # caddy_file UPSTREAM — the Caddyfile, on stdout
  printf '# Written by ./setup.sh address caddy. HTTPS for the phone, to the API only: never the dashboard.\n{\n\tadmin off\n'
  [[ -n ${BUDGET_ACME_EMAIL:-} ]] && printf '\temail %s\n' "$BUDGET_ACME_EMAIL"
  printf '}\n\n%s {\n\treverse_proxy %s\n}\n' "$BUDGET_DOMAIN" "$1"
}

address_caddy() {
  ask_domain "on a domain you own"
  local host=$BUDGET_DOMAIN lan='' resolved=''
  if [[ $OS == Darwin ]]; then lan=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)
  else lan=$(hostname -I 2>/dev/null | awk '{print $1}'); fi
  command -v dig >/dev/null && resolved=$(dig +short A "$host" | grep -E '^[0-9.]+$' | tail -1 || true)
  echo "  Caddy gets a certificate from Let's Encrypt and forwards only to the API. Before it can, you need:"
  echo "    1. a DNS record: $host → your home's public IP${resolved:+ (now it points to $resolved)}"
  echo "    2. your router forwarding TCP ports 80 and 443 to this machine${lan:+ ($lan)}"
  echo "  Some internet providers (and most cellular ones) share one public IP among customers (CGNAT), and then no"
  echo "  port forward works: use Tailscale or a Cloudflare Tunnel instead."
  if command -v dig >/dev/null && [[ -z $resolved ]]; then warn "$host doesn't resolve yet"; fi
  ask "Set up Caddy for $host?" || die "Stopped; nothing changed."

  if [[ $KIND == docker ]]; then
    ( umask 022; caddy_file server:8080 > "$DOCKER_DIR/Caddyfile" )
    ok "wrote deploy/docker/Caddyfile"
    dc up -d caddy >/dev/null || die "The Caddy container didn't start: docker compose -f deploy/docker/compose.yaml logs caddy"
    ok "the Caddy container is running (it restarts with Docker)"
  else
    if ! command -v caddy >/dev/null; then
      ask "Caddy isn't installed. brew install caddy?" || die "Caddy is needed: brew install caddy"
      brew install caddy
    fi
    launchctl bootout "$GUI/local.budget.caddy" 2>/dev/null || true
    local holder; holder=$(lsof -nP -iTCP:443 -sTCP:LISTEN 2>/dev/null | awk 'NR == 2 {print $1}' || true)
    [[ -z $holder ]] || die "Something else ($holder) already listens on port 443 here. Stop it, or put the API behind that instead (./setup.sh address url)."
    mkdir -p "$BUDGET_HOME/logs"
    caddy_file "127.0.0.1:$(api_port)" > "$BUDGET_HOME/Caddyfile"
    caddy validate --config "$BUDGET_HOME/Caddyfile" --adapter caddyfile >/dev/null 2>&1 || die "Caddy rejected $BUDGET_HOME/Caddyfile: caddy validate --config \"$BUDGET_HOME/Caddyfile\""
    launch_agent local.budget.caddy "$BUDGET_HOME/logs/caddy.log" XDG_DATA_HOME="$BUDGET_HOME" XDG_CONFIG_HOME="$BUDGET_HOME" \
      -- "$(command -v caddy)" run --config "$BUDGET_HOME/Caddyfile" --adapter caddyfile
    ok "Caddy runs as launchd job local.budget.caddy (log: $BUDGET_HOME/logs/caddy.log)"
    /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null | grep -q enabled \
      && warn "macOS's firewall is on: allow caddy when it asks, or: sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add $(command -v caddy)"
  fi
  CHECK_TRIES=24   # the first certificate can take a minute
  ADDRESS="https://$host"
}

address_cloudflare() {
  if [[ $OS != Darwin ]]; then
    die "Here, run cloudflared yourself (https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/), with one
ingress rule to http://127.0.0.1:8080 and nothing else, then: ./setup.sh address url"
  fi
  ask_domain "on a domain you have on Cloudflare"
  local host=$BUDGET_DOMAIN id config="$BUDGET_HOME/cloudflared.yml"
  if ! command -v cloudflared >/dev/null; then
    ask "cloudflared isn't installed. brew install cloudflared?" || die "cloudflared is needed: brew install cloudflared"
    brew install cloudflared
  fi
  if [[ ! -f $HOME/.cloudflared/cert.pem ]]; then
    echo "  cloudflared signs in to Cloudflare in your browser once, and you pick the domain."
    ask "Sign in now?" || die "Stopped; nothing changed."
    cloudflared tunnel login
  fi
  tunnel_id() { cloudflared tunnel list --name budget --output json 2>/dev/null | /usr/bin/python3 -I -c 'import json,sys; t=json.load(sys.stdin); print(t[0]["id"] if t else "")'; }
  id=$(tunnel_id)
  if [[ -z $id ]]; then
    cloudflared tunnel create budget >/dev/null || die "Creating the tunnel failed: cloudflared tunnel create budget"
    id=$(tunnel_id)
  fi
  ok "tunnel budget ($id)"
  [[ -f $HOME/.cloudflared/$id.json ]] || die "The tunnel's credentials aren't in ~/.cloudflared/$id.json. It was made on another machine: delete it (cloudflared tunnel delete budget) and run this again."
  cloudflared tunnel route dns budget "$host" >/dev/null 2>&1 && ok "DNS: $host → the tunnel" \
    || warn "couldn't add the DNS record for $host. If it already points to this tunnel, that's fine; otherwise remove the old record on Cloudflare and run this again"
  mkdir -p "$BUDGET_HOME/logs"
  cat > "$config" <<EOF
# Written by ./setup.sh address cloudflare. The tunnel reaches the API only: never the dashboard.
tunnel: $id
credentials-file: $HOME/.cloudflared/$id.json
ingress:
  - hostname: $host
    service: http://127.0.0.1:$(api_port)
  - service: http_status:404
EOF
  cloudflared tunnel --config "$config" ingress validate >/dev/null || die "cloudflared rejected $config"
  launch_agent local.budget.tunnel "$BUDGET_HOME/logs/tunnel.log" -- "$(command -v cloudflared)" --no-autoupdate tunnel --config "$config" run
  ok "the tunnel runs as launchd job local.budget.tunnel (log: $BUDGET_HOME/logs/tunnel.log)"
  ADDRESS="https://$host"
}

# MARK: - app

cmd_app() {
  [[ $OS == Darwin ]] || die "The app is built on a Mac with Xcode: run ./setup.sh app there."
  command -v xcodegen >/dev/null || die "xcodegen isn't installed: ./setup.sh tools"
  [[ -n $KIND ]] || { local found; found=$(installed_kind); [[ -n $found ]] && use_kind "$found"; }
  step "Signing"
  local cfg="$REPO/Config/Local.xcconfig" team prefix
  team=$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' "$cfg" 2>/dev/null || true)
  prefix=$(sed -n 's/^BUDGET_BUNDLE_PREFIX *= *//p' "$cfg" 2>/dev/null || true)
  if [[ -n $team && $team != ABCDE12345 && -n $prefix && $prefix != com.yourname && $prefix != com.example ]]; then
    ok "Config/Local.xcconfig: team $team, app $prefix.budget"
  else
    # Xcode's signed-in accounts, to offer a default: "teamID<TAB>name<TAB>free" per team.
    local teams default_team
    teams=$(defaults export com.apple.dt.Xcode - 2>/dev/null | /usr/bin/python3 -I -c '
import plistlib, sys
d = plistlib.loads(sys.stdin.buffer.read()).get("IDEProvisioningTeamByIdentifier", {})
seen = set()
for ts in d.values():
    for t in ts:
        if t.get("teamID") not in seen:
            seen.add(t.get("teamID")); print(t.get("teamID"), t.get("teamName"), int(t.get("isFreeProvisioningTeam", 0)), sep="\t")
' 2>/dev/null || true)
    if [[ -n $teams ]]; then
      echo "  Teams signed in to Xcode:"
      awk -F'\t' '{ printf "    %s  %s%s\n", $1, $2, ($3 == 1 ? " (free Personal Team)" : "") }' <<<"$teams"
      default_team=$(awk -F'\t' '$3 == 0 {print $1; exit}' <<<"$teams")
    else
      echo "  No team is signed in to Xcode yet (Xcode → Settings → Accounts). The team ID is on https://developer.apple.com/account → Membership details."
    fi
    prompt BUDGET_TEAM_ID "Apple Developer team ID" "$default_team"; team=$BUDGET_TEAM_ID
    [[ $team =~ ^[A-Z0-9]{10}$ ]] || die "A team ID is 10 letters and digits ($team)."
    prompt BUDGET_BUNDLE_PREFIX "Bundle ID prefix you own, such as com.yourname"; prefix=$BUDGET_BUNDLE_PREFIX
    [[ $prefix =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ && $prefix != com.yourname && $prefix != com.example ]] \
      || die "Use a reverse-DNS prefix of your own, such as com.yourname ($prefix)."
    if [[ -f $cfg ]]; then cp "$cfg" "$cfg.bak"; warn "kept the old one as Config/Local.xcconfig.bak"; fi
    sed -e "s/^DEVELOPMENT_TEAM *=.*/DEVELOPMENT_TEAM = $team/" -e "s/^BUDGET_BUNDLE_PREFIX *=.*/BUDGET_BUNDLE_PREFIX = $prefix/" \
      "$REPO/Config/Local.xcconfig.example" > "$cfg"
    ok "wrote Config/Local.xcconfig: team $team, app $prefix.budget"
    if [[ $(awk -F'\t' -v t="$team" '$1 == t {print $3}' <<<"$teams") == 1 ]]; then
      warn "That's a free Personal Team: it can't sign push (remove the entitlements: block from project.yml), and the app expires after 7 days."
    fi
  fi

  step "Project"
  (cd "$REPO" && xcodegen generate --quiet)
  ok "generated Budget.xcodeproj"

  step "iPhone"
  local found udid name
  found=$(phones)
  if [[ -n ${BUDGET_DEVICE:-} ]]; then found=$(awk -F'\t' -v d="$BUDGET_DEVICE" '$1 == d || $2 == d' <<<"$found"); fi
  if [[ -z $found ]]; then
    warn "no iPhone${BUDGET_DEVICE:+ named $BUDGET_DEVICE} is connected. Plug one in (and trust this Mac), then: ./setup.sh app"
    echo "  Or open Budget.xcodeproj, pick the phone and Run. The simulator needs none of this: it starts on the demo ledger."
    return 0
  fi
  if (( $(wc -l <<<"$found") > 1 )); then
    echo "  Connected:"; awk -F'\t' '{ printf "    %d) %s  %s\n", NR, $2, $1 }' <<<"$found"
    local pick; prompt BUDGET_DEVICE_PICK "Which one" 1; pick=$BUDGET_DEVICE_PICK
    found=$(sed -n "${pick}p" <<<"$found")
  fi
  udid=$(cut -f1 <<<"$found"); name=$(cut -f2 <<<"$found")
  ask "Build Budget and install it on $name?" || return 0

  echo "  building (Release; the first build takes a few minutes)"
  local log="$DERIVED/build.log"
  mkdir -p "$DERIVED"
  if ! xcodebuild -project "$REPO/Budget.xcodeproj" -scheme Budget -configuration Release \
      -destination "platform=iOS,id=$udid" -derivedDataPath "$DERIVED" -allowProvisioningUpdates build > "$log" 2>&1; then
    grep -E 'error:|requires a provisioning profile|No Account|not registered' "$log" | sort -u | head -8 | sed 's/^/    /' >&2
    die "The build failed (full log: $log). Signing errors usually mean Xcode → Settings → Accounts isn't signed in to team $team, or Developer Mode is off on the phone (Settings → Privacy & Security). docs/INSTALL-APP.md → Troubleshooting."
  fi
  ok "built"
  xcrun devicectl device install app --device "$udid" "$DERIVED/Build/Products/Release-iphoneos/Budget.app" >/dev/null \
    || die "Installing on $name failed. Is it unlocked, with Developer Mode on (Settings → Privacy & Security)?"
  ok "installed on $name"
  xcrun devicectl device process launch --device "$udid" "$prefix.budget" >/dev/null 2>&1 && ok "launched" \
    || warn "open Budget on the phone (if it says Untrusted Developer: Settings → General → VPN & Device Management)"

  local url; url=$(env_get BUDGET_PUBLIC_URL)
  echo
  echo "  On the phone, enter the server's address ${url:+($url) }and the token from the dashboard:"
  echo "  the dashboard → Settings → Connect your phone → Show."
  echo "  For the morning summary, the dashboard's Notifications wants the bundle ID $prefix.budget."
}

# MARK: - main

all() {
  case ${BUDGET_BANKS:-} in ''|plaid|simplefin|later) ;; *) die "BUDGET_BANKS is plaid, simplefin or later ($BUDGET_BANKS)." ;; esac
  printf '%sBudget setup%s: the server, the phone'"'"'s address, then the app. Each step asks first.\n' "$B" "$N"
  step "Where the server runs"
  pick_server "" skip
  cmd_tools
  case $KIND in
    none) warn "no server here. The app can point at a server elsewhere (or the demo ledger in the simulator)." ;;
    olares) server_olares; cmd_address ;;
    *)
      cmd_server "$KIND"
      ask "Give the phone an HTTPS address for the API now?" && cmd_address
      ;;
  esac
  [[ $OS == Darwin ]] && { ask "Set up and build the iPhone app?" && cmd_app; }
  echo
  [[ $KIND == none ]] && KIND=''
  cmd_check || true
  [[ $KIND == mac || $KIND == docker ]] || return 0
  echo
  # Banks already linked: the choice is made, so don't ask it again on a re-run.
  local banks; banks=$(bank_counts "http://127.0.0.1:$(dash_port)")
  if [[ -n $banks && $banks != "Banks: 0 "* ]]; then
    banks="  1. $banks; add more at http://budget.localhost:$(dash_port) → Accounts → Connect a bank"
  else
    choose BUDGET_BANKS "How will this server get bank data? Either works, and you can add the other later." later \
      "plaid|Plaid: your own developer account and keys; card bills, merchant names, 2 years of history; the free Trial is 10 bank logins, ever" \
      "simplefin|SimpleFIN: \$15 a year, one token, up to 25 banks; about daily, 90 days per request, no card bills" \
      "later|decide on the dashboard, which shows the two side by side"
    banks="  1. Link banks: http://budget.localhost:$(dash_port) → Accounts → Connect a bank
$(banks_next)"
  fi
  cat <<EOF

${B}Next, in a browser on this machine${N} (docs/INSTALL-SERVER.md walks through each):
$banks
  2. Optional: a model for Ask, under Settings → Models
  3. Optional: the morning summary, under Settings → Notifications
Save BUDGET_TOKEN_KEY from $ENV_FILE in a password manager: without it, every bank must be linked again.
EOF
}

banks_next() {  # the steps for BUDGET_BANKS, or the comparison when it's undecided
  case ${BUDGET_BANKS:-later} in
    plaid) cat <<'EOF'
     a. Make a Plaid account: https://dashboard.plaid.com (Sandbox is free; real banks need the free Trial or a paid plan)
     b. Copy the client ID and secret from https://dashboard.plaid.com/developers/keys into the Plaid tab → Keys
     c. Add the return address shown there under Allowed redirect URIs: https://dashboard.plaid.com/developers/api
     d. Link an account
EOF
    ;;
    simplefin) cat <<'EOF'
     a. Sign up at https://beta-bridge.simplefin.org ($15 a year, or $1.50 a month)
     b. Add your banks there; check coverage at https://beta-bridge.simplefin.org/search-institutions
     c. Create a setup token there and paste it in the SimpleFIN tab
EOF
    ;;
    *) cat <<'EOF'
     Plaid or SimpleFIN (the dashboard shows the same comparison):
                    Plaid                                         SimpleFIN
       Cost         your Plaid account; free Trial = 10 logins    $15/yr to SimpleFIN, up to 25 banks
       Setup        developer sign-up, keys, identity check       sign up, add banks there, paste a token
       Card bills   yes                                           no
       Merchants    names and bank categories                     raw bank descriptions
       History      up to 2 years at link                         ~90 days per request, walked back further
       Freshness    several times a day                           about once a day
       Investments  holdings by position                          balances only
EOF
    ;;
  esac
}

case ${1:-} in
  "")      all ;;
  check)   cmd_check ;;
  tools)   cmd_tools ;;
  server)  cmd_server "${2:-}" ;;
  address) cmd_address "${2:-}" ;;
  app)     cmd_app ;;
  -h|--help|help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" ;;
  *) echo "usage: $0 [check | tools | server [mac|docker|olares] | address [tailscale|caddy|cloudflare|url] | app]" >&2; exit 2 ;;
esac
