#!/usr/bin/env bash
set -euo pipefail

# Deploys the workloads only: the four MCP servers and the chat frontend.
#
# Agents, skills, prompts, and policies are NOT deployed here -- they are published to
# agentregistry from registry/ and deployed onto a runtime from the catalog. That split
# is the point of the demo, so resist the urge to add them to this script.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NAMESPACE="${NAMESPACE:-agentic-demo}"

echo "==> Creating namespace..."
kubectl apply -f "${SCRIPT_DIR}/namespace.yaml"

echo "==> Deploying MCP servers and chat frontend..."
kubectl apply -f "${SCRIPT_DIR}/services/"

echo "==> Waiting for rollouts..."
for d in catalog-service orders-service customers-service notifications-service support-ui; do
  kubectl rollout status "deployment/${d}" -n "${NAMESPACE}" --timeout=180s
done

echo ""
echo "==> Deployment complete."
echo "    MCP servers are running but nothing consumes them yet."
echo "    Next: publish artifacts with registry/publish.sh, then deploy an agent from the catalog."
echo ""
echo "    Chat UI:  kubectl get svc support-ui -n ${NAMESPACE}"
