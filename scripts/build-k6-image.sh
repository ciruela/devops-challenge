#!/usr/bin/env bash
set -euo pipefail

K6_IMAGE=local/k6:arm64
echo "Building k6 image (${K6_IMAGE}) inside minikube Docker..."
eval "$(minikube -p minikube docker-env)"
docker build -t ${K6_IMAGE} -f scripts/k6/Dockerfile .
echo "Built ${K6_IMAGE}"
