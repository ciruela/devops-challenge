#!/usr/bin/env bash
set -euo pipefail

echo "Building images inside minikube docker..."
if ! command -v minikube >/dev/null 2>&1; then
  echo "minikube not found. Install minikube or build images manually." >&2
  exit 1
fi

echo "Setting docker env to minikube"
eval "$(minikube -p minikube docker-env)"

docker build -t content-blue:local -f apps/blue-v1/Dockerfile .
docker build -t content-green:local -f apps/blue-v2/Dockerfile .
docker build -t content-canary:local -f apps/canary/Dockerfile .

echo "Images built: content-blue:local, content-green:local, content-canary:local"
