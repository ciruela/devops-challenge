#!/usr/bin/env bash
set -euo pipefail

# Cleanup script for the local CI runner and artifacts
# - deletes k8s manifests applied from this repo
# - kills any lingering kubectl port-forward processes targeting the services used
# - removes kind cluster (default name: ci)
# - removes locally-built docker images used by the runner
# - deletes artifacts/ directory
# Usage: ./scripts/cleanup.sh [--cluster-name NAME] [--yes] [--skip-kind] [--skip-images] [--skip-artifacts]

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
CLUSTER_NAME=${CLUSTER_NAME:-ci}
YES=0
SKIP_KIND=0
SKIP_IMAGES=0
SKIP_ARTIFACTS=0

usage() {
  cat <<EOF
Usage: $0 [options]
Options:
  --cluster-name NAME   Kind cluster name to delete (default: $CLUSTER_NAME)
  --yes                 Don't prompt, assume yes
  --skip-kind           Skip deleting the kind cluster
  --skip-images         Skip removing docker images
  --skip-artifacts      Skip deleting artifacts/ directory
  -h, --help            Show this help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cluster-name)
      CLUSTER_NAME="$2"; shift 2;;
    --yes)
      YES=1; shift;;
    --skip-kind)
      SKIP_KIND=1; shift;;
    --skip-images)
      SKIP_IMAGES=1; shift;;
    --skip-artifacts)
      SKIP_ARTIFACTS=1; shift;;
    -h|--help)
      usage; exit 0;;
    *)
      echo "Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

confirm() {
  if [ "$YES" -eq 1 ]; then
    return 0
  fi
  read -r -p "$1 [y/N]: " resp
  case "$resp" in
    [yY]|[yY][eE][sS]) return 0;;
    *) return 1;;
  esac
}

echo "Cleanup starting (root: $ROOT_DIR)"

# 1) Delete k8s resources that the runner applied
echo "Deleting Kubernetes manifests (if present)..."
kubectl delete -f k8s/blue-green --ignore-not-found --wait=false || true
kubectl delete -f k8s/canary --ignore-not-found --wait=false || true
kubectl delete -f k8s/load-test/configmap-k6.yaml --ignore-not-found --wait=false || true
kubectl delete -f k8s/load-test --ignore-not-found --wait=false || true

# Also attempt to delete any k6 jobs by name (if they exist)
kubectl delete job k6-bluegreen --ignore-not-found || true
kubectl delete job k6-canary --ignore-not-found || true

# 2) Kill lingering kubectl port-forward processes that reference the repo services
echo "Killing kubectl port-forward processes (svc/content-service and svc/content-service-canary)..."
# Find processes with 'kubectl port-forward' and the service names
PF_PIDS=$(pgrep -f "kubectl port-forward .*content-service" || true)
if [ -n "$PF_PIDS" ]; then
  echo "Killing port-forward pids: $PF_PIDS"
  echo "$PF_PIDS" | xargs -r kill || true
fi
PF_PIDS2=$(pgrep -f "kubectl port-forward .*content-service-canary" || true)
if [ -n "$PF_PIDS2" ]; then
  echo "Killing port-forward pids: $PF_PIDS2"
  echo "$PF_PIDS2" | xargs -r kill || true
fi

# 3) Delete kind cluster
if [ "$SKIP_KIND" -eq 0 ]; then
  if command -v kind >/dev/null 2>&1; then
    if kind get clusters | grep -qE "^${CLUSTER_NAME}$"; then
      if confirm "Delete kind cluster '${CLUSTER_NAME}'?"; then
        echo "Deleting kind cluster ${CLUSTER_NAME}..."
        kind delete cluster --name "$CLUSTER_NAME" || true
      else
        echo "Skipping kind delete"
      fi
    else
      echo "Kind cluster '${CLUSTER_NAME}' not found — skipping"
    fi
  else
    echo "kind CLI not installed — cannot delete kind cluster"
  fi
else
  echo "SKIP_KIND set — not deleting kind cluster"
fi

# 4) Remove local docker images
if [ "$SKIP_IMAGES" -eq 0 ]; then
  if command -v docker >/dev/null 2>&1; then
    IMGS=(content-blue:local content-green:local content-canary:local local/k6:ci)
    echo "Removing local docker images (if present): ${IMGS[*]}"
    for img in "${IMGS[@]}"; do
      if docker image inspect "$img" >/dev/null 2>&1; then
        if confirm "Remove docker image $img?"; then
          docker image rm -f "$img" || true
        else
          echo "Keeping $img"
        fi
      else
        echo "Image $img not found locally — skipping"
      fi
    done
  else
    echo "docker not found — skipping image removal"
  fi
else
  echo "SKIP_IMAGES set — not removing images"
fi

# 5) Remove artifacts directory
if [ "$SKIP_ARTIFACTS" -eq 0 ]; then
  if [ -d "$ARTIFACTS_DIR" ]; then
    if confirm "Delete artifacts directory $ARTIFACTS_DIR?"; then
      echo "Removing $ARTIFACTS_DIR"
      rm -rf "$ARTIFACTS_DIR"
    else
      echo "Keeping artifacts directory"
    fi
  else
    echo "No artifacts directory found — skipping"
  fi
else
  echo "SKIP_ARTIFACTS set — not removing artifacts"
fi

echo "Cleanup completed."
