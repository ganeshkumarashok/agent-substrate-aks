#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
exec > >(tee -a "$ROOT/.state/logs/build-tools.log") 2>&1
trap 'progress "FAILED tool build; line=$LINENO; inspect .state/logs/build-tools.log"' ERR

if [[ ! -d "$UPSTREAM/.git" ]]; then
  git clone --quiet --no-checkout https://github.com/agent-substrate/substrate.git "$UPSTREAM"
  git -C "$UPSTREAM" checkout --quiet --detach "$SUBSTRATE_COMMIT"
fi
if [[ "$(git -C "$UPSTREAM" rev-parse HEAD)" != "$SUBSTRATE_COMMIT" ]]; then
  echo "Upstream checkout is not the pinned commit; refusing to build." >&2
  exit 1
fi
progress "Building installer and CLI from pinned $SUBSTRATE_VERSION; required Go toolchain resolved by upstream go.mod"
cd "$UPSTREAM"
make VERSION="$SUBSTRATE_VERSION" build-ate-setup build-atectl
cp bin/ate-setup bin/kubectl-ate "$ROOT/.cache/bin/"
progress "Built installer and CLI; next=AKS preflight then source image build"
bash "$ROOT/scripts/bootstrap-kubectl.sh"
