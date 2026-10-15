#!/usr/bin/env bash
# Sets up Budget on this Mac from a fresh clone: the tools, the server, an HTTPS address for the phone, and the app.
# Every step checks first and skips what's already done, so it's safe to run again (and to update: git pull, then this).
#
#   ./setup.sh            everything, in order, asking before each step
#   ./setup.sh check      what's installed and answering; changes nothing
#   ./setup.sh tools      Homebrew tools: xcodegen, postgresql@16
#   ./setup.sh server     Postgres, then deploy/macos/install.sh (backup, build, launchd, /health)
#   ./setup.sh address    the phone's HTTPS address for the API, saved as BUDGET_PUBLIC_URL and checked
#   ./setup.sh app        Config/Local.xcconfig, xcodegen, and with an iPhone connected: build, install, launch
#
# Answers can come from the environment instead of prompts (for an agent):
#   BUDGET_TEAM_ID        Apple Developer team ID              BUDGET_BUNDLE_PREFIX  com.yourname (app = <prefix>.budget)
#   BUDGET_PUBLIC_URL     the phone's HTTPS address for the API
#   BUDGET_DEVICE         the iPhone's UDID or name            BUDGET_YES=1          yes to every question (needed
#                                                                                    without a terminal: there, no is the default)
#
# Secrets are never printed. The phone's token is on the dashboard: Settings → Connect your phone → Show.
# Guides: docs/SETUP.md (start here), docs/INSTALL-SERVER.md, docs/INSTALL-APP.md.
set -euo pipefail

REPO=$(cd "$(dirname "$0")" && pwd)
BUDGET_HOME=${BUDGET_HOME:-"$HOME/Library/Application Support/BudgetServer"}
ENV_FILE="$BUDGET_HOME/budget.env"
DOMAIN="gui/$(id -u)"
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/Budget-setup"
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

env_get() {  # env_get KEY — a value from budget.env, without sourcing it into this shell
  [[ -f $ENV_FILE ]] || return 0
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -1
}
env_set() {  # env_set KEY VALUE — replaces KEY's line (commented or not), or appends it
  local tmp
  tmp=$(mktemp "$BUDGET_HOME/.env.XXXXXX")
  awk -v k="$1" -v v="$2" '
    $0 ~ "^#? *" k "=" { if (!done) print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }' "$ENV_FILE" > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$ENV_FILE"
}
api_port()  { local p; p=$(env_get PORT); echo "${p:-8080}"; }
dash_port() { local p; p=$(env_get DASHBOARD_PORT); echo "${p:-8081}"; }
healthy()   { curl -fsS --max-time "${2:-3}" "$1/health" 2>/dev/null | grep -q '"ok"'; }
restart_server() {
  if launchctl print "$DOMAIN/local.budget.server" >/dev/null 2>&1; then
    launchctl kickstart -k "$DOMAIN/local.budget.server" >/dev/null && ok "restarted the server"
  else warn "the server isn't a launchd job here; restart it yourself so it picks up the change"; fi
}

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

cmd_check() {
  local fails=0
  step "This Mac"
  local major; major=$(sw_vers -productVersion | cut -d. -f1)
  if (( major >= 26 )); then ok "macOS $(sw_vers -productVersion)"; else bad "macOS $(sw_vers -productVersion): the server needs 26 or later"; fails=1; fi
  if xcode-select -p >/dev/null 2>&1 && xcodebuild -version >/dev/null 2>&1; then
    ok "$(xcodebuild -version | head -1), $(swift --version 2>&1 | grep -o 'Swift version [0-9.]*')"
  else bad "Xcode isn't installed (or xcode-select points at the Command Line Tools)"; fails=1; fi
  if command -v brew >/dev/null; then ok "Homebrew"; else bad "Homebrew isn't installed"; fails=1; fi
  for tool in xcodegen psql; do
    if command -v $tool >/dev/null; then ok "$tool"; else warn "$tool isn't installed (./setup.sh tools)"; fi
  done

  step "Server"
  if [[ -x $BUDGET_HOME/bin/budget-server && -f $ENV_FILE ]]; then
    ok "installed in $BUDGET_HOME"
    [[ $(stat -f %Lp "$ENV_FILE") == 600 ]] && ok "budget.env is private (600)" || { bad "budget.env isn't mode 600"; fails=1; }
    for key in BUDGET_API_TOKEN BUDGET_TOKEN_KEY; do
      [[ -n $(env_get $key) ]] && ok "$key is set" || { bad "$key is empty in budget.env"; fails=1; }
    done
    local host; host=$(env_get HOST)
    [[ ${host:-127.0.0.1} == 127.0.0.1 || $host == localhost ]] && ok "listens on loopback only" \
      || { bad "HOST=$host: the dashboard has no login, set HOST=127.0.0.1"; fails=1; }
    local pg; pg=$(env_get POSTGRES_HOST)
    if [[ -z $pg ]]; then warn "no POSTGRES_HOST: the ledger is in memory and lost on restart"
    elif pg_isready -q -h "$pg" -p "$(env_get POSTGRES_PORT | grep . || echo 5432)" 2>/dev/null; then ok "Postgres answers on $pg"
    else bad "Postgres isn't answering on $pg"; fails=1; fi
    launchctl print "$DOMAIN/local.budget.server" >/dev/null 2>&1 && ok "launchd job local.budget.server" || warn "the launchd job isn't loaded"
    if healthy "http://127.0.0.1:$(api_port)"; then ok "API answers on 127.0.0.1:$(api_port) ($(curl -fsS "http://127.0.0.1:$(api_port)/health" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p'))"
    else bad "API isn't answering on 127.0.0.1:$(api_port); see $BUDGET_HOME/logs/server.log"; fails=1; fi
    curl -fsS --max-time 3 -o /dev/null "http://127.0.0.1:$(dash_port)/" 2>/dev/null \
      && ok "dashboard: http://budget.localhost:$(dash_port)" || warn "the dashboard isn't answering on $(dash_port)"
    local latest; latest=$(ls -1t "$BUDGET_HOME"/backups/budget-*.dump 2>/dev/null | head -1 || true)
    if [[ -n $latest ]]; then ok "latest backup: $(basename "$latest")"; else warn "no backup yet (the first runs tonight at 3:30)"; fi
    local url; url=$(env_get BUDGET_PUBLIC_URL)
    if [[ -z $url ]]; then warn "no BUDGET_PUBLIC_URL: the phone has no address yet (./setup.sh address)"
    elif healthy "$url" 8; then ok "the phone's address answers: $url"
    else bad "$url doesn't answer /health"; fails=1; fi
    [[ $(pmset -g 2>/dev/null | awk '$1 == "sleep" {print $2}') == 0 ]] && ok "this Mac doesn't sleep" \
      || warn "this Mac can sleep, and the server sleeps with it (System Settings → Energy, or sudo pmset -a sleep 0)"
  else
    warn "not installed on this Mac (./setup.sh server)"
  fi

  step "App"
  local local_cfg="$REPO/Config/Local.xcconfig"
  if [[ -f $local_cfg ]] && ! grep -Eq '^(DEVELOPMENT_TEAM *= *ABCDE12345|BUDGET_BUNDLE_PREFIX *= *com\.(yourname|example)) *$' "$local_cfg"; then
    ok "Config/Local.xcconfig: app $(sed -n 's/^BUDGET_BUNDLE_PREFIX *= *//p' "$local_cfg").budget"
  else warn "no Config/Local.xcconfig with your team (./setup.sh app); the app builds for the simulator only"; fi
  [[ -d $REPO/Budget.xcodeproj ]] && ok "Budget.xcodeproj generated" || warn "Budget.xcodeproj not generated yet (xcodegen generate)"
  local found; found=$(phones)
  if [[ -n $found ]]; then ok "iPhone connected: $(cut -f2 <<<"$found" | paste -sd, - )"; else warn "no iPhone connected (USB, or the same Wi-Fi once paired)"; fi

  echo
  (( fails == 0 )) && printf '%sNothing is broken.%s\n' "$G" "$N" || printf '%sSomething above needs fixing.%s\n' "$R" "$N"
  return $fails
}

# MARK: - tools

cmd_tools() {
  step "Tools"
  [[ $(uname) == Darwin ]] || die "This script is for macOS. On Linux, see docs/SERVER.md."
  local major; major=$(sw_vers -productVersion | cut -d. -f1)
  (( major >= 26 )) || die "The server needs macOS 26 or later (this is $(sw_vers -productVersion))."
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
  local missing=()
  for formula in xcodegen postgresql@16; do
    brew list --formula "$formula" >/dev/null 2>&1 && ok "$formula" || missing+=("$formula")
  done
  if (( ${#missing[@]} )); then
    ask "brew install ${missing[*]}?" || die "Those are needed: brew install ${missing[*]}"
    brew install "${missing[@]}"
  fi
}

# MARK: - server

cmd_server() {
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

# MARK: - address

cmd_address() {
  [[ -f $ENV_FILE ]] || die "Install the server first: ./setup.sh server"
  step "The phone's HTTPS address"
  local url=${BUDGET_PUBLIC_URL:-} current
  current=$(env_get BUDGET_PUBLIC_URL)
  if [[ -z $url && -n $current ]] && healthy "$current" 8 && ask "$current answers. Keep it?"; then
    ok "keeping $current"; return 0
  fi
  if [[ -z $url ]]; then
    echo "  The phone reaches the API over HTTPS. Use an address you control that forwards to 127.0.0.1:$(api_port), and"
    echo "  nothing else: the dashboard ($(dash_port)) has no login. Ways to get one: docs/INSTALL-SERVER.md, step 5."
    prompt BUDGET_PUBLIC_URL "The address (https://…)"; url=$BUDGET_PUBLIC_URL
  fi

  url=${url%/}
  [[ $url == https://* ]] || die "The phone needs https:// ($url)."
  env_set BUDGET_PUBLIC_URL "$url"
  ok "saved BUDGET_PUBLIC_URL=$url"
  restart_server
  echo "  checking $url/health"
  for _ in $(seq 1 12); do healthy "$url" 5 && { ok "the phone's address answers"; return 0; }; sleep 5; done
  warn "$url doesn't answer yet. Check it later with ./setup.sh check"
}

# MARK: - app

cmd_app() {
  command -v xcodegen >/dev/null || die "xcodegen isn't installed: ./setup.sh tools"
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
  echo "  On the phone, enter the server ${url:+($url) }and the token from the dashboard:"
  echo "  http://budget.localhost:$(dash_port) → Settings → Connect your phone → Show."
  echo "  For the morning summary, the dashboard's Notifications wants the bundle ID $prefix.budget."
}

# MARK: - main

all() {
  printf '%sBudget setup%s: tools, server, the phone'"'"'s address, then the app. Each step asks first.\n' "$B" "$N"
  cmd_tools
  if ask "Install the server on this Mac (it should stay on)?"; then
    cmd_server
    ask "Give the phone an HTTPS address for the API now?" && cmd_address
  else
    warn "skipped the server. The app can point at a server elsewhere (or the demo ledger in the simulator)."
  fi
  ask "Set up and build the iPhone app?" && cmd_app
  echo
  cmd_check || true
  cat <<EOF

${B}Next, in a browser on this Mac${N} (docs/INSTALL-SERVER.md walks through each):
  1. Link banks: http://budget.localhost:$(dash_port) → Accounts → Connect a bank (SimpleFIN or Plaid)
  2. Optional: a model for Ask, under Settings → Models
  3. Optional: the morning summary, under Settings → Notifications
Save BUDGET_TOKEN_KEY from $ENV_FILE in a password manager: without it, every bank must be linked again.
EOF
}

case ${1:-} in
  "")      all ;;
  check)   cmd_check ;;
  tools)   cmd_tools ;;
  server)  cmd_server ;;
  address) cmd_address ;;
  app)     cmd_app ;;
  -h|--help|help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" ;;
  *) echo "usage: $0 [check | tools | server | address | app]" >&2; exit 2 ;;
esac
