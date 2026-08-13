#!/usr/bin/env bash
set -euo pipefail

# Mints an agentregistry access token using the automation service account and prints it.
#
# Intended to be consumed, not read:
#     export AGENTREGISTRY_TOKEN="$(./registry/get-token.sh)"
#
# Reads AUTOMATION_CLIENT_ID / AUTOMATION_CLIENT_SECRET from .env.local when present, so the
# usual flow is `source .env.local` first. Tokens are short-lived; re-run rather than storing.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "${REPO_ROOT}/.env.local" ] && . "${REPO_ROOT}/.env.local"

KEYCLOAK_URL="${KEYCLOAK_URL:-https://keycloak.pintobean.xyz}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-solo}"
CLIENT_ID="${1:-${AUTOMATION_CLIENT_ID:-cloudcart-automation}}"
CLIENT_SECRET="${2:-${AUTOMATION_CLIENT_SECRET:-}}"

if [ -z "${CLIENT_SECRET}" ]; then
  echo "ERROR: no client secret. Run registry/keycloak-setup.sh, then 'source .env.local'." >&2
  exit 1
fi

response="$(curl -sS -X POST \
  "${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" \
  -d grant_type=client_credentials \
  --data-urlencode "client_id=${CLIENT_ID}" \
  --data-urlencode "client_secret=${CLIENT_SECRET}")"

token="$(printf '%s' "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))')"

if [ -z "$token" ]; then
  echo "ERROR: no access_token returned." >&2
  printf '%s\n' "$response" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("  ", d.get("error"), "-", d.get("error_description"), file=sys.stderr)' 2>/dev/null || true
  exit 1
fi

printf '%s' "$token"
