#!/usr/bin/env bash
# Sets up Budget from a fresh clone: the tools, the server, an HTTPS address for the phone, and the app.
# Every step checks first and skips what's already done, so it's safe to run again (and to update: git pull, then this).
#
#   ./setup.sh                    everything, in order, asking before each step
#   ./setup.sh check [--json]     what's done, what's left, and a last "Next:" line naming the one next step; changes
#                                 nothing. --json prints the same for an agent. Exits 0 when nothing is left to fix
#                                 (steps waiting on you don't count), 1 otherwise
#   ./setup.sh before             what you paste into your own Terminal first: the steps that need your password or a
#                                 browser (Homebrew, Xcode's license, signing in to Xcode, the docker group on Linux)
#   ./setup.sh tools              what the chosen server and the app need (Homebrew: xcodegen, postgresql@16)
#   ./setup.sh server [where]     where the server runs:
#                                   mac     this Mac: launchd, Homebrew's Postgres, nightly backups (deploy/macos)
#                                   docker  Docker Compose: server, Postgres, daily backups (deploy/docker); Linux, a NAS,
#                                           or a Mac with Docker
#                                   olares  owner only (the chart isn't in this repo): builds this checkout and updates
#                                           the budgetapi app installed there. Refuses a checkout with uncommitted changes
#   ./setup.sh address [how]      the phone's HTTPS address for the API, saved as BUDGET_PUBLIC_URL and checked:
#                                   tailscale   Tailscale Serve: private to your devices (Tailscale must be installed);
#                                               no Plaid webhooks and no phone reconnect
#                                   caddy       Caddy on your domain, ports 80 and 443 forwarded here
#                                   cloudflare  a Cloudflare Tunnel on your domain, no open ports (on a Mac)
#                                   url         an address you already have
#   ./setup.sh app                Config/Local.xcconfig (team, prefix, BUDGET_FREE_TEAM for a free Personal Team,
#                                 BUDGET_API_HOST for phone reconnect), the server's BUDGET_IOS_APP_ID, APNS_TEAM_ID and
#                                 APNS_TOPIC (paid teams), xcodegen, and with an iPhone connected: build, install, and
#                                 launch it with the server's address and token (pairs it; the token is never shown).
#                                 Prints NOT INSTALLED and exits 1 when nothing was installed
#   ./setup.sh banks [plaid|simplefin]   the steps to get bank data, filled in for this install, for each kind of
#                                 server; with no argument, the two compared and both
#   ./setup.sh bank simplefin [--stdin]  links SimpleFIN with a setup token you copied: reads the clipboard (or stdin),
#                                 hands it to this machine's dashboard, clears the clipboard, prints only counts
#   ./setup.sh secret NAME [--stdin]     sets one budget.env value without showing it: typed in your Terminal, else the
#                                 clipboard, or stdin; then restarts the server. NAME is one of PLAID_CLIENT_ID,
#                                 PLAID_SECRET, PLAID_ENV, PLAID_REDIRECT_URI, PLAID_MOBILE_REDIRECT_URI, APNS_KEY (the
#                                 .p8 text), APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC, OPENROUTER_API_KEY, MODEL_BASE_URL,
#                                 MODEL_API_KEY, MODEL_NAME, DECISION_BASE_URL, DECISION_API_KEY
#   ./setup.sh save-key [--clipboard|--done]   puts BUDGET_TOKEN_KEY in your login Keychain ("Budget server token key")
#                                 without showing it; --clipboard puts it on the clipboard instead; --done records that
#                                 you saved it yourself. check reports whether this ran
#
# Answers can come from the environment instead of prompts (for an agent). Without a terminal, every answer a step
# needs is checked first, and all the missing ones are listed at once:
#   BUDGET_SERVER         mac | docker | olares | none (no server here: the app only)
#   BUDGET_ADDRESS        tailscale | caddy | cloudflare | url
#   BUDGET_DOMAIN         the API's hostname, for caddy or cloudflare (budget.example.com)
#   BUDGET_PUBLIC_URL     the phone's address, for url         BUDGET_ACME_EMAIL     optional, for Caddy's certificates
#   BUDGET_TEAM_ID        Apple Developer team ID              BUDGET_BUNDLE_PREFIX  com.yourname (app = <prefix>.budget)
#   BUDGET_FREE_TEAM      1 for a free Personal Team, 0 for a paid one (by default, what Xcode says about the team).
#                         Free: no push, no phone reconnect, and the app stops opening after 7 days until reinstalled
#   BUDGET_RECONNECT      no leaves phone reconnect out. By default it's on with a paid team and a public https address
#   BUDGET_DEVICE         the iPhone's UDID or name            BUDGET_DEVICE_PICK    with several iPhones connected and no
#                                                                                    BUDGET_DEVICE: its number in the list
#   BUDGET_YES=1          yes to every question (needed without a terminal: there, no is the default)
#   BUDGET_DEPLOY=1       also needed, with BUDGET_YES=1 or without a terminal, to deploy to an Olares (it replaces the
#                         live server)
#   BUDGET_BANKS          plaid | simplefin | later            which provider's steps the bare ./setup.sh prints at the
#                                                              end (./setup.sh banks prints them any time)
#   BUDGET_KEYCHAIN       an existing keychain file for save-key instead of the login Keychain (for tests)
#   BUDGET_DERIVED        where ./setup.sh app builds (default ~/Library/Developer/Xcode/DerivedData/Budget-setup)
#   BUDGET_PASTE, BUDGET_COPY   the commands that read and write the clipboard (default pbpaste, pbcopy)
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
DERIVED=${BUDGET_DERIVED:-"$HOME/Library/Developer/Xcode/DerivedData/Budget-setup"}  # BUDGET_DERIVED: elsewhere, for tests
OS=$(uname)
KIND='' ENV_FILE='' ADDRESS='' CHECK_TRIES=12 PREFLIGHT_ENV=''
KEY_MARKER="$BUDGET_HOME/token-key-saved"
# What ./setup.sh app leaves once the phone has its address and token: the date, the address and a fingerprint of the
# token (never the token), so check can say when the phone needs pairing again.
PHONE_MARKER="$BUDGET_HOME/phone-paired"
XCCONFIG="$REPO/Config/Local.xcconfig"
KEYCHAIN_SERVICE="Budget server token key"
SECRET_NAMES="PLAID_CLIENT_ID PLAID_SECRET PLAID_ENV PLAID_REDIRECT_URI PLAID_MOBILE_REDIRECT_URI APNS_KEY APNS_KEY_ID APNS_TEAM_ID APNS_TOPIC OPENROUTER_API_KEY MODEL_BASE_URL MODEL_API_KEY MODEL_NAME DECISION_BASE_URL DECISION_API_KEY"
export PATH="/opt/homebrew/bin:/opt/homebrew/opt/postgresql@16/bin:/usr/local/bin:$PATH"

if [[ -t 1 ]]; then B=$'\e[1m' G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' N=$'\e[0m'; else B='' G='' Y='' R='' N=''; fi
step() { printf '\n%s==> %s%s\n' "$B" "$*" "$N"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$R" "$N" "$*"; }
die()  { printf '%s%s%s\n' "$R" "$*" "$N" >&2; exit 1; }
usage() {
  echo "usage: $0 [check [--json] | before | tools | server [mac|docker|olares] | address [tailscale|caddy|cloudflare|url] | app
          | banks [plaid|simplefin] | bank simplefin [--stdin] | secret NAME [--stdin] | save-key [--clipboard|--done]]" >&2
  exit 2
}

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
    olares|none) ENV_FILE='' ;;
    *) die "BUDGET_SERVER is mac, docker, olares or none ($KIND)." ;;
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
    [[ -n $found || -f $OLARES_DIR/deploy.env ]] && opts+=("olares|an Olares, owner only: update the budgetapi app installed there")
    [[ ${2:-} == skip ]] && opts+=("none|no server here: the app will use one somewhere else")
    choose BUDGET_SERVER "Where should the server run?" "$default" "${opts[@]}"
    want=$BUDGET_SERVER
  fi
  [[ $want == none ]] && { use_kind none; return 0; }
  [[ -n $found && $found != "$want" ]] && warn "a server is also set up here for $found; this step works on $want"
  use_kind "$want"
}
server_here() {  # server_here "what" ["where on an Olares"] — the Mac or Docker install whose budget.env this works on
  local found=${BUDGET_SERVER:-$(installed_kind)}
  case $found in
    mac|docker) use_kind "$found"; [[ -f $ENV_FILE ]] || die "There's no $ENV_FILE yet: ./setup.sh server $found first." ;;
    olares) die "On an Olares, $1 isn't done from here: ${2:-its settings are in the Olares app}." ;;
    none) die "BUDGET_SERVER=none: there's no server on this machine for $1." ;;
    *) die "No server is set up on this machine yet: ./setup.sh server" ;;
  esac
}

env_get() {  # env_get KEY — a value from the server's settings file, without sourcing it into this shell
  [[ -n $ENV_FILE && -f $ENV_FILE ]] || return 0
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -1
}
env_set() {  # env_set KEY VALUE — replaces KEY's line (commented or not), or appends it. The value goes to awk through
  local tmp  # its environment, never its arguments, which other users can list.
  tmp=$(mktemp "$(dirname "$ENV_FILE")/.env.XXXXXX")
  ENV_SET_KEY=$1 ENV_SET_VALUE=$2 awk '
    BEGIN { k = ENVIRON["ENV_SET_KEY"]; v = ENVIRON["ENV_SET_VALUE"] }
    $0 ~ "^#? *" k "=" { if (!done) print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }' "$ENV_FILE" > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$ENV_FILE"
}
mode_of() { if [[ $OS == Darwin ]]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi 2>/dev/null || true; }
api_port()  { local p=''; [[ $KIND == mac ]] && p=$(env_get PORT); echo "${p:-8080}"; }
dash_port() { local p=''; [[ $KIND == mac ]] && p=$(env_get DASHBOARD_PORT); echo "${p:-8081}"; }
healthy()   { curl -fsS --max-time "${2:-3}" "$1/health" 2>/dev/null | grep -q '"ok"'; }
# /health tells the version only to a request with the token, which goes to curl as a file so it never shows in ps.
version_at() {
  local v
  v=$(curl -fsS --max-time 3 -H @<(printf 'Authorization: Bearer %s\n' "$(env_get BUDGET_API_TOKEN)") "$1/health" 2>/dev/null |
    sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
  echo "${v:-version hidden: no token here}"
}
url_host()  { local h=${1#*://}; h=${h%%/*}; echo "${h%%:*}"; }
docker_ready() { command -v docker >/dev/null && docker compose version >/dev/null 2>&1; }
# Compose, with the caddy profile on once ./setup.sh address caddy has written its Caddyfile.
dc() {
  local profiles=''
  [[ -f $DOCKER_DIR/Caddyfile ]] && profiles=caddy
  COMPOSE_PROFILES=$profiles docker compose -f "$DOCKER_DIR/compose.yaml" "$@"
}
restart_server() {  # sets RESTARTED when it did
  RESTARTED=''
  case $KIND in
    mac)
      if launchctl print "$GUI/local.budget.server" >/dev/null 2>&1; then
        launchctl kickstart -k "$GUI/local.budget.server" >/dev/null && { RESTARTED=1; ok "restarted the server"; }
      else warn "the server isn't a launchd job here; restart it yourself so it picks up the change"; fi ;;
    docker) dc up -d --force-recreate --no-deps server >/dev/null 2>&1 && { RESTARTED=1; ok "restarted the server"; } \
              || warn "restarting the server failed: docker compose -f deploy/docker/compose.yaml up -d" ;;
  esac
  return 0
}
wait_healthy() {  # wait_healthy URL TRIES — every 2 s
  for _ in $(seq 1 "$2"); do healthy "$1" && return 0; sleep 2; done
  return 1
}

# The clipboard and the terminal, for values that must never be shown. BUDGET_PASTE and BUDGET_COPY swap the clipboard
# commands (a test passes its own, so it never touches the real clipboard).
clip_ok()    { local c=${BUDGET_PASTE:-pbpaste}; command -v "${c%% *}" >/dev/null; }
clip_paste() { ${BUDGET_PASTE:-pbpaste}; }
clip_copy()  { ${BUDGET_COPY:-pbcopy}; }
clip_clear() { printf '' | clip_copy 2>/dev/null || true; }
read_hidden() {  # read_hidden "label" [pem] — typed or pasted in the terminal without echo, on stdout; pem reads to END
  local line value=''
  printf '  %s (it won'"'"'t show as you type or paste): ' "$1" >/dev/tty
  IFS= read -rs line </dev/tty || true
  value=$line
  if [[ ${2:-} == pem && $line == *BEGIN* && $line != *END* ]]; then
    while IFS= read -rs line </dev/tty; do value+=$'\n'$line; [[ $line == *END* ]] && break; done
  fi
  printf '\n' >/dev/tty
  printf '%s' "$value"
}
trim() { local s=$1; s=${s//$'\r'/}; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }
fingerprint() { if command -v shasum >/dev/null; then shasum -a 256; else sha256sum; fi | cut -c1-12; }

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

# Xcode's signed-in teams, one "teamID<TAB>name<TAB>free" per team (free is 1 for a free Personal Team).
xcode_teams() {
  [[ $OS == Darwin ]] || return 0
  defaults export com.apple.dt.Xcode - 2>/dev/null | /usr/bin/python3 -I -c '
import plistlib, sys
d = plistlib.loads(sys.stdin.buffer.read()).get("IDEProvisioningTeamByIdentifier", {})
seen = set()
for ts in d.values():
    for t in ts:
        if t.get("teamID") not in seen:
            seen.add(t.get("teamID")); print(t.get("teamID"), t.get("teamName"), int(t.get("isFreeProvisioningTeam", 0)), sep="\t")
' 2>/dev/null || true
}

# MARK: - the dashboard, read without a secret

dash_get() { curl -fsS --max-time 3 "$1" 2>/dev/null; }
dash_setting() {  # dash_setting DASHBOARD_URL key|environmentVariable NAME — "value<TAB>origin" of one setting (a secret's value is never sent)
  dash_get "$1/dash/settings" | /usr/bin/python3 -I -c '
import json, sys
try: fields = json.load(sys.stdin)
except ValueError: sys.exit()
for f in fields if isinstance(fields, list) else []:
    if isinstance(f, dict) and f.get(sys.argv[1]) == sys.argv[2]:
        value = "" if f.get("kind") == "secret" else (f.get("value") or "")
        print("%s\t%s" % (value, f.get("origin") or "")); break' "$2" "$3" 2>/dev/null || true
}
dash_providers() {  # dash_providers DASHBOARD_URL — "origin<TAB>environment<TAB>sealing" for Plaid's keys, or nothing
  dash_get "$1/dash/providers" | /usr/bin/python3 -I -c '
import json, sys
try: d = json.load(sys.stdin)["providers"]
except (ValueError, KeyError, TypeError): sys.exit()
p = d.get("plaid") or {}
print("%s\t%s\t%s" % (p.get("origin") or "none", p.get("environment") or "-", "yes" if d.get("sealingAvailable") else "no"))' 2>/dev/null || true
}
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

effective_env() {  # effective_env NAME — a non-secret setting as the server uses it: the dashboard's answer, else budget.env's
  local line=''
  [[ $KIND == mac || $KIND == docker ]] && line=$(dash_setting "http://127.0.0.1:$(dash_port)" environmentVariable "$1")
  if [[ -n ${line%%$'\t'*} ]]; then echo "${line%%$'\t'*}"; else env_get "$1"; fi
}
dash_isset() {  # dash_isset DASHBOARD_URL NAME — yes when the setting for that environment variable has a value (never the value)
  dash_get "$1/dash/settings" | /usr/bin/python3 -I -c '
import json, sys
try: fields = json.load(sys.stdin)
except ValueError: sys.exit()
for f in fields if isinstance(fields, list) else []:
    if isinstance(f, dict) and f.get("environmentVariable") == sys.argv[1]:
        print("yes" if f.get("isSet") else "no"); break' "$2" 2>/dev/null || true
}
dash_chat_model() {  # dash_chat_model DASHBOARD_URL — which model Ask uses (an id, or off), from /dash/models
  dash_get "$1/dash/models" | /usr/bin/python3 -I -c '
import json, sys
try: print(json.load(sys.stdin).get("chatInUse") or "")
except (ValueError, AttributeError): pass' 2>/dev/null || true
}

# The phone's address as the server has it: the dashboard's value (Settings → Phone) wins over budget.env's.
# Sets PUB_URL and PUB_FROM (dashboard | environment | budget.env, or empty).
effective_public_url() {
  PUB_URL='' PUB_FROM=''
  if [[ $KIND == mac || $KIND == docker ]]; then
    local line; line=$(dash_setting "http://127.0.0.1:$(dash_port)" key publicURL)
    if [[ -n ${line%%$'\t'*} ]]; then
      PUB_URL=${line%%$'\t'*}; PUB_FROM=${line#*$'\t'}
      [[ $PUB_FROM == dashboard ]] || PUB_FROM=budget.env
    else PUB_URL=$(env_get BUDGET_PUBLIC_URL); [[ -n $PUB_URL ]] && PUB_FROM=budget.env; fi
  elif [[ -n ${BUDGET_PUBLIC_URL:-} ]]; then PUB_URL=$BUDGET_PUBLIC_URL; PUB_FROM=environment
  fi
  PUB_URL=${PUB_URL%/}
  return 0
}

# MARK: - before

# What this machine still needs from the person, in their own Terminal or by hand: BEFORE_RUN (commands to paste,
# which ask for their password) and BEFORE_HAND (clicks).
before_items() {
  BEFORE_RUN=() BEFORE_HAND=()
  local kind=${KIND:-${BUDGET_SERVER:-$(installed_kind)}}
  if [[ $OS == Darwin ]]; then
    local xcode=''
    xcodebuild -version >/dev/null 2>&1 && xcode=1
    command -v brew >/dev/null || BEFORE_RUN+=('/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"')
    if [[ -z $xcode ]] && ! ls -d /Applications/Xcode*.app >/dev/null 2>&1; then
      BEFORE_HAND+=("Install Xcode 26 or later from the App Store and open it once: https://apps.apple.com/app/xcode/id497799835")
    fi
    [[ -n $xcode ]] || BEFORE_RUN+=("sudo xcode-select -s /Applications/Xcode.app")
    if [[ -z $xcode ]] || ! xcodebuild -license check >/dev/null 2>&1; then BEFORE_RUN+=("sudo xcodebuild -license accept"); fi
    [[ -n $(xcode_teams) ]] || BEFORE_HAND+=("Sign in to Xcode: open Xcode, then Settings → Accounts → + (bottom left) → Apple Account → Continue")
    if [[ $kind == docker ]] && ! docker_ready; then
      BEFORE_HAND+=("Install Docker Desktop (https://www.docker.com/products/docker-desktop/) or OrbStack (https://orbstack.dev), and start it")
    fi
    if [[ ${BUDGET_ADDRESS:-} == cloudflare && ! -f $HOME/.cloudflared/cert.pem ]]; then
      command -v cloudflared >/dev/null || BEFORE_RUN+=("brew install cloudflared")
      BEFORE_RUN+=("cloudflared tunnel login")
      BEFORE_HAND+=("In the browser window cloudflared opens, sign in to Cloudflare and pick the domain for the API")
    fi
  else
    if ! docker_ready; then
      BEFORE_HAND+=("Install Docker Engine with the Compose plugin: https://docs.docker.com/engine/install/")
    elif ! docker info >/dev/null 2>&1 && ! id -nG 2>/dev/null | grep -qw docker; then
      BEFORE_RUN+=('sudo usermod -aG docker $USER')
      BEFORE_HAND+=("Log out and back in (or restart) so the docker group takes effect")
    fi
  fi
  return 0
}
cmd_before() {
  before_items
  step "Before: what you do yourself"
  if (( ${#BEFORE_RUN[@]} + ${#BEFORE_HAND[@]} == 0 )); then
    ok "nothing: every step that needs your password or a browser is done"; return 0
  fi
  if (( ${#BEFORE_RUN[@]} )); then
    echo "  Paste this into your own Terminal (sudo asks for your password; nothing here can type it):"
    echo
    printf '    %s\n' "${BEFORE_RUN[@]}"
    echo
  fi
  if (( ${#BEFORE_HAND[@]} )); then
    echo "  By hand:"
    printf '    - %s\n' "${BEFORE_HAND[@]}"
  fi
  echo "  Then: ./setup.sh check"
}
# A step only the person can do. With a terminal, stop with the reason; without one (an agent running this), print the
# whole Before block too, and stop rather than start an installer that waits for a password.
person_stop() {  # person_stop "why"
  [[ -t 0 ]] && die "$1"
  printf '%s%s%s\n' "$R" "$1" "$N" >&2
  cmd_before
  exit 1
}

# MARK: - check

# Each step check finds: printed as it goes, and kept for --json and the "Next:" line. STATE is done, todo (something
# to run), person (waiting on the person), warn or skipped. NEXT is what to do about it.
R_ID=() R_STATE=() R_LINE=() R_URL=() R_NEXT=()
rec() {  # rec ID STATE "detail" [URL] [NEXT]
  local id=$1 state=$2 line=$3 url=${4:-} next=${5:-}
  [[ -n $next && $state != "done" ]] && line+=" ($next)"
  R_ID+=("$id"); R_STATE+=("$state"); R_LINE+=("$line"); R_URL+=("$url"); R_NEXT+=("${next:-$3}")
  case $state in
    done)    ok "$line" ;;
    todo)    bad "$line" ;;
    person)  printf '  %s→%s %s\n' "$Y" "$N" "$line" ;;
    warn)    warn "$line" ;;
    skipped) printf '  - %s\n' "$line" ;;
  esac
  if [[ -n $url && $line != *"$url"* ]]; then printf '      %s\n' "$url"; fi
  return 0
}
check_next() {  # the first step left, in order (the order is what depends on what); else the first warning
  local i
  for i in "${!R_ID[@]}"; do
    if [[ ${R_STATE[i]} == todo || ${R_STATE[i]} == person ]]; then echo "${R_NEXT[i]}${R_URL[i]:+ (${R_URL[i]})}"; return 0; fi
  done
  for i in "${!R_ID[@]}"; do
    if [[ ${R_STATE[i]} == warn ]]; then echo "${R_NEXT[i]}"; return 0; fi
  done
  echo "nothing: setup is done"
}
check_failed() { [[ " ${R_STATE[*]} " == *" todo "* || " ${R_STATE[*]} " == *" warn "* ]]; }
json_str() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\t'/\\t}; s=${s//$'\n'/\\n}; s=${s//$'\r'/}
  printf '"%s"' "$s"
}
check_json() {
  local i sep=''
  printf '{"version":1,"server":%s,"steps":[' "$(json_str "${KIND:-none}")"
  for i in "${!R_ID[@]}"; do
    printf '%s{"id":%s,"state":%s,"detail":%s' "$sep" "$(json_str "${R_ID[i]}")" "$(json_str "${R_STATE[i]}")" "$(json_str "${R_LINE[i]}")"
    [[ -n ${R_URL[i]} ]] && printf ',"url":%s' "$(json_str "${R_URL[i]}")"
    printf '}'; sep=','
  done
  printf '],"next":%s}\n' "$(json_str "$(check_next)")"
}

check_installed() {  # what a Mac or Docker install has in common: settings, API, dashboard, backups
  local backups=$1
  if [[ $(mode_of "$ENV_FILE") == 600 ]]; then rec env_private "done" "budget.env is private (600)"
  else rec env_private todo "$ENV_FILE isn't mode 600" "" "chmod 600 \"$ENV_FILE\""; fi
  local key id
  for key in BUDGET_API_TOKEN BUDGET_TOKEN_KEY; do
    id=$(tr '[:upper:]' '[:lower:]' <<<"${key#BUDGET_}")
    if [[ -n $(env_get $key) ]]; then rec "$id" "done" "$key is set"
    else rec "$id" todo "$key is empty in budget.env" "" "./setup.sh server $KIND"; fi
  done
  local api="http://127.0.0.1:$(api_port)"
  if healthy "$api"; then rec api "done" "API answers on 127.0.0.1:$(api_port) ($(version_at "$api"))"
  else rec api todo "API isn't answering on 127.0.0.1:$(api_port)" "" "./setup.sh server $KIND"; fi
  if curl -fsS --max-time 3 -o /dev/null "http://127.0.0.1:$(dash_port)/" 2>/dev/null; then
    DASH_UP=1; rec dashboard "done" "dashboard: http://budget.localhost:$(dash_port)"
  else rec dashboard warn "the dashboard isn't answering on $(dash_port)" "" "./setup.sh server $KIND"; fi
  local latest; latest=$(ls -1t "$backups"/budget-*.dump 2>/dev/null | head -1 || true)
  if [[ -n $latest ]]; then rec backups "done" "latest backup: $(basename "$latest")"
  elif [[ -z $(find "$ENV_FILE" -mtime +1 2>/dev/null) ]]; then rec backups skipped "no backup yet: the first runs tonight"
  else rec backups warn "no backup in $backups yet" "" "see the backup log; docs/INSTALL-SERVER.md → Backups"; fi
}

check_steps() {
  local found; found=$(installed_kind)
  [[ -n ${BUDGET_SERVER:-} ]] && found=$BUDGET_SERVER
  [[ -n $found ]] && use_kind "$found"
  DASH_UP=''

  if [[ $OS == Darwin ]]; then
    step "This Mac"
    local ver major; ver=$(sw_vers -productVersion); major=${ver%%.*}
    if (( major >= 26 )); then rec macos "done" "macOS $ver"
    elif [[ $KIND == mac ]]; then rec macos todo "macOS $ver: the server needs 26 or later" "" "BUDGET_SERVER=docker ./setup.sh server"
    else rec macos skipped "macOS $ver: fine for Docker; a server on this Mac would need 26 or later"; fi
    if xcode-select -p >/dev/null 2>&1 && xcodebuild -version >/dev/null 2>&1; then
      rec xcode "done" "$(xcodebuild -version | head -1), $(swift --version 2>&1 | grep -o 'Swift version [0-9.]*' || true)"
      xcodebuild -license check >/dev/null 2>&1 || rec xcode_license person "Xcode's license isn't accepted yet" "" "./setup.sh before"
      if [[ -n $(xcode_teams) ]]; then rec xcode_account "done" "Xcode is signed in to an Apple Account"
      else rec xcode_account person "Xcode isn't signed in to an Apple Account" "" "./setup.sh before"; fi
    else rec xcode person "Xcode isn't installed (or xcode-select points at the Command Line Tools)" "https://apps.apple.com/app/xcode/id497799835" "./setup.sh before"; fi
    if command -v brew >/dev/null; then rec homebrew "done" "Homebrew"; else rec homebrew person "Homebrew isn't installed" "" "./setup.sh before"; fi
    local tool
    for tool in xcodegen psql caddy cloudflared; do
      if command -v $tool >/dev/null; then rec "$tool" "done" "$tool"
      elif [[ $tool == xcodegen || ($tool == psql && $KIND == mac) ]]; then rec "$tool" todo "$tool isn't installed" "" "./setup.sh tools"; fi
    done
  else
    step "This machine"
    rec machine "done" "$(uname -sr)"
  fi
  if docker_ready; then
    rec docker "done" "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "(not running)")"
    if [[ $KIND == docker && $OS != Darwin ]] && ! docker info >/dev/null 2>&1; then
      rec docker_access person "this user can't reach Docker" "" "./setup.sh before"
    fi
  elif [[ $KIND == docker ]]; then rec docker person "Docker with Compose isn't installed" "" "./setup.sh before"; fi
  local ts; ts=$(tailscale_cli || true)
  [[ -n $ts ]] && rec tailscale "done" "Tailscale"

  step "Server"
  case $KIND in
    mac)
      if [[ -x $BUDGET_HOME/bin/budget-server ]]; then rec server "done" "on this Mac, in $BUDGET_HOME"
      else rec server todo "budget.env is there, but no server binary" "" "./setup.sh server mac"; fi
      local host; host=$(env_get HOST)
      if [[ ${host:-127.0.0.1} == 127.0.0.1 || $host == localhost ]]; then rec loopback "done" "listens on loopback only"
      else rec loopback todo "HOST=$host: the dashboard has no login" "" "set HOST=127.0.0.1 in budget.env"; fi
      local pg; pg=$(env_get POSTGRES_HOST)
      if [[ -z $pg ]]; then rec postgres warn "no POSTGRES_HOST: the ledger is in memory and lost on restart" "" "./setup.sh server mac"
      elif pg_isready -q -h "$pg" -p "$(env_get POSTGRES_PORT | grep . || echo 5432)" 2>/dev/null; then rec postgres "done" "Postgres answers on $pg"
      else rec postgres todo "Postgres isn't answering on $pg" "" "brew services start postgresql@16"; fi
      if agent_loaded local.budget.server; then rec launchd "done" "launchd job local.budget.server"
      else rec launchd warn "the launchd job isn't loaded" "" "./setup.sh server mac"; fi
      check_installed "$BUDGET_HOME/backups"
      if [[ $(pmset -g 2>/dev/null | awk '$1 == "sleep" {print $2}') == 0 ]]; then rec awake "done" "this Mac doesn't sleep"
      else rec awake warn "this Mac can sleep, and the server sleeps with it" "" "System Settings → Energy, or sudo pmset -a sleep 0"; fi
      ;;
    docker)
      local running; running=$(dc ps --status running --services 2>/dev/null || true)
      local svc down=''
      for svc in server db backup; do grep -qx $svc <<<"$running" || down+=" $svc"; done
      if [[ -z $down ]]; then rec server "done" "in Docker (deploy/docker/compose.yaml): server, db and backup are running"
      else rec server todo "in Docker, not running:$down" "" "./setup.sh server docker"; fi
      local published; published=$(dc port server 8081 2>/dev/null || true)
      if [[ -z $published || $published == 127.0.0.1:* ]]; then rec loopback "done" "the dashboard is published on 127.0.0.1 only"
      else rec loopback todo "the dashboard is published on $published, and it has no login" "" "publish it on 127.0.0.1 in compose.yaml"; fi
      check_installed "$DOCKER_DIR/backups"
      ;;
    olares)
      if [[ -n ${BUDGET_PUBLIC_URL:-} ]]; then
        if healthy "$BUDGET_PUBLIC_URL" 8; then rec server "done" "on an Olares (owner only): $BUDGET_PUBLIC_URL answers ($(version_at "$BUDGET_PUBLIC_URL"))"
        else rec server todo "on an Olares: $BUDGET_PUBLIC_URL doesn't answer /health" "" "check the budgetapi app on the Olares"; fi
      else rec server warn "on an Olares (owner only); this can't see it from here" "" "BUDGET_PUBLIC_URL=https://<its API entrance> ./setup.sh check"; fi
      ;;
    none) rec server skipped "no server here (BUDGET_SERVER=none): the app uses one somewhere else" ;;
    *) rec server todo "no server set up here" "" "./setup.sh server" ;;
  esac

  if [[ $KIND == mac || $KIND == docker || $KIND == olares ]]; then
    step "The phone's address"
    effective_public_url
    local url=$PUB_URL
    if [[ $KIND != olares ]]; then
      local env_url; env_url=$(env_get BUDGET_PUBLIC_URL); env_url=${env_url%/}
      if [[ $PUB_FROM == dashboard && -n $env_url && $env_url != "$url" ]]; then
        rec address_source warn "the dashboard's Server URL ($url) overrides budget.env's ($env_url)" "" "keep one: Settings → Phone on the dashboard, or budget.env"
      fi
      if [[ -z $url ]]; then rec address todo "no BUDGET_PUBLIC_URL: the phone has no address yet" "" "./setup.sh address"
      elif healthy "$url" 8; then rec address "done" "answers: $url${PUB_FROM:+ (set in the $PUB_FROM)}"
      else rec address todo "$url doesn't answer /health" "" "./setup.sh address"; fi
      agent_loaded local.budget.caddy && rec caddy_job "done" "Caddy (launchd job local.budget.caddy; log $BUDGET_HOME/logs/caddy.log)"
      if [[ $KIND == docker && -f $DOCKER_DIR/Caddyfile ]]; then
        if grep -qx caddy <<<"$(dc ps --status running --services 2>/dev/null)"; then rec caddy_job "done" "Caddy container is running"
        else rec caddy_job todo "the Caddy container isn't running" "" "docker compose -f deploy/docker/compose.yaml logs caddy"; fi
      fi
      agent_loaded local.budget.tunnel && rec tunnel "done" "Cloudflare Tunnel (launchd job local.budget.tunnel; log $BUDGET_HOME/logs/tunnel.log)"
      if [[ -n $ts ]] && "$ts" serve status 2>/dev/null | grep -q "127.0.0.1:$(api_port)"; then rec tailscale_serve "done" "Tailscale Serve forwards to 127.0.0.1:$(api_port)"; fi
    fi
    if [[ -n $url ]]; then check_public_paths "$url"; fi
  fi

  if [[ $KIND == mac || $KIND == docker ]]; then
    step "Banks"
    check_banks
  elif [[ $KIND == olares ]]; then
    step "Banks"
    rec banks person "link banks on the Olares dashboard (this can't see them from here)" "" "./setup.sh banks"
  fi

  if [[ $OS == Darwin ]]; then
    step "App"
    local team prefix free=''
    team=$(xc_get DEVELOPMENT_TEAM); prefix=$(xc_get BUDGET_BUNDLE_PREFIX)
    if [[ -n $team && $team != ABCDE12345 && -n $prefix && $prefix != com.yourname && $prefix != com.example ]]; then
      [[ $(xc_get BUDGET_FREE_TEAM) == YES ]] && free=1
      local detail="Config/Local.xcconfig: team $team, app $prefix.budget"
      if [[ -n $free ]]; then detail+=", free Personal Team"
      elif [[ -n $(xc_get BUDGET_API_HOST) ]]; then detail+=", phone reconnect on $(xc_get BUDGET_API_HOST)"; fi
      rec app_config "done" "$detail"
      if [[ -n $free ]]; then
        rec free_team skipped "a free Personal Team: no push, no phone reconnect, and the app stops opening 7 days after each install"
      elif [[ $(free_team_of "$team") == yes ]]; then
        rec free_team todo "Xcode says team $team is a free Personal Team, but Local.xcconfig doesn't: the build would fail on push" "" "BUDGET_FREE_TEAM=1 ./setup.sh app"
      fi
      if [[ -z $free && ($KIND == mac || $KIND == docker) && -f $ENV_FILE ]]; then
        # What the server uses: a value saved on the dashboard wins over budget.env's.
        local apns_team apns_topic
        apns_team=$(effective_env APNS_TEAM_ID); apns_topic=$(effective_env APNS_TOPIC)
        if [[ $apns_team == "$team" && $apns_topic == "$prefix.budget" ]]; then
          rec push_ids "done" "the server's APNS_TEAM_ID and APNS_TOPIC match the app"
        else rec push_ids todo "the server's APNS_TEAM_ID or APNS_TOPIC doesn't match the app ($team, $prefix.budget)" "" "./setup.sh app"; fi
      fi
    else rec app_config todo "no Config/Local.xcconfig with your team; the app builds for the simulator only" "" "./setup.sh app"; fi
    if [[ -d $REPO/Budget.xcodeproj ]]; then rec xcodeproj "done" "Budget.xcodeproj generated"
    else rec xcodeproj todo "Budget.xcodeproj isn't generated yet" "" "./setup.sh app"; fi
    local phone; phone=$(phones)
    if [[ -n $phone ]]; then rec phone "done" "iPhone connected: $(cut -f2 <<<"$phone" | paste -sd, - )"
    else rec phone skipped "no iPhone connected now (only installing needs one: USB, or the same Wi-Fi once paired)"; fi
    check_paired
  fi
}

check_paired() {  # whether the phone still has this server's address and token, from what ./setup.sh app left
  [[ $KIND == mac || $KIND == docker ]] || return 0
  if [[ ! -f $PHONE_MARKER ]]; then
    rec phone_paired skipped "no pairing recorded: ./setup.sh app pairs the phone (or enter the address and token on it by hand)"
    return 0
  fi
  local when server token
  when=$(sed -n 's/^paired=//p' "$PHONE_MARKER"); server=$(sed -n 's/^server=//p' "$PHONE_MARKER")
  token=$(env_get BUDGET_API_TOKEN)
  if [[ -n $token ]] && ! grep -qx "fingerprint=$(printf '%s' "$token" | fingerprint)" "$PHONE_MARKER"; then
    rec phone_paired todo "the API token changed since the phone was paired ($when)" "" "./setup.sh app"
  elif [[ -n ${PUB_URL:-} && $server != "$PUB_URL" ]]; then
    rec phone_paired todo "the phone was paired with $server, but the address is now $PUB_URL" "" "./setup.sh app"
  else rec phone_paired "done" "the phone was paired with $server ($when)"; fi
}

# The three paths on the phone's address that take no token: Apple's Universal Link file, Plaid's webhook and the
# phone's OAuth return. A proxy in front of the API (Olares, Caddy, a tunnel) has to let all three through.
check_public_paths() {
  local url=$1 out code plaid_used=yes
  if [[ $(url_host "$url") == *.ts.net ]]; then
    rec public_paths skipped "a Tailscale address: Plaid and Apple can't reach it, so no Plaid webhooks and no phone reconnect"
    return 0
  fi
  if [[ $KIND != olares ]]; then
    local p; p=$(dash_providers "http://127.0.0.1:$(dash_port)")
    [[ ${p%%$'\t'*} == none ]] && plaid_used=''
  fi
  out=$(curl -s --max-time 8 -w '\n%{http_code}' "$url/.well-known/apple-app-site-association" 2>/dev/null || true)
  code=${out##*$'\n'}
  local app_id=''
  [[ -n $(xc_get BUDGET_API_HOST) && $(xc_get BUDGET_FREE_TEAM) != YES ]] && app_id="$(xc_get DEVELOPMENT_TEAM).$(xc_get BUDGET_BUNDLE_PREFIX).budget"
  if [[ $code == 200 && ${out:0:1} == '{' && -n $app_id && $out != *"\"$app_id\""* ]]; then
    rec aasa todo "the Universal Link file doesn't name this app ($app_id), so phone reconnect won't open it" "" "./setup.sh app"
  elif [[ $code == 200 && ${out:0:1} == '{' ]]; then rec aasa "done" "the Universal Link file answers (phone reconnect)"
  elif [[ $code == 404 ]]; then
    if [[ -n $(xc_get BUDGET_API_HOST) && $(xc_get BUDGET_FREE_TEAM) != YES ]]; then
      rec aasa todo "no Universal Link file at $url: BUDGET_IOS_APP_ID isn't set on the server, but the app expects one" "" "./setup.sh app"
    else rec aasa skipped "no Universal Link file (BUDGET_IOS_APP_ID isn't set): only phone reconnect needs it"; fi
  else rec aasa warn "the Universal Link file answered ${code:-nothing}, not 200 with JSON: a proxy in front of the API may be in the way" "" "docs/SERVER.md → Olares and Plaid"; fi
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -X POST -H 'Content-Type: application/json' --data-binary '' "$url/v1/plaid/webhook" 2>/dev/null || true)
  if [[ $code == 400 ]]; then rec webhook "done" "Plaid's webhook path answers (400 to an empty test, as it should)"
  elif [[ -n $plaid_used ]]; then rec webhook warn "Plaid's webhook path answered ${code:-nothing}, not 400: Plaid's webhooks won't arrive" "" "docs/SERVER.md → Olares and Plaid"
  else rec webhook skipped "Plaid's webhook path answered ${code:-nothing} (only Plaid needs it)"; fi
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$url/plaid/oauth-return" 2>/dev/null || true)
  if [[ $code == 200 ]]; then rec oauth_return "done" "the phone's OAuth return answers"
  elif [[ -n $plaid_used ]]; then rec oauth_return warn "the phone's OAuth return answered ${code:-nothing}, not 200" "" "docs/SERVER.md → Olares and Plaid"
  else rec oauth_return skipped "the phone's OAuth return answered ${code:-nothing} (only Plaid needs it)"; fi
}

check_banks() {  # what the dashboard says about providers and links (counts and origins only), and the token key's copy
  local dash="http://127.0.0.1:$(dash_port)" dash_url="http://budget.localhost:$(dash_port)"
  if [[ -n $DASH_UP ]]; then
    local p origin env sealing
    p=$(dash_providers "$dash")
    IFS=$'\t' read -r origin env sealing <<<"${p:-none	-	-}"
    [[ $env == - ]] && env=''
    [[ $sealing == no ]] && rec linking todo "the server can't seal bank tokens (no BUDGET_TOKEN_KEY), so no bank can be linked" "" "./setup.sh server $KIND"
    if [[ $origin == none ]]; then rec plaid_keys skipped "no Plaid keys (only Plaid needs them: ./setup.sh banks plaid)"
    else
      rec plaid_keys "done" "Plaid keys are set ($([[ $origin == dashboard ]] && echo "on the dashboard" || echo "in budget.env"), ${env:-sandbox})"
      local bills; bills=$(dash_setting "$dash" key cardBills)
      [[ ${bills%%$'\t'*} == true ]] || rec card_bills person "card bills are off" "" "dashboard → Settings → Sync → Card bills (Plaid Liabilities)"
    fi
    local banks; banks=$(bank_counts "$dash")
    if [[ -n $banks && $banks != "Banks: 0 "* ]]; then rec banks "done" "$banks"
    else rec banks person "no bank linked yet" "$dash_url/#/accounts?connect=1" "./setup.sh banks"; fi
  fi
  if [[ -n $DASH_UP ]]; then  # the optional ones: skipped when unset, so they never fail check
    local chat; chat=$(dash_chat_model "$dash")
    if [[ -n $chat && $chat != off ]]; then rec model_configured "done" "Ask has a model"
    elif [[ -n $chat ]]; then rec model_configured skipped "no model for Ask (optional: dashboard → Settings → Models)"; fi
    if [[ $(xc_get BUDGET_FREE_TEAM) == YES ]]; then rec apns_key skipped "no morning summary: a free Personal Team can't get push"
    elif [[ $(dash_isset "$dash" APNS_KEY) == yes && $(dash_isset "$dash" APNS_KEY_ID) == yes ]]; then rec apns_key "done" "the APNs key and key ID are set (morning summary, pace alerts)"
    else rec apns_key skipped "no APNs key (optional, for the morning summary: dashboard → Settings → Notifications)"; fi
  fi
  local key; key=$(env_get BUDGET_TOKEN_KEY)
  if [[ -n $key ]]; then
    if [[ -f $KEY_MARKER ]] && grep -qx "fingerprint=$(printf '%s' "$key" | fingerprint)" "$KEY_MARKER"; then
      rec save_key "done" "BUDGET_TOKEN_KEY has a copy ($(sed -n 's/^method=//p' "$KEY_MARKER"), $(sed -n 's/^saved=//p' "$KEY_MARKER"))"
    else
      local why="BUDGET_TOKEN_KEY is only in budget.env: lose it and every bank must be linked again"
      [[ -f $KEY_MARKER ]] && why="BUDGET_TOKEN_KEY changed since its copy was saved"
      if [[ $OS == Darwin ]]; then rec save_key todo "$why" "" "./setup.sh save-key"
      else rec save_key person "$why" "" "copy it from $ENV_FILE into a password manager, then ./setup.sh save-key --done"; fi
    fi
  fi
}

cmd_check() {
  local json=''
  case ${1:-} in '') ;; --json) json=1 ;; *) usage ;; esac
  R_ID=() R_STATE=() R_LINE=() R_URL=() R_NEXT=()
  if [[ -n $json ]]; then
    set +e   # a step that trips over something still leaves valid JSON for the rest
    check_steps >/dev/null 2>&1
    set -e
    check_json
  else
    check_steps
    echo
    if check_failed; then printf '%sSomething above needs fixing.%s\n' "$R" "$N"; else printf '%sNothing is broken.%s\n' "$G" "$N"; fi
    printf '%sNext:%s %s\n' "$B" "$N" "$(check_next)"
  fi
  ! check_failed
}

# MARK: - tools

cmd_tools() {
  step "Tools"
  [[ -n $KIND ]] || { local found; found=${BUDGET_SERVER:-$(installed_kind)}; [[ -n $found ]] && use_kind "$found"; }
  if [[ $OS != Darwin ]]; then
    [[ $KIND == olares ]] && { ok "nothing to install here for an Olares deploy (ssh and rsync)"; return 0; }
    [[ $KIND == none ]] && { ok "nothing to install here: the app is built on a Mac"; return 0; }
    docker_ready || person_stop "Install Docker Engine with the Compose plugin (https://docs.docker.com/engine/install/), then run this again.
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
    person_stop "Install Xcode 26 or later from the App Store (https://apps.apple.com/app/xcode/id497799835), open it once, then run:
  sudo xcode-select -s /Applications/Xcode.app
and run this again."
  fi
  ok "$(xcodebuild -version | head -1)"
  xcodebuild -license check >/dev/null 2>&1 || person_stop "Accept Xcode's license first: sudo xcodebuild -license accept"

  if ! command -v brew >/dev/null; then
    [[ -t 0 ]] || person_stop "Homebrew isn't installed, and its installer needs your password."
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
    docker_ready && ok "Docker" || person_stop "Install Docker Desktop (https://www.docker.com/products/docker-desktop/) or OrbStack (https://orbstack.dev), start it, then run this again."
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
    none)   ok "no server here (BUDGET_SERVER=none): nothing to do" ;;
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
  docker_ready || person_stop "Docker with Compose v2 isn't installed: https://docs.docker.com/engine/install/ on Linux, Docker Desktop or OrbStack on a Mac."
  docker info >/dev/null 2>&1 || person_stop "Docker isn't running, or this user can't reach it (on Linux: sudo usermod -aG docker \$USER, then log in again)."

  step "Settings"
  if [[ -f $ENV_FILE ]]; then
    ok "keeping deploy/docker/budget.env"
  else
    local zone; zone=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||' || true)
    ( umask 077; cp "$DOCKER_DIR/budget.env.example" "$ENV_FILE" )
    chmod 600 "$ENV_FILE"
    # Each secret goes in through env_set (awk reads it from its environment), never in an argument list.
    local secret
    secret=$(openssl rand -hex 32); env_set BUDGET_API_TOKEN "$secret"
    secret=$(openssl rand -base64 32); env_set BUDGET_TOKEN_KEY "$secret"
    secret=$(openssl rand -hex 24); env_set POSTGRES_PASSWORD "$secret"
    secret=''
    env_set BUDGET_TIMEZONE "${zone:-America/New_York}"
    ok "wrote deploy/docker/budget.env (mode 600) with new secrets"
    warn "keep a copy of BUDGET_TOKEN_KEY: without it, every bank must be linked again (./setup.sh save-key)"
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
  step "Olares (owner only)"
  [[ -f $OLARES_DIR/deploy.env || -n ${OLARES_SSH:-} ]] || die "Say which Olares: put OLARES_SSH=user@host and APP_NS=budgetapi-<user> in deploy/olares/budgetapi/deploy.env (never committed).
The budgetapi app must already be installed there from your own Market repo; the chart isn't in this repo (docs/SERVER.md → Deploy)."
  # It replaces a live server: a blanket yes (BUDGET_YES=1) or a run without a terminal isn't enough on its own.
  if [[ ${BUDGET_YES:-} == 1 || ! -t 0 ]] && [[ ${BUDGET_DEPLOY:-} != 1 ]]; then
    die "Deploying replaces the server on the Olares. Without a terminal, or with BUDGET_YES=1, it also needs BUDGET_DEPLOY=1."
  fi
  if git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 && [[ -n $(git -C "$REPO" status --porcelain 2>/dev/null) ]]; then
    die "This checkout has uncommitted changes. Deploy from a clean one (a separate worktree of main), so what runs is what's committed."
  fi
  echo "  deploy.sh builds this checkout on the Olares, backs up the ledger (it stops if that fails), installs the"
  echo "  binary and restarts the app, which is down for about 15 s. Its settings stay in the Olares app."
  ask "Deploy this checkout to the Olares now?" n || { ok "left as it is"; return 0; }
  "$OLARES_DIR/deploy.sh"
}

# MARK: - address

cmd_address() {
  local how=${1:-${BUDGET_ADDRESS:-}} current
  step "The phone's HTTPS address"
  [[ -n $KIND ]] || pick_server
  if [[ $KIND == none ]]; then ok "no server here (BUDGET_SERVER=none): nothing to set up"; return 0; fi
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
    "tailscale|Tailscale Serve: private, only your own devices; the phone runs Tailscale too. No Plaid webhooks or phone reconnect$ts_note" \
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
  warn "Plaid can't reach a Tailscale address: no Plaid webhooks (the server pulls on its schedule) and no phone reconnect"
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
  if [[ ! -f $HOME/.cloudflared/cert.pem && ! -t 0 ]]; then
    person_stop "cloudflared has to sign in to Cloudflare in your browser once (cloudflared tunnel login), and that waits for you."
  fi
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

# Config/Local.xcconfig, edited in place so values set by hand stay: xc_set replaces KEY's line (set, or the example's
# commented one) or appends it, and xc_unset comments it out. Values go to awk through its environment.
xc_get() { [[ -f $XCCONFIG ]] || return 0; sed -n "s/^$1 *= *//p" "$XCCONFIG" | tail -1 | sed 's/[[:space:]]*$//'; }
xc_set() {  # xc_set KEY VALUE
  local tmp; tmp=$(mktemp "$XCCONFIG.XXXXXX") || return 1
  XC_KEY=$1 XC_VALUE=$2 awk '
    BEGIN { k = ENVIRON["XC_KEY"]; v = ENVIRON["XC_VALUE"] }
    !done && $0 ~ "^(// *)?" k " *=" { print k " = " v; done = 1; next }
    $0 ~ "^" k " *=" { next }
    { print }
    END { if (!done) print k " = " v }' "$XCCONFIG" > "$tmp" && mv "$tmp" "$XCCONFIG"
}
xc_unset() {  # xc_unset KEY
  [[ -n $(xc_get "$1") ]] || return 0
  local tmp; tmp=$(mktemp "$XCCONFIG.XXXXXX") || return 1
  XC_KEY=$1 awk 'BEGIN { k = ENVIRON["XC_KEY"] } $0 ~ "^" k " *=" { print "// " $0; next } { print }' "$XCCONFIG" > "$tmp" \
    && mv "$tmp" "$XCCONFIG"
}
free_team_of() {  # free_team_of TEAM — yes or no as Xcode has it, nothing when Xcode doesn't list the team
  case $(xcode_teams | awk -F'\t' -v t="$1" '$1 == t {print $3; exit}') in 1) echo yes ;; 0) echo no ;; esac
}
free_flag() {  # free_flag — yes or no from BUDGET_FREE_TEAM, nothing when it's unset
  case ${BUDGET_FREE_TEAM:-} in 1|yes|YES|true) echo yes ;; 0|no|NO|false) echo no ;; esac
}
# The host Apple checks for the Universal Link file, from the phone's address. Sets RC_HOST, or RC_WHY when the
# address can't carry phone reconnect.
reconnect_host() {  # reconnect_host URL
  local rest host
  RC_HOST='' RC_WHY=''
  [[ -n $1 ]] || { RC_WHY="the phone has no address yet (./setup.sh address)"; return 1; }
  [[ $1 == https://* ]] || { RC_WHY="the phone's address isn't https"; return 1; }
  rest=${1#https://}; rest=${rest%/}; host=${rest%%/*}; host=${host%:443}
  if [[ $rest != "${rest%%/*}" ]]; then RC_WHY="$1 has a path, and Apple looks for the Universal Link file at the host's root"
  elif [[ $host == *:* ]]; then RC_WHY="$1 has a port, and Apple looks for the Universal Link file on 443 only"
  elif [[ $host == *.ts.net ]]; then RC_WHY="a Tailscale address: Apple and Plaid can't reach it"
  elif [[ ! $host =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then RC_WHY="$host isn't a public hostname"
  fi
  [[ -z $RC_WHY ]] && RC_HOST=$host
  [[ -n $RC_HOST ]]
}
aasa_names() {  # aasa_names URL APPID — the Universal Link file answers 200 with JSON that names the app
  local out
  out=$(curl -fsS --max-time 8 "$1/.well-known/apple-app-site-association" 2>/dev/null) || return 1
  [[ ${out:0:1} == '{' && $out == *"\"$2\""* ]]
}
not_installed() {  # not_installed "why" — the app wasn't installed: say so plainly, and fail
  printf '\n%sNOT INSTALLED%s: %s\n' "$R" "$N" "$1" >&2
  return 1
}

cmd_app() {
  [[ $OS == Darwin ]] || die "NOT INSTALLED: the app is built on a Mac with Xcode. Run ./setup.sh app there."
  command -v xcodegen >/dev/null || die "NOT INSTALLED: xcodegen isn't installed. Run ./setup.sh tools"
  [[ -n $KIND ]] || { local found; found=${BUDGET_SERVER:-$(installed_kind)}; use_kind "${found:-none}"; }
  local server_env=''
  [[ ($KIND == mac || $KIND == docker) && -f $ENV_FILE ]] && server_env=1

  step "Signing"
  local team prefix before='' free
  team=$(xc_get DEVELOPMENT_TEAM); prefix=$(xc_get BUDGET_BUNDLE_PREFIX)
  [[ $team == ABCDE12345 ]] && team=''
  [[ $prefix == com.yourname || $prefix == com.example ]] && prefix=''
  # Values given in the environment win over the file's, so an agent's answers are the ones used.
  if [[ -n ${BUDGET_TEAM_ID:-} ]]; then team=$BUDGET_TEAM_ID; fi
  if [[ -n ${BUDGET_BUNDLE_PREFIX:-} ]]; then prefix=$BUDGET_BUNDLE_PREFIX; fi
  if [[ -z $team ]]; then
    local teams default_team=''
    teams=$(xcode_teams)
    if [[ -n $teams ]]; then
      echo "  Teams signed in to Xcode:"
      awk -F'\t' '{ printf "    %s  %s%s\n", $1, $2, ($3 == 1 ? " (free Personal Team)" : "") }' <<<"$teams"
      default_team=$(awk -F'\t' '$3 == 0 {print $1; exit}' <<<"$teams")
      [[ -n $default_team ]] || default_team=$(awk -F'\t' 'NR == 1 {print $1}' <<<"$teams")
    else
      echo "  No team is signed in to Xcode yet (Xcode → Settings → Accounts → + → Apple Account). A paid team's ID is on"
      echo "  https://developer.apple.com/account → Membership details; a free one shows in Xcode once you sign in."
    fi
    prompt BUDGET_TEAM_ID "Apple Developer team ID" "$default_team"; team=$BUDGET_TEAM_ID
  fi
  [[ $team =~ ^[A-Z0-9]{10}$ ]] || die "NOT INSTALLED: a team ID is 10 capital letters and digits ($team)."
  if [[ -z $prefix ]]; then prompt BUDGET_BUNDLE_PREFIX "Bundle ID prefix you own, such as com.yourname"; prefix=$BUDGET_BUNDLE_PREFIX; fi
  [[ $prefix =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ && $prefix != com.yourname && $prefix != com.example ]] \
    || die "NOT INSTALLED: use a reverse-DNS prefix of your own, such as com.yourname ($prefix)."

  # Free or paid: BUDGET_FREE_TEAM, else what Xcode says about the team, else what the file already says.
  free=$(free_flag)
  [[ -n $free ]] || free=$(free_team_of "$team")
  if [[ -z $free ]]; then
    if [[ $(xc_get BUDGET_FREE_TEAM) == YES ]]; then free=yes; warn "Xcode doesn't list team $team; keeping BUDGET_FREE_TEAM = YES"
    else free=no; warn "Xcode doesn't list team $team, so this treats it as paid. For a free Personal Team: BUDGET_FREE_TEAM=1 ./setup.sh app"; fi
  fi

  # Phone reconnect: a paid team, and a public https address on 443 that Apple can reach.
  effective_public_url
  local url=$PUB_URL host='' old_host
  old_host=$(xc_get BUDGET_API_HOST)
  if [[ $free == yes ]]; then :
  elif [[ ${BUDGET_RECONNECT:-} == no ]]; then :
  elif reconnect_host "$url"; then host=$RC_HOST
  elif [[ -n $old_host && -z $url ]]; then host=$old_host   # no address known here (an Olares, or none): keep the file's
  fi

  [[ -f $XCCONFIG ]] && before=$(mktemp) && cp "$XCCONFIG" "$before"
  [[ -f $XCCONFIG ]] || cp "$REPO/Config/Local.xcconfig.example" "$XCCONFIG" || die "NOT INSTALLED: couldn't write $XCCONFIG"
  xc_set DEVELOPMENT_TEAM "$team" && xc_set BUDGET_BUNDLE_PREFIX "$prefix" || die "NOT INSTALLED: couldn't write $XCCONFIG"
  if [[ $free == yes ]]; then xc_set BUDGET_FREE_TEAM YES; else xc_unset BUDGET_FREE_TEAM; fi
  # A free team keeps any BUDGET_API_HOST line as it is: BUDGET_FREE_TEAM = YES leaves it out of the build anyway.
  if [[ $free == no ]]; then
    if [[ -n $host ]]; then xc_set BUDGET_API_HOST "$host"; else xc_unset BUDGET_API_HOST; fi
  fi
  if [[ -n $before ]]; then
    if cmp -s "$before" "$XCCONFIG"; then rm -f "$before"; ok "Config/Local.xcconfig: team $team, app $prefix.budget"
    else mv "$before" "$XCCONFIG.bak"; ok "updated Config/Local.xcconfig: team $team, app $prefix.budget (the old one is Config/Local.xcconfig.bak)"; fi
  else ok "wrote Config/Local.xcconfig: team $team, app $prefix.budget"; fi

  if [[ $free == yes ]]; then
    warn "a free Personal Team: the app is built without push and Associated Domains (BUDGET_FREE_TEAM = YES)."
    echo "    No morning summary, no pace alerts, no phone reconnect (sign in to a bank again on the dashboard), and the"
    echo "    app stops opening after 7 days until ./setup.sh app installs it again. The paid program: https://developer.apple.com/programs/enroll/"
  elif [[ ${BUDGET_RECONNECT:-} == no ]]; then
    ok "phone reconnect: off (BUDGET_RECONNECT=no)"
  elif [[ -n $host ]]; then
    ok "phone reconnect: Associated Domains for $host (BUDGET_API_HOST)"
  else
    local why=${RC_WHY:-"the phone's address isn't known here"}
    warn "phone reconnect: off, since $why. Sign in to a bank again on the dashboard instead."
  fi

  # The server's half, before a build that claims the host: Apple fetches the Universal Link file when the app is
  # installed, so the server must already serve it. Paid teams also get push's team and topic filled in.
  if [[ $free == no && ( -n $server_env || -n $host ) ]]; then
    step "Server settings for the app"
    local app_id="$team.$prefix.budget" changed='' key want
    if [[ -n $server_env ]]; then
      local pairs=("APNS_TEAM_ID=$team" "APNS_TOPIC=$prefix.budget")
      [[ -n $host ]] && pairs+=("BUDGET_IOS_APP_ID=$app_id")
      local todo=()
      for key in "${pairs[@]}"; do
        want=${key#*=}; key=${key%%=*}
        if [[ $(env_get "$key") == "$want" ]]; then ok "$key=$want"; else todo+=("$key=$want"); fi
      done
      if (( ${#todo[@]} )) && ask "Set ${todo[*]} in budget.env and restart the server?"; then
        for key in "${todo[@]}"; do
          want=${key#*=}; key=${key%%=*}
          env_set "$key" "$want" || die "Couldn't write $ENV_FILE"; changed=1; ok "set $key=$want in budget.env"
        done
      elif (( ${#todo[@]} )); then warn "left budget.env as it is: push needs APNS_TEAM_ID and APNS_TOPIC to match the app"; fi
      local dash="http://127.0.0.1:$(dash_port)" line
      for key in APNS_TEAM_ID APNS_TOPIC; do
        line=$(dash_setting "$dash" environmentVariable "$key")
        want=$team; [[ $key == APNS_TOPIC ]] && want=$prefix.budget
        if [[ ${line##*$'\t'} == dashboard && ${line%%$'\t'*} != "$want" ]]; then
          warn "the dashboard has its own $key (${line%%$'\t'*}), and it wins over budget.env: Settings → Notifications"
        fi
      done
      if [[ -n $changed ]]; then
        restart_server
        if [[ -n $RESTARTED ]]; then
          wait_healthy "http://127.0.0.1:$(api_port)" 15 && ok "the server is back" || warn "the server isn't answering yet: ./setup.sh check"
        fi
      fi
    fi
    if [[ -n $host ]]; then
      local tries=1
      [[ -n $changed ]] && tries=6
      local i aasa='' probe=${url:-https://$host}
      for ((i = 1; i <= tries; i++)); do
        if aasa_names "$probe" "$app_id"; then aasa=1; break; fi
        if (( i < tries )); then sleep 3; fi
      done
      if [[ -n $aasa ]]; then ok "the Universal Link file answers at $probe for $app_id"
      else
        warn "the Universal Link file at $probe/.well-known/apple-app-site-association doesn't name $app_id yet,"
        echo "    so this build leaves Associated Domains out (phone reconnect stays off). Once it does (./setup.sh check),"
        echo "    run ./setup.sh app again."
        if [[ -z $server_env ]]; then
          echo "    The server isn't on this machine. On it, set BUDGET_IOS_APP_ID=$app_id, APNS_TEAM_ID=$team and"
          echo "    APNS_TOPIC=$prefix.budget$([[ $KIND == olares ]] && echo " (in the budgetapi app's settings on the Olares)"), then restart it."
        fi
        xc_unset BUDGET_API_HOST
        host=''
      fi
    fi
  fi

  step "Project"
  (cd "$REPO" && xcodegen generate --quiet) || die "NOT INSTALLED: xcodegen generate failed."
  ok "generated Budget.xcodeproj"

  step "iPhone"
  local phones_found udid name
  phones_found=$(phones)
  if [[ -n ${BUDGET_DEVICE:-} ]]; then phones_found=$(awk -F'\t' -v d="$BUDGET_DEVICE" '$1 == d || $2 == d' <<<"$phones_found"); fi
  if [[ -z $phones_found ]]; then
    echo "  Connect the iPhone with a cable, unlock it and tap Trust on \"Trust This Computer\". The first time, also turn on"
    echo "  Developer Mode: Settings → Privacy & Security → Developer Mode, tap Restart, then after the restart tap Turn On"
    echo "  (or Enable) and enter the passcode. Then run ./setup.sh app again."
    echo "  The simulator needs none of this: open Budget.xcodeproj and Run; it starts on the demo ledger."
    not_installed "no iPhone${BUDGET_DEVICE:+ named $BUDGET_DEVICE} is connected and paired with this Mac."
    return 1
  fi
  if (( $(wc -l <<<"$phones_found") > 1 )); then
    echo "  Connected:"; awk -F'\t' '{ printf "    %d) %s  %s\n", NR, $2, $1 }' <<<"$phones_found"
    [[ -t 0 || -n ${BUDGET_DEVICE_PICK:-} ]] || { not_installed "several iPhones are connected: set BUDGET_DEVICE to one's name or UDID, or BUDGET_DEVICE_PICK to its number above."; return 1; }
    local pick; prompt BUDGET_DEVICE_PICK "Which one" 1; pick=$BUDGET_DEVICE_PICK
    phones_found=$(sed -n "${pick}p" <<<"$phones_found")
    [[ -n $phones_found ]] || { not_installed "there's no phone $pick in that list."; return 1; }
  fi
  udid=$(cut -f1 <<<"$phones_found"); name=$(cut -f2 <<<"$phones_found")
  ask "Build Budget and install it on $name?" || { not_installed "you didn't say yes to building it (BUDGET_YES=1 does, without a terminal)."; return 1; }

  echo "  building (Release; the first build takes a few minutes)"
  local log="$DERIVED/build.log"
  mkdir -p "$DERIVED"
  if ! xcodebuild -project "$REPO/Budget.xcodeproj" -scheme Budget -configuration Release \
      -destination "platform=iOS,id=$udid" -derivedDataPath "$DERIVED" -allowProvisioningUpdates build > "$log" 2>&1; then
    grep -E 'error:|requires a provisioning profile|No Account|not registered|Personal development teams|maximum number' "$log" | sort -u | head -8 | sed 's/^/    /' >&2 || true
    die "NOT INSTALLED: the build failed (full log: $log). Signing errors usually mean Xcode → Settings → Accounts isn't signed in to team $team$([[ $free == no ]] && echo ", or it's a free Personal Team (BUDGET_FREE_TEAM=1 ./setup.sh app)"). docs/INSTALL-APP.md → Troubleshooting."
  fi
  ok "built"
  xcrun devicectl device install app --device "$udid" "$DERIVED/Build/Products/Release-iphoneos/Budget.app" >/dev/null 2>&1 \
    || die "NOT INSTALLED: installing on $name failed. Is it unlocked, with Developer Mode on (Settings → Privacy & Security → Developer Mode)?"
  ok "installed on $name"

  # Pairing: the app takes -server at launch, and the token as BUDGET_TOKEN in its launch environment, as if they were
  # typed in Settings (the token goes to its Keychain). devicectl hands DEVICECTL_CHILD_* variables to the app, so the
  # token stays out of every argument list. It's read from budget.env here and never printed. The "--" keeps devicectl
  # from reading the app's -server as one of its own options.
  local token='' args=() out msg paired=''
  [[ -n $server_env ]] && token=$(env_get BUDGET_API_TOKEN)
  [[ $url == https://* && -n $token ]] && args=(-- -server "$url")
  [[ ${#args[@]} -gt 0 ]] || token=''
  out=$(mktemp)
  if DEVICECTL_CHILD_BUDGET_TOKEN=$token xcrun devicectl device process launch --device "$udid" --terminate-existing "$prefix.budget" ${args[@]+"${args[@]}"} >"$out" 2>&1; then
    ok "launched Budget on $name"
    [[ ${#args[@]} -gt 0 ]] && paired=1
  else
    msg=$(cat "$out"); [[ -n $token ]] && msg=${msg//"$token"/<token>}
    if grep -qiE 'untrusted|not trusted|profile|denied' <<<"$msg"; then
      warn "installed, but the phone doesn't trust the developer yet: Settings → General → VPN & Device Management →"
      echo "    Developer App → your Apple Account → Trust (on newer iOS: Allow & Restart). Then run ./setup.sh app again to pair it."
    else
      warn "installed, but it didn't open (unlock the phone and run ./setup.sh app again):"
      grep -iE 'error|fail' <<<"$msg" | head -3 | sed 's/^/    /' || true
    fi
  fi
  rm -f "$out"
  token=''; args=()

  echo
  if [[ -n $paired ]]; then
    ok "PAIRED: Budget opened with $url and the API token from budget.env (not shown)"
    mkdir -p "$BUDGET_HOME"
    ( umask 077; printf 'paired=%s\nserver=%s\nfingerprint=%s\n' "$(date +%Y-%m-%d)" "$url" \
        "$(env_get BUDGET_API_TOKEN | tr -d '\n' | fingerprint)" > "$PHONE_MARKER" )
    local accounts; accounts=$(dash_get "http://127.0.0.1:$(dash_port)/dash/summary" | /usr/bin/python3 -I -c '
import json, sys
try: print(int(json.load(sys.stdin)["stats"]["accounts"]))
except Exception: pass' 2>/dev/null || true)
    [[ -n $accounts ]] && echo "  After its first sync, the phone shows $accounts account$([[ $accounts == 1 ]] || echo s) (the same as the dashboard)."
  else
    printf '  %sNOT PAIRED%s: ' "$Y" "$N"
    if [[ $url != https://* ]]; then echo "the server has no https address for the phone yet (./setup.sh address)."
    elif [[ -z $server_env ]]; then echo "the token is on the server, not here."
    else echo "Budget didn't open."; fi
    echo "  On the phone, enter the server's address ${url:+($url) }and the token: the dashboard → Settings → Connect your phone → Show."
  fi
  if [[ $free == yes ]]; then
    warn "a free Personal Team's install stops opening in 7 days: run ./setup.sh app again before then."
  elif [[ -n $server_env ]]; then
    echo "  The morning summary needs an APNs key: the dashboard → Settings → Notifications (team and bundle ID are filled in)."
  else
    echo "  The morning summary: on the server's dashboard, Settings → Notifications wants the APNs key, team $team and"
    echo "  bundle ID $prefix.budget."
  fi
  return 0
}

# MARK: - banks

here() {  # here KIND... — " (this install)" when this machine's server is one of them
  local k
  for k in "$@"; do [[ $KIND == "$k" ]] && { printf ' (this install)'; return 0; }; done
  return 0
}

cmd_banks() {  # cmd_banks [plaid|simplefin|later] — later: just the comparison
  local which=${1:-}
  case $which in ''|plaid|simplefin|later) ;; *) die "usage: ./setup.sh banks [plaid|simplefin]" ;; esac
  [[ -n $KIND ]] || { local found; found=${BUDGET_SERVER:-$(installed_kind)}; [[ -n $found ]] && use_kind "$found"; }
  effective_public_url
  BANK_API=${PUB_URL:-https://<the API address>}
  BANK_TS=''; [[ -n $PUB_URL && $(url_host "$PUB_URL") == *.ts.net ]] && BANK_TS=1
  BANK_PORT=$(dash_port); BANK_DASH="http://budget.localhost:$BANK_PORT"
  BANK_OLARES=${BUDGET_DASHBOARD_URL:-https://<the budgetapi dashboard entrance>}
  BANK_OLARES=${BANK_OLARES%/}
  BANK_RETURN=''  # the server's own answer (0.6.2+), which follows PLAID_MOBILE_REDIRECT_URI
  if [[ $KIND == mac || $KIND == docker ]]; then
    BANK_RETURN=$(dash_get "http://127.0.0.1:$BANK_PORT/dash/providers" | /usr/bin/python3 -I -c '
import json, sys
try: print(json.load(sys.stdin).get("phoneReturnURI") or "")
except (ValueError, AttributeError): pass' 2>/dev/null || true)
  fi
  step "Bank data${which:+: $which}"
  case $KIND in
    mac)    echo "  This install: the server on this Mac. Dashboard: $BANK_DASH. The phone's address: ${PUB_URL:-not set yet (./setup.sh address)}" ;;
    docker) echo "  This install: the server in Docker here. Dashboard: $BANK_DASH. The phone's address: ${PUB_URL:-not set yet (./setup.sh address)}" ;;
    olares) echo "  This install: an Olares (owner only). The phone's address: ${PUB_URL:-the API entrance (BUDGET_PUBLIC_URL=… to fill it in)}" ;;
    *)      echo "  No server on this machine: the steps cover each kind of server." ;;
  esac
  if [[ -n $BANK_TS ]]; then
    warn "That's a Tailscale address: Plaid can't reach it, so no webhooks (the server pulls on its schedule) and no phone reconnect."
  fi
  if [[ -z $which || $which == later ]]; then banks_compare; fi
  if [[ $which == later ]]; then echo "  The steps for either: ./setup.sh banks plaid, or ./setup.sh banks simplefin"; fi
  if [[ -z $which || $which == plaid ]]; then banks_plaid; fi
  if [[ -z $which || $which == simplefin ]]; then banks_simplefin; fi
}

banks_compare() {
  cat <<'EOF'

  Plaid or SimpleFIN (the dashboard shows the same comparison; you can add the other later):
                  Plaid                                         SimpleFIN
     Cost         your Plaid account; free Trial = 10 logins    $15/yr to SimpleFIN, up to 25 banks
     Setup        developer sign-up, keys, identity check       sign up, add banks there, paste a token
     Card bills   yes, once turned on (Settings → Sync)         no
     Merchants    names and bank categories                     raw bank descriptions
     History      up to 2 years at link                         ~90 days per request, walked back further
     Freshness    several times a day                           about once a day
     Investments  holdings by position, once turned on          balances only
                  (Settings → Sync; Plaid then bills Investments)
EOF
}

banks_plaid() {
  local reconnect=${BANK_RETURN:-$BANK_API/plaid/oauth-return} webhooks="nothing to do on a public address; ./setup.sh check tests it"
  if [[ -n $BANK_TS ]]; then
    reconnect="not with a Tailscale address (Plaid and Apple can't reach it)"
    webhooks="off with a Tailscale address; the server pulls on its schedule instead"
  elif [[ -n $PUB_URL && $PUB_URL != https://* ]]; then
    reconnect="needs an https address first (./setup.sh address)"
  fi
  cat <<EOF

${B}Plaid${N}: your own Plaid developer account and keys. Card bills, merchant names, up to 2 years of history.
  1. Sign up at https://dashboard.plaid.com and verify your email. Sandbox (made-up banks) works right away.
  2. For your real banks, pick a plan:
       Trial, free: https://dashboard.plaid.com/trial-plan (or the button on the Plaid Dashboard home). For teams made
         on or after April 15, 2026, in the US or Canada. 10 bank logins, ever: removing one doesn't give it back.
         It needs no company profile or security questionnaire until you upgrade.
       An older team: Limited Production, https://dashboard.plaid.com/overview/limited-production
         (no Chase, Bank of America or Wells Fargo until full Production).
       Pay as you go: https://dashboard.plaid.com/overview/request-products, then the company profile
         (https://dashboard.plaid.com/settings/company/compliance?tab=companyProfile), the app profile
         (https://dashboard.plaid.com/settings/company/app-branding) and the security questionnaire
         (https://dashboard.plaid.com/settings/company/compliance?tab=dataSecurity), which Chase needs.
     Real banks also need a Link use case: https://dashboard.plaid.com/link/data-transparency-v5 (Customize → Link).
  3. Copy the client ID and the secret for your environment (Sandbox or Production): https://dashboard.plaid.com/developers/keys
  4. Enter them on the dashboard: Accounts → Connect a bank → Plaid → Keys. Pick the environment, paste both, then Save and test.
     Moving to real banks later: switch Environment to Production there and paste the Production secret.
       Mac:     $BANK_DASH/#/accounts?connect=1 on that Mac$(here mac)
                (from another computer: ssh -L $BANK_PORT:127.0.0.1:$BANK_PORT <that mac>, then the same address)
       Docker:  the same address, on the Docker machine or through the same ssh tunnel$(here docker)
       Olares:  $BANK_OLARES/#/accounts?connect=1, signed in to Olares (owner only)$(here olares)
     On a Mac or Docker install they can go in budget.env instead, never shown: copy each value, then run
     ./setup.sh secret PLAID_CLIENT_ID, ./setup.sh secret PLAID_SECRET and ./setup.sh secret PLAID_ENV.
     Keys saved on the dashboard win over budget.env.
  5. Return addresses, under Allowed redirect URIs at https://dashboard.plaid.com/developers/api (Developers → API):
       Phone reconnect, any server:  $reconnect
       Dashboard on an Olares:       $BANK_OLARES/ (its own https address, with the slash)
       Dashboard on a Mac or Docker: none. Leave the return address on the Keys form empty: Chase and other banks
                                     that sign in on their own site open in a pop-up.
  6. Card bills are off until you turn them on: dashboard → Settings → Sync → Card bills (Plaid Liabilities).
     Plaid then bills Liabilities for each bank login. A bank linked before needs Grant card-bill access on its link.
  7. Phone reconnect uses Plaid's Hosted Link: nothing to request, Plaid's API includes it. It also needs a paid Apple
     Developer team and the return address in step 5; ./setup.sh app sets up the rest.
  8. Plaid's webhooks: $webhooks.
  9. Link a bank: Accounts → Connect a bank → Plaid → Link an account. Plaid's window opens; sign in to the bank there.
EOF
}

banks_simplefin() {
  cat <<EOF

${B}SimpleFIN${N}: \$15 a year (or \$1.50 a month) to SimpleFIN, up to 25 banks. About daily; no card bills.
  1. Check your banks are covered (US and Canada only): https://beta-bridge.simplefin.org/search-institutions
  2. Sign up: https://beta-bridge.simplefin.org/auth/login → your email → Send sign-in email, then open the link in
     it. The same form signs you in later. Accept the terms; you land on My Account.
  3. Subscribe there (\$1.50 a month or \$15 a year) before you add the first bank.
  4. Add each bank: Financial Institutions → New Connection, then sign in to the bank.
  5. Make a setup token: Apps → New Connection → name it Budget → Create Setup Token, and copy it.
     It works once. If linking fails after it was used, make a new one. (The Bridge may word these buttons a little differently.)
  6. Give it to the server:
       Mac or Docker$(here mac docker): with the token copied, run ./setup.sh bank simplefin. It reads the clipboard,
         links, clears the clipboard and prints only counts. Or paste it at $BANK_DASH/#/accounts?connect=1 → SimpleFIN → Link.
       Olares$(here olares): $BANK_OLARES/#/accounts?connect=1 → SimpleFIN → paste → Link.
     The phone can't add a SimpleFIN link. If SimpleFIN stops accepting one later, paste a new setup token on the
     dashboard (the link's Paste a new setup token).
  7. To stop it: turn off Budget's access on the Bridge, under Apps, then remove the link on the dashboard.
EOF
}

# MARK: - bank, secret, save-key: values that never show

simplefin_ids() {  # simplefin_ids DASHBOARD_URL — the ids of the SimpleFIN links, one per line (nothing else from them)
  curl -fsS --max-time 5 "$1/v1/links" 2>/dev/null | /usr/bin/python3 -I -c '
import json, sys
try: links = json.load(sys.stdin)
except ValueError: sys.exit()
for l in links if isinstance(links, list) else []:
    if isinstance(l, dict) and l.get("provider") == "simplefin" and l.get("id"): print(l["id"])' 2>/dev/null || true
}

cmd_bank() {  # cmd_bank simplefin [--stdin]
  local from=clipboard token dash resp code
  [[ ${1:-} == simplefin ]] || die "usage: ./setup.sh bank simplefin [--stdin]   (Plaid links in its own window on the dashboard: ./setup.sh banks plaid)"
  case ${2:-} in '') ;; --stdin) from=stdin ;; *) usage ;; esac
  server_here "linking SimpleFIN" "paste the setup token on the dashboard: Accounts → Connect a bank → SimpleFIN"
  dash="http://127.0.0.1:$(dash_port)"
  step "SimpleFIN"
  local p; p=$(dash_providers "$dash")
  [[ -n $p ]] || die "The dashboard isn't answering on $dash, so nothing was sent: ./setup.sh check"
  [[ ${p##*$'\t'} == yes ]] || die "The server can't seal bank tokens yet (no BUDGET_TOKEN_KEY), and the setup token works only once. Nothing was sent: ./setup.sh check"
  if [[ $from == clipboard ]]; then
    clip_ok || die "There's no clipboard here: pipe the token in with --stdin."
    token=$(clip_paste 2>/dev/null || true)
    clip_clear   # right away, so a token that's refused below doesn't stay on the clipboard either
  else
    token=$(cat)
  fi
  token=$(printf '%s' "$token" | tr -d ' \t\r\n')
  [[ -n $token ]] || die "Nothing came from the $([[ $from == clipboard ]] && echo clipboard || echo input). Copy the setup token on SimpleFIN Bridge (Apps → New Connection → Create Setup Token), then run this again."
  if [[ ! $token =~ ^[A-Za-z0-9+/=_-]+$ ]] || (( ${#token} < 16 || ${#token} > 4096 )); then
    die "That doesn't look like a SimpleFIN setup token, so nothing was sent$([[ $from == clipboard ]] && echo " (the clipboard was cleared)"). Copy the token again and rerun."
  fi
  [[ $from == clipboard ]] && ok "read the token and cleared the clipboard"
  # The SimpleFIN links there before, so a link that lands after the answer times out still counts (the server stores
  # it before the first sync, which walks history back and can take a while).
  local before_ids; before_ids=$(simplefin_ids "$dash")
  resp=$(mktemp)
  # The token goes in on stdin (printf is a builtin), never in an argument other users can list.
  code=$(printf '{"setupToken":"%s"}' "$token" | curl -sS --max-time 300 -o "$resp" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' -H 'X-Budget-Dashboard: 1' -H "Origin: $dash" --data-binary @- \
    "$dash/v1/links/simplefin" 2>/dev/null || true)
  token=''
  local result='' new_id=''
  if [[ $code == 2* ]]; then
    result=$(/usr/bin/python3 -I -c '
import json, sys
r = json.load(open(sys.argv[1]))
print("%s\t%s\t%s" % (r.get("linkID") or "-", "yes" if r.get("ok") else "no", (r.get("error") or "-").replace("\t", " ")))' "$resp" 2>/dev/null || true)
  else
    new_id=$(comm -13 <(sort <<<"$before_ids") <(simplefin_ids "$dash" | sort) | head -1)
    if [[ -n $new_id ]]; then
      result="$new_id	no	no clear answer came back (${code:-none}); the first sync may still be running"
    else
      local why; why=$(/usr/bin/python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("error",""))' "$resp" 2>/dev/null || true)
      rm -f "$resp"
      if [[ ${code:-000} == 000 ]]; then
        die "No answer from the dashboard in time, and no new SimpleFIN link shows yet. The server may still be working on it:
run ./setup.sh check in a few minutes before you make a new setup token (a second one would add a second link)."
      fi
      die "SimpleFIN wasn't linked ($code): ${why:-the dashboard gave no reason}. A setup token works once: if SimpleFIN took it, make a new one."
    fi
  fi
  rm -f "$resp"
  local link_id ok_sync error
  IFS=$'\t' read -r link_id ok_sync error <<<"$result"
  [[ $error == - ]] && error=''
  local counted; counted=$(curl -fsS --max-time 5 "$dash/v1/links" 2>/dev/null | /usr/bin/python3 -I -c '
import json, sys
for l in json.load(sys.stdin):
    if isinstance(l, dict) and l.get("id") == sys.argv[1]:
        banks = l.get("banks") or []
        print("%d bank%s, %d account%s" % (len(banks), "" if len(banks) == 1 else "s",
              sum(len(b.get("accountIDs") or []) for b in banks), "" if sum(len(b.get("accountIDs") or []) for b in banks) == 1 else "s"))' "$link_id" 2>/dev/null || true)
  ok "Linked: ${counted:-SimpleFIN Bridge}"
  [[ $ok_sync == yes ]] || warn "the first sync didn't finish: ${error:-no reason given}. The server tries again on its schedule."
  local banks; banks=$(bank_counts "$dash")
  [[ -n $banks ]] && ok "$banks"
  return 0
}

clean_secret() {  # clean_secret NAME VALUE — the value as budget.env should hold it, or a reason on stderr (never the value)
  local name=$1 value=$2
  if [[ $name == APNS_KEY ]]; then
    value=${value//-----BEGIN PRIVATE KEY-----/}; value=${value//-----END PRIVATE KEY-----/}
    value=$(printf '%s' "$value" | tr -d ' \t\r\n')
  else
    value=$(trim "$value")
  fi
  local bad=''
  if [[ -z $value ]]; then bad="it's empty"
  elif [[ ! $value =~ ^[A-Za-z0-9._~+/=:@-]+$ ]]; then bad="it has spaces, quotes or other characters budget.env can't hold safely"
  elif (( ${#value} > 8192 )); then bad="it's too long"
  else
    case $name in
      PLAID_ENV) [[ $value == sandbox || $value == production ]] || bad="it's sandbox or production" ;;
      PLAID_CLIENT_ID) [[ $value =~ ^[0-9a-f]{24}$ ]] || bad="a Plaid client ID is 24 characters, 0-9 and a-f" ;;
      APNS_KEY_ID|APNS_TEAM_ID) [[ $value =~ ^[A-Z0-9]{10}$ ]] || bad="it's 10 capital letters and digits" ;;
      APNS_TOPIC) [[ $value =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || bad="it's the app's bundle ID, such as com.yourname.budget" ;;
      APNS_KEY) [[ $value =~ ^[A-Za-z0-9+/=]+$ ]] || bad="it isn't the text of a .p8 file" ;;
      PLAID_MOBILE_REDIRECT_URI) [[ $value == off || $value == https://* ]] || bad="it starts with https:// (or is off)" ;;
      # A model can run on this machine, the Docker host or the LAN, so plain http is fine there.
      MODEL_BASE_URL|DECISION_BASE_URL) [[ $value == https://* || $value == http://* ]] || bad="it starts with https:// or http://" ;;
      *_URL|*_URI) [[ $value == https://* ]] || bad="it starts with https://" ;;
    esac
  fi
  if [[ -n $bad ]]; then echo "$bad" >&2; return 1; fi
  printf '%s' "$value"
}

cmd_secret() {  # cmd_secret NAME [--stdin]
  local name=${1:-} from='' value why
  [[ -n $name ]] || die "usage: ./setup.sh secret NAME [--stdin]   NAME: ${SECRET_NAMES// /, }"
  case $name in
    BUDGET_API_TOKEN|BUDGET_TOKEN_KEY) die "$name is made by ./setup.sh server and stays as it is. A new BUDGET_TOKEN_KEY would unlink every bank." ;;
  esac
  [[ " $SECRET_NAMES " == *" $name "* ]] || die "This sets only: ${SECRET_NAMES// /, }."
  case ${2:-} in '') ;; --stdin) from=stdin ;; *) usage ;; esac
  server_here "setting $name" "set it in the budgetapi app's settings there"
  if [[ -z $from ]]; then
    if [[ -t 0 ]]; then from="tty"
    elif clip_ok; then from=clipboard
    else die "No terminal to type it on, and no clipboard here: pipe it in with --stdin."; fi
  fi
  step "$name"
  case $from in
    tty)       value=$(read_hidden "$name" "$([[ $name == APNS_KEY ]] && echo pem)") ;;
    clipboard) echo "  reading it from the clipboard (copy it there first)"; value=$(clip_paste 2>/dev/null || true)
               clip_clear ;;   # right away, so a value that's refused below doesn't stay on the clipboard either
    stdin)     value=$(cat) ;;
  esac
  if ! value=$(clean_secret "$name" "$value" 2>"${TMPDIR:-/tmp}/budget-secret.$$"); then
    why=$(cat "${TMPDIR:-/tmp}/budget-secret.$$"); rm -f "${TMPDIR:-/tmp}/budget-secret.$$"
    die "Didn't set $name: $why. Nothing changed.$([[ $from == clipboard ]] && echo " (The clipboard was cleared.)")"
  fi
  rm -f "${TMPDIR:-/tmp}/budget-secret.$$"
  env_set "$name" "$value"
  value=''
  ok "set $name in budget.env (mode $(mode_of "$ENV_FILE"))"
  [[ $from == clipboard ]] && ok "cleared the clipboard"
  case $name in
    PLAID_CLIENT_ID) [[ -n $(env_get PLAID_SECRET) ]] || warn "the server uses Plaid keys from budget.env once PLAID_SECRET is set too" ;;
    PLAID_SECRET)    [[ -n $(env_get PLAID_CLIENT_ID) ]] || warn "the server uses Plaid keys from budget.env once PLAID_CLIENT_ID is set too" ;;
  esac
  local dash="http://127.0.0.1:$(dash_port)" origin=''
  if [[ $name == PLAID_* ]]; then local p; p=$(dash_providers "$dash"); origin=${p%%$'\t'*}
  else local s; s=$(dash_setting "$dash" environmentVariable "$name"); origin=${s##*$'\t'}; fi
  if [[ $origin == dashboard ]]; then
    warn "the dashboard has its own saved value for this, and it wins over budget.env: clear it there to use this one"
  fi
  restart_server
  [[ -n $RESTARTED ]] || return 0
  if wait_healthy "http://127.0.0.1:$(api_port)" 15; then ok "the server is back"
  else warn "the server isn't answering yet: ./setup.sh check (a value it can't read stops it; the log says which)"; fi
}

cmd_save_key() {  # cmd_save_key [--clipboard|--done]
  local how=keychain key kc=${BUDGET_KEYCHAIN:-}
  case ${1:-} in '') ;; --clipboard) how=clipboard ;; --done) how="done" ;; *) usage ;; esac
  server_here "saving BUDGET_TOKEN_KEY" "it's in the budgetapi app's settings there"
  key=$(env_get BUDGET_TOKEN_KEY)
  [[ -n $key ]] || die "budget.env has no BUDGET_TOKEN_KEY: ./setup.sh server $KIND"
  step "BUDGET_TOKEN_KEY"
  case $how in
    keychain)
      command -v security >/dev/null || die "There's no Keychain here. Use --clipboard, or copy BUDGET_TOKEN_KEY from $ENV_FILE into a password manager and run ./setup.sh save-key --done."
      # security falls back to the login Keychain for a keychain file that isn't there, so a missing one stops here.
      [[ -z $kc || -f $kc ]] || die "BUDGET_KEYCHAIN names a keychain file that doesn't exist ($kc), so nothing was saved."
      # security reads the command on stdin (-i), so the key never appears in an argument list.
      printf 'add-generic-password -U -a "BUDGET_TOKEN_KEY" -s "%s" -l "%s" -w "%s"%s\n' \
        "$KEYCHAIN_SERVICE" "$KEYCHAIN_SERVICE" "$key" "${kc:+ \"$kc\"}" | security -i >/dev/null 2>&1 || true
      # An older item can still be there when the add fails (a locked Keychain, or no way to ask over SSH), so compare
      # what's stored with the key, by fingerprint, without printing either.
      local stored
      stored=$(security find-generic-password -a BUDGET_TOKEN_KEY -s "$KEYCHAIN_SERVICE" -w ${kc:+"$kc"} 2>/dev/null | tr -d '\n' | fingerprint || true)
      if [[ $stored != "$(printf '%s' "$key" | fingerprint)" ]]; then
        security find-generic-password -a BUDGET_TOKEN_KEY -s "$KEYCHAIN_SERVICE" ${kc:+"$kc"} >/dev/null 2>&1 \
          && die "The Keychain still holds a different \"$KEYCHAIN_SERVICE\" (an older key), and it didn't take the new one (it may be locked). Unlock it and try again, or use ./setup.sh save-key --clipboard."
        die "The Keychain didn't take it (it may be locked). Try again, or use ./setup.sh save-key --clipboard."
      fi
      if [[ -n $kc ]]; then ok "saved in the keychain $kc as \"$KEYCHAIN_SERVICE\""
      else ok "saved in your login Keychain as \"$KEYCHAIN_SERVICE\" (Keychain Access, search Budget)"; fi
      ;;
    clipboard)
      printf '%s' "$key" | clip_copy || die "Couldn't put it on the clipboard."
      ok "BUDGET_TOKEN_KEY is on the clipboard. Paste it into your password manager now, then copy something else over it."
      ;;
    done) ok "noted: you saved a copy yourself" ;;
  esac
  mkdir -p "$BUDGET_HOME"
  ( umask 077; printf 'method=%s\nsaved=%s\nfingerprint=%s\n' "$how" "$(date +%Y-%m-%d)" "$(printf '%s' "$key" | fingerprint)" > "$KEY_MARKER" )
  key=''
  echo "  Keep it with the backups: bank tokens in them are sealed with it."
}

# MARK: - main

# Every answer the run will need, checked before anything changes, so a run without a terminal lists all the missing
# and wrong ones at once instead of stopping at the first.
preflight() {  # preflight COMMAND [ARG]
  local cmd=$1 arg=${2:-} problems=() kind env_file='' re_host='^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$'
  case ${BUDGET_SERVER:-} in ''|mac|docker|olares|none) ;; *) problems+=("BUDGET_SERVER is mac, docker, olares or none, not \"$BUDGET_SERVER\"") ;; esac
  case ${BUDGET_ADDRESS:-} in ''|tailscale|caddy|cloudflare|url) ;; *) problems+=("BUDGET_ADDRESS is tailscale, caddy, cloudflare or url, not \"$BUDGET_ADDRESS\"") ;; esac
  case ${BUDGET_BANKS:-} in ''|plaid|simplefin|later) ;; *) problems+=("BUDGET_BANKS is plaid, simplefin or later, not \"$BUDGET_BANKS\"") ;; esac
  if [[ -n ${BUDGET_DOMAIN:-} ]]; then
    local d=${BUDGET_DOMAIN#https://}; d=${d%%/*}
    [[ $d =~ $re_host ]] || problems+=("BUDGET_DOMAIN is a hostname, such as budget.example.com")
  fi
  [[ -z ${BUDGET_TEAM_ID:-} || $BUDGET_TEAM_ID =~ ^[A-Z0-9]{10}$ ]] || problems+=("BUDGET_TEAM_ID is 10 capital letters and digits")
  if [[ -n ${BUDGET_BUNDLE_PREFIX:-} ]] && { [[ ! $BUDGET_BUNDLE_PREFIX =~ $re_host ]] || [[ $BUDGET_BUNDLE_PREFIX == com.yourname || $BUDGET_BUNDLE_PREFIX == com.example ]]; }; then
    problems+=("BUDGET_BUNDLE_PREFIX is a reverse-DNS prefix of your own, such as com.yourname")
  fi
  [[ -z ${BUDGET_DEVICE_PICK:-} || $BUDGET_DEVICE_PICK =~ ^[1-9][0-9]*$ ]] || problems+=("BUDGET_DEVICE_PICK is a phone's number in the list")
  [[ -z ${BUDGET_FREE_TEAM:-} || -n $(free_flag) ]] || problems+=("BUDGET_FREE_TEAM is 1 (a free Personal Team) or 0 (a paid team)")
  case ${BUDGET_RECONNECT:-} in ''|yes|no) ;; *) problems+=("BUDGET_RECONNECT is yes or no, not \"$BUDGET_RECONNECT\"") ;; esac
  if [[ ($cmd == all || $cmd == address) && -n ${BUDGET_PUBLIC_URL:-} && $BUDGET_PUBLIC_URL != https://* ]]; then
    problems+=("BUDGET_PUBLIC_URL starts with https://")
  fi

  kind=${BUDGET_SERVER:-$(installed_kind)}
  [[ $cmd == server && -n $arg ]] && kind=$arg
  [[ $cmd == all && -z $kind ]] && kind=$([[ $OS == Darwin ]] && echo mac || echo docker)
  case $kind in mac) env_file="$BUDGET_HOME/budget.env" ;; docker) env_file="$DOCKER_DIR/budget.env" ;; esac
  if [[ ($cmd == server || $cmd == all) && $kind == olares && ${BUDGET_YES:-} == 1 && ${BUDGET_DEPLOY:-} != 1 ]]; then
    problems+=("BUDGET_DEPLOY=1 as well as BUDGET_YES=1: deploying to the Olares replaces the live server")
  fi

  if [[ ! -t 0 ]]; then
    local want_address='' want_app=''
    [[ $cmd == address ]] && want_address=1
    [[ $cmd == app ]] && want_app=1
    if [[ $cmd == all && ${BUDGET_YES:-} == 1 ]]; then want_address=1; [[ $OS == Darwin ]] && want_app=1; fi
    [[ $kind == olares || $kind == none ]] && want_address=''
    if [[ ($cmd == server || $cmd == all) && $kind == olares && ${BUDGET_YES:-} != 1 ]]; then
      problems+=("BUDGET_YES=1 and BUDGET_DEPLOY=1: deploying to the Olares asks first")
    fi
    if [[ -n $want_address ]]; then
      local how=${BUDGET_ADDRESS:-} current=''
      [[ $cmd == address && -n $arg ]] && how=$arg
      [[ -n $env_file && -f $env_file ]] && current=$(sed -n 's/^BUDGET_PUBLIC_URL=//p' "$env_file" | tail -1)
      if [[ -z $how ]]; then
        if [[ -n ${BUDGET_PUBLIC_URL:-} ]]; then how=url
        elif [[ -z $current || ${BUDGET_YES:-} != 1 ]]; then problems+=("BUDGET_ADDRESS: how the phone reaches the server (tailscale, caddy, cloudflare or url)"); fi
      fi
      case $how in
        caddy|cloudflare)
          [[ -n ${BUDGET_DOMAIN:-} ]] || problems+=("BUDGET_DOMAIN: the API's hostname for $how, such as budget.example.com")
          [[ ${BUDGET_YES:-} == 1 ]] || problems+=("BUDGET_YES=1: $how asks before it changes anything") ;;
        url) [[ -n ${BUDGET_PUBLIC_URL:-} ]] || problems+=("BUDGET_PUBLIC_URL: the https address you already have") ;;
      esac
    fi
    if [[ -n $want_app ]]; then
      [[ ${BUDGET_YES:-} == 1 ]] || problems+=("BUDGET_YES=1: app asks before it changes the server's settings, builds and installs")
      local cfg="$REPO/Config/Local.xcconfig" team='' prefix=''
      if [[ -f $cfg ]]; then
        team=$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' "$cfg"); prefix=$(sed -n 's/^BUDGET_BUNDLE_PREFIX *= *//p' "$cfg")
      fi
      if [[ -z $team || $team == ABCDE12345 || -z $prefix || $prefix == com.yourname || $prefix == com.example ]]; then
        local listed; listed=$(xcode_teams | awk -F'\t' '{ printf "%s%s%s", (NR > 1 ? ", " : ""), $1, ($3 == 1 ? " (free)" : "") }')
        [[ -n ${BUDGET_TEAM_ID:-} ]] || problems+=("BUDGET_TEAM_ID: the Apple Developer team ID${listed:+ (Xcode has $listed)}")
        [[ -n ${BUDGET_BUNDLE_PREFIX:-} ]] || problems+=("BUDGET_BUNDLE_PREFIX: a reverse-DNS prefix you own, such as com.yourname")
      fi
    fi
  fi

  if (( ${#problems[@]} )); then
    printf '%sSet these first%s:\n' "$R" "$N" >&2
    printf '  - %s\n' "${problems[@]}" >&2
    [[ -t 0 ]] || echo "  There's no terminal to ask on, so every answer comes from the environment (./setup.sh help lists them)." >&2
    exit 1
  fi
  PREFLIGHT_ENV=$env_file
  [[ $cmd == app || $cmd == address ]] && cross_check "$env_file"
  return 0
}

# Answers that rule each other out, said once before anything runs (the steps say it again where it matters).
cross_check() {  # cross_check BUDGET_ENV_FILE
  local notes=() pub=${BUDGET_PUBLIC_URL:-} ts='' free team
  [[ -z $pub && -n $1 && -f $1 ]] && pub=$(sed -n 's/^BUDGET_PUBLIC_URL=//p' "$1" | tail -1)
  [[ ${BUDGET_ADDRESS:-} == tailscale || ( -z ${BUDGET_ADDRESS:-} && $(url_host "$pub") == *.ts.net ) ]] && ts=1
  free=$(free_flag)
  if [[ -z $free && $OS == Darwin ]]; then
    team=${BUDGET_TEAM_ID:-$(xc_get DEVELOPMENT_TEAM)}
    [[ -n $team && $team != ABCDE12345 ]] && free=$(free_team_of "$team")
    [[ -z $free && $(xc_get BUDGET_FREE_TEAM) == YES ]] && free=yes
  fi
  [[ -n $ts ]] && notes+=("Tailscale: Plaid can't reach the server, so no Plaid webhooks (it pulls on its schedule instead) and no phone reconnect.")
  [[ $free == yes ]] && notes+=("A free Personal Team: no morning summary or pace alerts (push), no phone reconnect, and the app stops opening after 7 days until ./setup.sh app installs it again.")
  if [[ ${BUDGET_RECONNECT:-} == yes && ( -n $ts || $free == yes ) ]]; then
    notes+=("BUDGET_RECONNECT=yes can't work here: phone reconnect needs a paid Apple team and a public https address. Banks sign in again on the dashboard.")
  fi
  (( ${#notes[@]} )) || return 0
  step "Before you start"
  local n; for n in "${notes[@]}"; do warn "$n"; done
  return 0
}

all() {
  printf '%sBudget setup%s: the server, the phone'"'"'s address, then the app. Each step asks first.\n' "$B" "$N"
  cross_check "${PREFLIGHT_ENV:-}"
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
  local app_failed=''
  if [[ $OS == Darwin ]] && ask "Set up and build the iPhone app?"; then
    # In a subshell with errexit on, so a failure inside stops the app step (die included) but not the rest of the run:
    # check and the bank steps still print. "cmd_app || ..." would turn errexit off for everything inside it.
    # ("if ( ... )" would turn errexit off inside again, so the status is read after.)
    set +e
    ( set -e; cmd_app )
    # shellcheck disable=SC2181
    [[ $? == 0 ]] || app_failed=1
    set -e
  fi
  echo
  local kind=$KIND
  cmd_check || true
  if [[ $kind != mac && $kind != docker && $kind != olares ]]; then
    app_verdict "$app_failed"; return
  fi
  echo
  # Banks already linked: the choice is made, so don't ask it again on a re-run.
  local banks=''
  [[ $kind == olares ]] || banks=$(bank_counts "http://127.0.0.1:$(dash_port)")
  if [[ -n $banks && $banks != "Banks: 0 "* ]]; then
    printf '%sBanks%s: %s; add more at http://budget.localhost:%s → Accounts → Connect a bank\n' "$B" "$N" "$banks" "$(dash_port)"
  else
    choose BUDGET_BANKS "How will this server get bank data? Either works, and you can add the other later." later \
      "plaid|Plaid: your own developer account and keys; card bills, merchant names, 2 years of history; the free Trial is 10 bank logins, ever" \
      "simplefin|SimpleFIN: \$15 a year, one token, up to 25 banks; about daily, 90 days per request, no card bills" \
      "later|decide on the dashboard, which shows the two side by side"
    cmd_banks "$BUDGET_BANKS"
  fi
  cat <<EOF

${B}Then${N} (docs/INSTALL-SERVER.md walks through each):
  Optional: a model for Ask, under Settings → Models
  Optional: the morning summary, under Settings → Notifications
EOF
  if [[ $kind != olares ]]; then
    echo "  Keep a copy of BUDGET_TOKEN_KEY: ./setup.sh save-key (your Keychain) or --clipboard. Without it, every bank must be linked again."
  fi
  app_verdict "$app_failed"
}
app_verdict() {  # app_verdict FAILED — the bare run's last word when the app wasn't installed, and its exit status
  [[ -z $1 ]] && return 0
  printf '\n%sThe app is NOT INSTALLED%s (the reason is above): ./setup.sh app once that'"'"'s sorted.\n' "$R" "$N"
  return 1
}

case ${1:-} in
  -h|--help|help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
  ""|check|before|tools|server|address|app|banks|bank|secret|save-key) ;;
  *) usage ;;
esac
preflight "${1:-all}" "${2:-}"
case ${1:-} in
  "")       all ;;
  check)    shift; cmd_check "$@" ;;
  before)   cmd_before ;;
  tools)    cmd_tools ;;
  server)   cmd_server "${2:-}" ;;
  address)  cmd_address "${2:-}" ;;
  app)      cmd_app ;;
  banks)    cmd_banks "${2:-}" ;;
  bank)     shift; cmd_bank "$@" ;;
  secret)   shift; cmd_secret "$@" ;;
  save-key) shift; cmd_save_key "$@" ;;
esac
