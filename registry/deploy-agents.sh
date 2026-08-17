#!/usr/bin/env bash
set -euo pipefail

# Deploys catalog agents onto a runtime.
#
# Deployments are not catalog artifacts under registry/ because they are environment-specific:
# the same five agents deploy to a dev cluster and to prod with different runtimes, different
# endpoints and a different policy set. Keeping them in a script rather than in the catalog
# keeps that separation honest.
#
#   ./deploy-agents.sh                        # all five onto kagent
#   ./deploy-agents.sh returns-agent          # just one
#   RUNTIME=aws-bedrock ./deploy-agents.sh product-agent
#   ./deploy-agents.sh --delete               # tear down
#
# Requires AGENTREGISTRY_URL and AGENTREGISTRY_TOKEN, plus .env.local for the harness's
# OIDC credentials.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
[ -f "${REPO_ROOT}/.env.local" ] && { set -a; . "${REPO_ROOT}/.env.local"; set +a; }

: "${AGENTREGISTRY_URL:?set AGENTREGISTRY_URL}"
: "${AGENTREGISTRY_TOKEN:?set AGENTREGISTRY_TOKEN (registry/get-token.sh)}"

RUNTIME="${RUNTIME:-kagent}"
AGENT_TAG="${AGENT_TAG:-v1}"

# In-cluster addresses: the agents run beside these services, not behind the public LBs.
REGISTRY_IN_CLUSTER="${REGISTRY_IN_CLUSTER:-http://agentregistry-enterprise-server.agentregistry-system.svc:12121}"
# The gateway holds the model API key and injects it, so no key is stored on any agent.
MODEL_BASE_URL="${MODEL_BASE_URL:-http://agentgateway-proxy.agentgateway-system.svc:8080}"
# Tracing is off unless the workload is told to turn it on: kagent's app reads
# OTEL_TRACING_ENABLED and defaults it to false. The runtime's telemetryEndpoint is registered
# but the adapter does not export it to the pod, so it is passed explicitly here. Port 4317 is
# the collector's gRPC port, which matches the exporter's default protocol -- 4318 would also
# need OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf and a /v1/traces suffix.
OTEL_ENDPOINT="${OTEL_ENDPOINT:-http://agentregistry-enterprise-telemetry-collector.agentregistry-system.svc.cluster.local:4317}"

ALL_AGENTS=(returns-agent order-agent complaint-agent product-agent support-concierge)

DELETE=false
AGENTS=()
for arg in "$@"; do
  case "$arg" in
    --delete) DELETE=true ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *) AGENTS+=("$arg") ;;
  esac
done
[ ${#AGENTS[@]} -eq 0 ] && AGENTS=("${ALL_AGENTS[@]}")

api() { # method, path, [body-file]
  local method="$1" path="$2" file="${3:-}"
  if [ -n "$file" ]; then
    curl -sS -X "$method" "${AGENTREGISTRY_URL}${path}" \
      -H "Authorization: Bearer ${AGENTREGISTRY_TOKEN}" \
      -H 'Content-Type: application/yaml' --data-binary "@${file}"
  else
    curl -sS -X "$method" "${AGENTREGISTRY_URL}${path}" \
      -H "Authorization: Bearer ${AGENTREGISTRY_TOKEN}" -o /dev/null -w '%{http_code}'
  fi
}

if [ "$DELETE" = true ]; then
  for a in "${AGENTS[@]}"; do
    printf '  delete %-20s -> %s\n' "$a" "$(api DELETE "/v0/deployments/${a}")"
  done
  exit 0
fi

for a in "${AGENTS[@]}"; do
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
apiVersion: ar.dev/v1alpha1
kind: Deployment
metadata:
  name: ${a}
spec:
  targetRef: {kind: Agent, name: ${a}, tag: ${AGENT_TAG}}
  runtimeRef: {kind: Runtime, name: ${RUNTIME}}
  env:
    AGENTREGISTRY_URL: "${REGISTRY_IN_CLUSTER}"
    OIDC_ISSUER: "${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}"
    OIDC_CLIENT_ID: "${SUPPORT_UI_CLIENT_ID}"
    OIDC_CLIENT_SECRET: "${SUPPORT_UI_CLIENT_SECRET}"
    AGENT_TAG: "${AGENT_TAG}"
    MODEL_BASE_URL: "${MODEL_BASE_URL}"
    OPENAI_API_KEY: "held-at-the-gateway"
    OTEL_TRACING_ENABLED: "true"
    OTEL_EXPORTER_OTLP_ENDPOINT: "${OTEL_ENDPOINT}"
    OTEL_SERVICE_NAME: "${a}"
EOF
  result="$(api POST "/v0/apply" "$tmp" | python3 -c '
import json, sys
try:
    for r in json.load(sys.stdin).get("results", []):
        print((r.get("status") or "?") + (" " + r["error"][:160] if r.get("error") else ""))
except Exception as e:
    print("unparseable response:", e)')"
  printf '  %-20s %s -> %s\n' "$a" "$RUNTIME" "$result"
  rm -f "$tmp"
done
