#!/usr/bin/env bash
set -euo pipefail

echo "Switching Service selector to green..."
kubectl -n default patch service content-service -p '{"spec":{"selector":{"app":"content","version":"green"}}}'
echo "Patched service to point to green"
