#!/usr/bin/env bash
set -euo pipefail

# Runs support-ui on your machine against the cluster's registry and agents (demo step 5).
#
# The app itself is local; everything it talks to stays in the cluster, which is the point --
# wiring the app is a config change, not a deployment. The registry is reached over a
# port-forward so the local run uses exactly the coordinates a developer would type.
#
#   ./demo/local.sh
#
# Then open http://localhost:8080 and try the seeded personas:
#   CUST-001 / ORD-2024-0001  eligible at 27 days
#   CUST-010 / ORD-2024-0010  denied at 44 days
#   CUST-008 / ORD-2024-0008  shipped, not delivered

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

LOCAL_PORT="${LOCAL_REGISTRY_PORT:-12121}"

[ -f .env.local ] || { echo "ERROR: .env.local not found. Run registry/keycloak-setup.sh first." >&2; exit 1; }
set -a; . ./.env.local; set +a

# The frontend mints its own registry tokens, so it needs the service account, not a token.
export AGENTREGISTRY_URL="http://localhost:${LOCAL_PORT}"
export AGENTREGISTRY_RUNTIME="${AGENTREGISTRY_RUNTIME:-kagent}"
export CONCIERGE_AGENT="${CONCIERGE_AGENT:-support-concierge}"
export OIDC_ISSUER="${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}"
export OIDC_CLIENT_ID="${SUPPORT_UI_CLIENT_ID}"
export OIDC_CLIENT_SECRET="${SUPPORT_UI_CLIENT_SECRET}"
export AGENTREGISTRY_TIMEOUT_SECONDS="${AGENTREGISTRY_TIMEOUT_SECONDS:-180}"

# Homebrew's JDK is not registered with java_home, so the wrapper cannot find it unaided.
if [ -z "${JAVA_HOME:-}" ] && [ -d /opt/homebrew/opt/openjdk ]; then
  export JAVA_HOME=/opt/homebrew/opt/openjdk
  export PATH="${JAVA_HOME}/bin:${PATH}"
fi

echo "==> Port-forwarding the registry to localhost:${LOCAL_PORT}..."
kubectl port-forward -n agentregistry-system svc/agentregistry-enterprise-server \
  "${LOCAL_PORT}:12121" >/tmp/cloudcart-pf.log 2>&1 &
PF_PID=$!
cleanup() { kill "${PF_PID}" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

until curl -sf -m 2 "http://localhost:${LOCAL_PORT}/v0/health" >/dev/null 2>&1; do
  kill -0 "${PF_PID}" 2>/dev/null || { echo "ERROR: port-forward died. See /tmp/cloudcart-pf.log" >&2; exit 1; }
  sleep 1
done
echo "    registry reachable"

echo "==> Starting support-ui on http://localhost:8080 (Ctrl-C to stop)"
./mvnw -q -B -pl support-ui spring-boot:run
