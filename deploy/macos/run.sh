#!/usr/bin/env bash
# What launchd runs: loads budget.env beside this script, then becomes the server.
set -euo pipefail
cd "$(dirname "$0")"
set -a; source ./budget.env; set +a
exec ./bin/budget-server
