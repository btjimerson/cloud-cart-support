#!/usr/bin/env bash
set -euo pipefail

# Removes everything this demo creates.
#
# Two distinct control planes are involved and both must be cleaned:
#   1. Kubernetes -- the namespace and its workloads
#   2. agentregistry -- published artifacts and deployments, which live in the registry's
#      own Postgres and survive a namespace delete
#
# The registry teardown is intentionally first: deleting the namespace out from under a
# live deployment leaves the catalog holding a deployment that points at nothing.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
NAMESPACE="${NAMESPACE:-agentic-demo}"

echo "==> Removing published artifacts from agentregistry..."
if [ -x "${REPO_ROOT}/registry/publish.sh" ]; then
  "${REPO_ROOT}/registry/publish.sh" --delete || echo "    (registry teardown skipped or already clean)"
else
  echo "    (registry/publish.sh not present yet -- skipping)"
fi

echo "==> Deleting the ${NAMESPACE} namespace..."
kubectl delete namespace "${NAMESPACE}" --ignore-not-found --wait=true

echo ""
echo "==> Cleanup complete."
echo "    Left in place (not created by this demo): agentregistry, agentgateway, kagent,"
echo "    and the agentgateway-demo namespace."
