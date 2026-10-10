#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
exec kubectl -n ate-system port-forward --address 127.0.0.1 \
  svc/atenet-router "${SUBSTRATE_LOCAL_PORT:-18080}:80"
