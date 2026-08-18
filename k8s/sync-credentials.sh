#!/usr/bin/env bash
set -euo pipefail

# Pushes the client secrets in .env.local out to everything that holds a copy.
#
# Three consumers cache these independently, and when they drift the symptoms point nowhere
# near the cause:
#
#   support-ui-oidc (Kubernetes Secret)   -> chat answers "the agent is unavailable" (HTTP 401)
#   kagent-oidc (agentregistry Secret)    -> the registry cannot drive kagent, so deployments
#                                            hang in "terminating" and re-apply is refused
#   agent Deployment env                  -> the harness crash-loops on a 401 before starting
#
# The registry also caches the secret it resolved at startup, so it is restarted here; without
# that it keeps failing with "Invalid client or Invalid client credentials" even once the
# stored value is correct.
#
#   ./k8s/sync-credentials.sh
#
# Run after registry/keycloak-setup.sh, or any time an agent or the chat starts returning 401.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

[ -f .env.local ] || { echo "ERROR: .env.local not found. Run registry/keycloak-setup.sh first." >&2; exit 1; }
set -a; . ./.env.local; set +a
: "${AGENTREGISTRY_URL:?set AGENTREGISTRY_URL}"

echo "==> Checking the secrets in .env.local still authenticate..."
for pair in "KAGENT_OIDC" "AUTOMATION" "SUPPORT_UI"; do
  cid_var="${pair}_CLIENT_ID"; sec_var="${pair}_CLIENT_SECRET"
  cid="${!cid_var:-}"; sec="${!sec_var:-}"
  [ -n "$cid" ] || continue
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 20 -X POST \
    "${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" \
    -d grant_type=client_credentials \
    --data-urlencode "client_id=${cid}" --data-urlencode "client_secret=${sec}")"
  if [ "$code" = "200" ]; then
    echo "    ${cid}: ok"
  else
    echo "    ${cid}: HTTP ${code} -- re-run registry/keycloak-setup.sh" >&2
    exit 1
  fi
done

echo "==> Syncing the frontend's Kubernetes Secret..."
"${SCRIPT_DIR}/create-support-ui-secret.sh" >/dev/null
echo "    support-ui-oidc updated"

echo "==> Syncing the registry's kagent credential..."
TOKEN="$(./registry/get-token.sh)"
printf 'apiVersion: ar.dev/v1alpha1\nkind: Secret\nmetadata:\n  name: kagent-oidc\nspec:\n  stringData:\n    clientSecret: "%s"\n' \
  "${KAGENT_OIDC_CLIENT_SECRET}" \
  | curl -sS -X POST "${AGENTREGISTRY_URL}/v0/apply" \
      -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/yaml' --data-binary @- \
  | python3 -c 'import json,sys; [print("    Secret/"+r["name"], r["status"]) for r in json.load(sys.stdin)["results"]]'

# The registry resolves this secret once at startup, so a corrected value alone is not enough.
echo "==> Restarting the registry so it picks the credential up..."
kubectl rollout restart deployment/agentregistry-enterprise-server -n agentregistry-system >/dev/null
kubectl rollout status deployment/agentregistry-enterprise-server -n agentregistry-system --timeout=240s >/dev/null
echo "    registry restarted"

echo ""
echo "==> Credentials in sync. Agent deployments hold their own copy of the frontend secret;"
echo "    refresh those with:  ./registry/deploy-agents.sh --recreate"
