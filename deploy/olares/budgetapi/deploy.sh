#!/usr/bin/env bash
# Builds the Budget API for Linux on the Olares and installs it into the budgetapi app.
#
#   deploy/olares/budgetapi/deploy.sh            build + install + restart
#   deploy/olares/budgetapi/deploy.sh --test     run the server tests (incl. Postgres) first; a failure stops the deploy
#   deploy/olares/budgetapi/deploy.sh --check    Linux check only: the same tests and release build, then stop —
#                                                nothing is installed and budgetapi isn't touched
#
# Everything runs on the box: a `swift:6.2-noble` build pod in the budget-build namespace compiles
# a static-stdlib release binary, and a short-lived installer pod writes it to
# <appData>/budgetapi/bin/budget-api (the app mounts that read-only). No registry involved.
# --check works in its own folders (~/budget-build/check-src on the host, /work/check in the pod), so it
# never replaces the sources or binary a deploy is using, and it exits non-zero if a test or the build fails.
#
# Before installing, a deploy takes a pg_dump of the ledger into ~/budget-backups on the host (checked readable with
# pg_restore --list) and keeps the running binary as bin/budget-api.prev. A new server can rewrite rows on its first
# start in a form an older one can't read, so rolling back is: restore that dump, put budget-api.prev back as
# budget-api, restart (docs/SERVER.md, "Roll back"). A failed backup stops the deploy.
#
# Where it deploys comes from the environment or from deploy.env beside this script (ignored by git):
#   OLARES_SSH=olares@<your box>     the host to ssh into, with kubectl on it
#   APP_NS=budgetapi-<your user>     the budgetapi app's namespace
set -euo pipefail

ENV_FILE="$(dirname "$0")/deploy.env"
[[ -f $ENV_FILE ]] && source "$ENV_FILE"
HOST=${OLARES_SSH:?set OLARES_SSH (user@host) in the environment or $ENV_FILE}
APP_NS=${APP_NS:?set APP_NS (the budgetapi namespace) in the environment or $ENV_FILE}
BUILD_NS=budget-build
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
RUN_TESTS=0
CHECK_ONLY=0
case ${1:-} in
  "") ;;
  --test) RUN_TESTS=1 ;;
  --check) RUN_TESTS=1; CHECK_ONLY=1 ;;
  *) echo "usage: $0 [--test | --check]" >&2; exit 2 ;;
esac
if [[ $CHECK_ONLY == 1 ]]; then SRC=budget-build/check-src WORK=/work/check; else SRC=budget-build/src WORK=/work; fi

echo "==> syncing sources"
ssh "$HOST" mkdir -p "$SRC"
rsync -az --delete --exclude .build --exclude .swiftpm "$REPO/Packages" "$REPO/Server" "$HOST:$SRC/"

ssh "$HOST" RUN_TESTS=$RUN_TESTS CHECK_ONLY=$CHECK_ONLY SRC=$SRC WORK=$WORK APP_NS=$APP_NS BUILD_NS=$BUILD_NS bash -s <<'REMOTE'
set -euo pipefail
k() { kubectl -n "$BUILD_NS" "$@"; }

kubectl get ns "$BUILD_NS" >/dev/null 2>&1 || kubectl create ns "$BUILD_NS"
if ! k get pod swift >/dev/null 2>&1; then
  echo "==> starting build pod"
  k run swift --image=swift:6.2-noble --restart=Never --command -- sleep infinity
fi
k wait --for=condition=Ready pod/swift --timeout=300s >/dev/null

echo "==> copying sources into the build pod"
tar czf ~/"$SRC".tgz -C ~/"$SRC" .
k exec swift -- sh -c "rm -rf $WORK/src && mkdir -p $WORK/src"
k cp ~/"$SRC".tgz swift:"$WORK"/src.tgz
k exec swift -- tar xzf "$WORK"/src.tgz -C "$WORK"/src

# The log keeps the whole output; the exit status is the command's, not tail's.
run_logged() { k exec swift -- sh -c "$1 > $WORK/$2.log 2>&1; status=\$?; tail -${3:-4} $WORK/$2.log; exit \$status"; }

if [[ $RUN_TESTS == 1 ]]; then
  echo "==> testing (scratch Postgres)"
  k get pod pg >/dev/null 2>&1 || k run pg --image=postgres:16-alpine --env=POSTGRES_PASSWORD=buildtest --port=5432
  k wait --for=condition=Ready pod/pg --timeout=180s >/dev/null
  PGIP=$(k get pod pg -o jsonpath='{.status.podIP}')
  run_logged "cd $WORK/src/Server && POSTGRES_TEST_HOST=$PGIP POSTGRES_TEST_PASSWORD=buildtest swift test" test
fi

echo "==> building release"
run_logged "cd $WORK/src/Server && swift build -c release --static-swift-stdlib --product BudgetServer" build 1
k exec swift -- strip -o "$WORK"/budget-api "$WORK"/src/Server/.build/release/BudgetServer

if [[ $CHECK_ONLY == 1 ]]; then
  echo "==> check passed: tests and a Linux release build ($(k exec swift -- du -h "$WORK"/budget-api | cut -f1)); nothing installed"
  exit 0
fi

# Stop budgetapi before the backup and before the binary changes, unless the strategy is Recreate. Under a RollingUpdate
# (Kubernetes' default) the old pod keeps serving and syncing while the new one starts, so two servers write the ledger at
# once. Server 0.6.0 rewrites statement ids on its first start, and each of the old pod's syncs would write the old ids
# back. Any later release that rewrites something at start has the same problem, so this runs on every deploy, not just
# 0.6.0: a few seconds of API downtime in exchange for one writer at a time. Stopping first also means the dump below
# (the rollback) holds everything; no sync lands between it and the new server's start.
STRATEGY=$(kubectl -n "$APP_NS" get deploy budgetapi -o jsonpath='{.spec.strategy.type}')
SCALED_DOWN=0
# budgetapi's own pods (budgetapi-<replicaset>-<id>), not budgetapidb's.
api_pods() { kubectl -n "$APP_NS" get pods -o name | grep -E '^pod/budgetapi-[a-z0-9]+-[a-z0-9]+$' || true; }
if [[ $STRATEGY != Recreate ]]; then
  REPLICAS=$(kubectl -n "$APP_NS" get deploy budgetapi -o jsonpath='{.spec.replicas}')
  REPLICAS=${REPLICAS:-1}; [[ $REPLICAS -ge 1 ]] || REPLICAS=1
  echo "==> stopping budgetapi before the backup and the new server (strategy ${STRATEGY:-RollingUpdate})"
  # However this script ends from here on, budgetapi is started again (with the old binary if the install failed).
  trap 'if [[ $SCALED_DOWN == 1 ]]; then kubectl -n "$APP_NS" scale deploy/budgetapi --replicas="$REPLICAS" >/dev/null; fi' EXIT
  SCALED_DOWN=1
  kubectl -n "$APP_NS" scale deploy/budgetapi --replicas=0 >/dev/null
  for _ in $(seq 1 60); do
    [[ -z $(api_pods) ]] && break
    sleep 2
  done
  if [[ -n $(api_pods) ]]; then
    echo "budgetapi's pod didn't stop within 2 minutes (if Olares scaled it back up, deploy with the strategy set to Recreate); nothing was installed" >&2
    exit 1
  fi
fi

echo "==> backing up the ledger"
if kubectl -n "$APP_NS" get deploy budgetapidb >/dev/null 2>&1; then
  mkdir -p ~/budget-backups
  DUMP=~/budget-backups/budget-$(date +%Y%m%d-%H%M%S).dump
  kubectl -n "$APP_NS" exec deploy/budgetapidb -- pg_dump -U budgetapi -d budgetapi --format=custom > "$DUMP"
  # Read it back from a file in the pod: piping it into `exec -i` never delivers EOF through this ssh session, and
  # anything here that reads stdin would also eat the rest of this script (it arrives on stdin via `bash -s`).
  DB_POD=$(kubectl -n "$APP_NS" get pods -o name | grep budgetapidb | head -1); DB_POD=${DB_POD#pod/}
  kubectl -n "$APP_NS" cp "$DUMP" "$DB_POD":/tmp/budget-check.dump </dev/null
  kubectl -n "$APP_NS" exec "$DB_POD" -- sh -c 'pg_restore --list /tmp/budget-check.dump > /dev/null; s=$?; rm -f /tmp/budget-check.dump; exit $s' </dev/null
  echo "    $DUMP ($(du -h "$DUMP" | cut -f1)); keep budgetapi-secret with it"
else
  echo "    no budgetapidb in $APP_NS (in-memory ledger): nothing to back up"
fi

# Olares' app-service manages this Deployment. If it put the replicas back while the backup ran, an old pod is writing
# again and the dump isn't the whole story: stop rather than install next to it.
if [[ $SCALED_DOWN == 1 && -n $(api_pods) ]]; then
  echo "budgetapi started again during the backup (Olares app-service?); nothing was installed" >&2
  exit 1
fi

echo "==> installing into $APP_NS"
BIN_DIR=$(kubectl -n "$APP_NS" get deploy budgetapi -o jsonpath='{.spec.template.spec.volumes[?(@.name=="appdata")].hostPath.path}')/bin
k delete pod budget-install --ignore-not-found --wait >/dev/null
cat <<EOF | k apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: budget-install}
spec:
  restartPolicy: Never
  containers:
    - {name: install, image: "swift:6.2-noble-slim", command: [sleep, "600"], volumeMounts: [{name: bin, mountPath: /bin-dir}]}
  volumes:
    - {name: bin, hostPath: {path: "$BIN_DIR", type: DirectoryOrCreate}}
EOF
k wait --for=condition=Ready pod/budget-install --timeout=120s >/dev/null
k cp swift:"$WORK"/budget-api /tmp/budget-api >/dev/null
k cp /tmp/budget-api budget-install:/bin-dir/budget-api.part
rm -f /tmp/budget-api
k exec budget-install -- sh -c 'chmod 0755 /bin-dir/budget-api.part && { [ ! -f /bin-dir/budget-api ] || cp -p /bin-dir/budget-api /bin-dir/budget-api.prev; } && mv /bin-dir/budget-api.part /bin-dir/budget-api && ls -la /bin-dir/budget-api*'
k delete pod budget-install --wait=false >/dev/null

echo "==> restarting"
if [[ $SCALED_DOWN == 1 ]]; then
  kubectl -n "$APP_NS" scale deploy/budgetapi --replicas="$REPLICAS" >/dev/null
  SCALED_DOWN=0
else
  kubectl -n "$APP_NS" rollout restart deploy/budgetapi >/dev/null
fi
kubectl -n "$APP_NS" rollout status deploy/budgetapi --timeout=300s
kubectl -n "$APP_NS" logs deploy/budgetapi -c budgetapi --tail=4
REMOTE
