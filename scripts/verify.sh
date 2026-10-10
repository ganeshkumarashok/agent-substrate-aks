#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
exec > >(tee -a "$ROOT/.state/logs/verify.log") 2>&1
trap 'progress "FAILED functional verification; line=$LINENO; inspect .state/verification.json and .state/logs/verify.log"' ERR
require_owned_group
progress "Verifying five full suspend/resume cycles, forced worker replacement, and second-actor isolation"
python3 "$ROOT/scripts/verify.py" --receipt "$ROOT/.state/verification.json" \
  --port "${SUBSTRATE_LOCAL_PORT:-18080}"
progress "PASS functional verification; proof actors suspended; temporary port-forward stopped"
