#!/usr/bin/env bash
set -euo pipefail

# Local CI script: build images, create kind cluster, load images, deploy manifests,
# run k6 jobs (bluegreen + canary), collect JSON results and logs, then teardown.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
CLUSTER_NAME=ci

echo "Starting local CI smoke run (root: $ROOT_DIR)"

command -v docker >/dev/null 2>&1 || { echo "docker not found" >&2; exit 1; }
command -v kind >/dev/null 2>&1 || { echo "kind not found" >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found" >&2; exit 1; }

mkdir -p "$ARTIFACTS_DIR"

build_images() {
  echo "Building service images..."
  docker build -t content-blue:local -f apps/blue-v1/Dockerfile .
  docker build -t content-green:local -f apps/blue-v2/Dockerfile .
  if [ -f "apps/canary/Dockerfile" ]; then
    docker build -t content-canary:local -f apps/canary/Dockerfile .
  else
    echo "No apps/canary/Dockerfile found — skipping canary image build"
  fi

  echo "Building local k6 image..."
  docker build -t local/k6:ci -f scripts/k6/Dockerfile .
}

create_kind() {
  if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
    echo "kind cluster ${CLUSTER_NAME} already exists — reusing"
  else
    echo "Creating kind cluster ${CLUSTER_NAME}..."
    kind create cluster --name "$CLUSTER_NAME" --wait 60s
  fi
  kubectl cluster-info --context kind-${CLUSTER_NAME} >/dev/null 2>&1 || true
}

load_images() {
  echo "Loading images into kind cluster..."
  kind load docker-image content-blue:local --name "$CLUSTER_NAME"
  kind load docker-image content-green:local --name "$CLUSTER_NAME"
  if docker image inspect content-canary:local >/dev/null 2>&1; then
    kind load docker-image content-canary:local --name "$CLUSTER_NAME"
  fi
  kind load docker-image local/k6:ci --name "$CLUSTER_NAME"
}

apply_manifests() {
  echo "Applying k8s manifests..."
  kubectl apply -f k8s/blue-green
  kubectl apply -f k8s/canary || true
  kubectl apply -f k8s/load-test/configmap-k6.yaml || true
}

wait_pods() {
  echo "Waiting for app pods to be ready..."
  kubectl wait --for=condition=ready pod -l app=content --timeout=120s || true
  kubectl get pods -l app=content -o wide
}

run_k6_job() {
  local job_yaml="$1"
  local out_json="$2"
  local job_name="$3"

  # For local runs we execute k6 from the local k6 image and port-forward the service
  echo "Running k6 locally against the cluster (port-forward + docker k6) for $job_name -> $out_json"
  # Extract script from configmap into artifacts
  if kubectl get configmap k6-scripts >/dev/null 2>&1; then
    if [[ "$job_name" == "k6-bluegreen" ]]; then
      kubectl get configmap k6-scripts -o json | jq -r '.data["blue-green.js"]' > "$ARTIFACTS_DIR/blue-green.js"
      SCRIPT_PATH="$ARTIFACTS_DIR/blue-green.js"
      # When running k6 from a Docker container on macOS, use host.docker.internal to reach
      # the host port-forward. 127.0.0.1 inside the container is the container itself.
      TARGET_URL="http://host.docker.internal:8080/"
    else
      kubectl get configmap k6-scripts -o json | jq -r '.data["canary.js"]' > "$ARTIFACTS_DIR/canary.js"
      SCRIPT_PATH="$ARTIFACTS_DIR/canary.js"
      TARGET_URL="http://host.docker.internal:8081/"
    fi
  else
    echo "k6 configmap not found; cannot extract scripts" >&2
    return 1
  fi

  # Patch the script to point to the host port-forward (use explicit replacements).
  # Replace the cluster DNS names with host.docker.internal and the forwarded port so
  # the k6 container can reach the services when run from Docker on macOS.
  sed -E \
    -e "s|content-service-canary.default.svc.cluster.local|host.docker.internal:8081|g" \
    -e "s|content-service.default.svc.cluster.local|host.docker.internal:8080|g" \
    "$SCRIPT_PATH" > "${SCRIPT_PATH}.local" && mv "${SCRIPT_PATH}.local" "$SCRIPT_PATH"

  # Start port-forward to the appropriate service
  if [[ "$job_name" == "k6-bluegreen" ]]; then
    kubectl port-forward svc/content-service 8080:80 >/dev/null 2>&1 &
    PF_PID=$!
  else
    kubectl port-forward svc/content-service-canary 8081:80 >/dev/null 2>&1 &
    PF_PID=$!
  fi

  # wait a moment for port-forward to start
  sleep 2

  echo "Running k6 docker container to execute $SCRIPT_PATH"
  docker run --rm -v "$ARTIFACTS_DIR":/scripts -v "$ARTIFACTS_DIR":/tmp local/k6:ci run --out json=/tmp/$(basename "$out_json") /scripts/$(basename "$SCRIPT_PATH") || true

  # stop port-forward
  if [ -n "${PF_PID-}" ]; then
    kill "$PF_PID" || true
  fi

  if [ -f "$ARTIFACTS_DIR/$(basename "$out_json")" ]; then
    echo "Collected artifact: $ARTIFACTS_DIR/$(basename "$out_json")"
  else
    echo "No artifact produced for $job_name; check logs in $ARTIFACTS_DIR/${job_name}.log"
  fi

  kubectl logs job/$job_name --tail=500 > "$ARTIFACTS_DIR/${job_name}.log" || true
}

main() {
  build_images
  create_kind
  load_images
  apply_manifests
  wait_pods

  run_k6_job "k8s/load-test/job-bluegreen.yaml" "k6-bluegreen.json" "k6-bluegreen"
  run_k6_job "k8s/load-test/job-canary.yaml" "k6-canary.json" "k6-canary"

  echo "Artifacts saved in $ARTIFACTS_DIR"
  echo "Done. To teardown the kind cluster run: kind delete cluster --name $CLUSTER_NAME"
}

main "$@"
