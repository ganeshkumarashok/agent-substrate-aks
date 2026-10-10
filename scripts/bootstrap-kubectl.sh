#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
case "$(uname -s)" in
  Darwin) os=darwin ;;
  Linux) os=linux ;;
  *) echo "Unsupported kubectl host OS" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  arm64|aarch64) arch=arm64 ;;
  x86_64) arch=amd64 ;;
  *) echo "Unsupported kubectl host architecture" >&2; exit 1 ;;
esac
url="https://dl.k8s.io/release/v$AKS_KUBERNETES_VERSION/bin/$os/$arch/kubectl"
curl --fail --location --silent --show-error "$url" -o "$ROOT/.state/kubectl.download"
curl --fail --location --silent --show-error "$url.sha256" -o "$ROOT/.state/kubectl.sha256"
python3 - "$ROOT/.state/kubectl.download" "$ROOT/.state/kubectl.sha256" <<'PY'
import hashlib
import pathlib
import sys
binary, checksum = map(pathlib.Path, sys.argv[1:])
actual = hashlib.file_digest(binary.open("rb"), "sha256").hexdigest()
if actual != checksum.read_text().strip():
    raise SystemExit("kubectl checksum mismatch; refusing installation")
PY
chmod 700 "$ROOT/.state/kubectl.download"
mv "$ROOT/.state/kubectl.download" "$ROOT/.cache/bin/kubectl"
progress "Installed checksum-verified task-local kubectl v$AKS_KUBERNETES_VERSION; global binary unchanged"
