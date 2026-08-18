#!/usr/bin/env bash
set -euo pipefail

# Returns a rehearsed environment to first-run state.
#
# This is not optional between run-throughs. The agents hold write tools and use them: a
# rehearsal that initiates a return leaves ORD-2024-0001 in `return_requested`, and the
# standard-return beat then quietly stops working with no obvious cause. Seed data is
# in-memory and rebuilt at startup, so restarting the service is the reset.
#
#   ./demo/reset.sh              # data, catalog, agents
#   ./demo/reset.sh --policies   # also remove the gateway policies added in steps 7-9
#
# Leaves alone: the kagent runtime, Keycloak clients and groups, the registry install.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

NAMESPACE="${NAMESPACE:-agentic-demo}"
DROP_POLICIES=false
[ "${1:-}" = "--policies" ] && DROP_POLICIES=true

[ -f .env.local ] && { set -a; . ./.env.local; set +a; }
: "${AGENTREGISTRY_URL:?set AGENTREGISTRY_URL, e.g. http://34.144.188.89:12121}"
export AGENTREGISTRY_TOKEN="${AGENTREGISTRY_TOKEN:-$(./registry/get-token.sh)}"

# Keycloak client secrets and the in-cluster Secret drift apart easily -- re-running
# keycloak-setup.sh used to rotate them, and the frontend then 401s with only "the agent is
# unavailable" to show for it. Re-syncing here makes that class of failure impossible.
echo "==> Re-syncing the frontend's registry credentials..."
./k8s/create-support-ui-secret.sh >/dev/null
kubectl rollout restart deployment/support-ui -n "${NAMESPACE}" >/dev/null
echo "    support-ui-oidc in sync with .env.local"

echo "==> Resetting seeded data..."
# Only orders carries mutable demo state; the other three are read-mostly, but restarting
# them all keeps the reset honest and costs a few seconds.
for svc in orders-service customers-service notifications-service catalog-service; do
  kubectl rollout restart "deployment/${svc}" -n "${NAMESPACE}" >/dev/null
done
for svc in orders-service customers-service notifications-service catalog-service; do
  kubectl rollout status "deployment/${svc}" -n "${NAMESPACE}" --timeout=180s >/dev/null
  echo "    ${svc} reseeded"
done
kubectl rollout status deployment/support-ui -n "${NAMESPACE}" --timeout=180s >/dev/null

# The agents hold MCP sessions to the services just restarted, so cycle them too rather than
# leaving a pod that reconnects on its own schedule.
echo "==> Restarting agents so they reconnect to the reseeded services..."
for a in returns-agent order-agent complaint-agent product-agent support-concierge; do
  kubectl rollout restart "deployment/${a}" -n kagent >/dev/null 2>&1 || true
done

if [ "$DROP_POLICIES" = true ]; then
  echo "==> Removing gateway policies added during the demo..."
  for p in cloudcart-jwt-auth cloudcart-prompt-guard cloudcart-token-exchange; do
    kubectl delete enterpriseagentgatewaypolicy "$p" -n agentgateway-system --ignore-not-found >/dev/null 2>&1 || true
    echo "    ${p} removed (if present)"
  done
  kubectl delete authconfig cloudcart-oidc -n agentic-demo --ignore-not-found >/dev/null 2>&1 || true
fi

echo "==> Republishing the catalog..."
./registry/publish.sh 2>&1 | grep -E '^  wave|created|configured|failed' | sed 's/^/  /' || true

echo "==> Redeploying agents..."
./registry/deploy-agents.sh 2>&1 | sed 's/^/  /'

echo "==> Waiting for agents to become ready..."
until [ "$(kubectl get agents.kagent.dev -n kagent --no-headers 2>/dev/null | grep -c 'True.*True')" = "5" ]; do
  sleep 5
done
kubectl get agents.kagent.dev -n kagent --no-headers | awk '{print "    "$1" "$4}'

echo ""
echo "==> Reset complete. Verify the standard-return path is eligible again:"
echo "    curl -s -X POST http://\$(kubectl get svc support-ui -n ${NAMESPACE} -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):8080/chat \\"
echo "      -H 'Content-Type: application/json' \\"
echo "      -d '{\"message\":\"I am CUST-001. Can I return ORD-2024-0001?\",\"customer_id\":\"CUST-001\"}'"
