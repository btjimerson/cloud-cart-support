#!/usr/bin/env bash
set -euo pipefail

# Creates the Keycloak groups and service-account clients this demo needs.
#
# Run this yourself -- it needs your Keycloak admin password, which is deliberately read from
# the environment and never printed. Client secrets are written straight into .env.local
# (gitignored, chmod 600) and are never echoed to the terminal.
#
#   export KEYCLOAK_ADMIN_USER=admin-user
#   export KEYCLOAK_ADMIN_PASSWORD=...        # not stored anywhere
#   ./registry/keycloak-setup.sh
#
# What it creates in realm `solo`:
#
#   Groups
#     support-engineers    the engineer persona -- composes and publishes, cannot approve
#     platform-approvers   the approver persona -- owns policy and the approval gate
#     admins               already exists; used by the automation client
#
#   Clients (all confidential; the first three are service accounts with browser flows
#   off, the last runs the authorization-code flow instead)
#     agentregistry-kagent   agentregistry -> kagent control plane
#     cloudcart-automation   publish.sh and CI -> agentregistry API
#     cloudcart-support-ui   the chat frontend -> agentregistry A2A proxy
#     cloudcart-gateway      agentgateway's browser OIDC login (authorization-code flow)
#
# Every client gets an explicit Groups mapper. Without one, Keycloak omits group membership
# from client_credentials tokens -- and kagent's roleMapper treats a *missing* Groups claim as
# global.Admin, so an unmapped service account silently becomes an admin.

KEYCLOAK_URL="${KEYCLOAK_URL:-https://keycloak.pintobean.xyz}"
REALM="${REALM:-solo}"
: "${KEYCLOAK_ADMIN_USER:?export KEYCLOAK_ADMIN_USER}"
: "${KEYCLOAK_ADMIN_PASSWORD:?export KEYCLOAK_ADMIN_PASSWORD}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env.local"

api() { # method path [body]
  local method="$1" path="$2" body="${3:-}" response http out
  if [ -n "$body" ]; then
    response="$(curl -sS -X "$method" "${KEYCLOAK_URL}/admin/realms/${REALM}${path}" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" -H 'Content-Type: application/json' \
      -d "$body" -w $'\n%{http_code}')"
  else
    response="$(curl -sS -X "$method" "${KEYCLOAK_URL}/admin/realms/${REALM}${path}" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" -w $'\n%{http_code}')"
  fi
  http="$(printf '%s' "$response" | tail -n1)"
  out="$(printf '%s' "$response" | sed '$d')"

  if [ "$http" -ge 400 ]; then
    echo "" >&2
    echo "ERROR: ${method} /admin/realms/${REALM}${path} -> HTTP ${http}" >&2
    [ -n "$out" ] && echo "  ${out}" >&2
    if [ "$http" = "403" ]; then
      cat >&2 <<EOF

  The token authenticated but is not allowed to administer realm '${REALM}'.
  Keycloak's Admin API needs realm-management roles, which a plain realm user does
  not have by default. Either:

    a) grant '${KEYCLOAK_ADMIN_USER}' the 'realm-admin' role:
         realm ${REALM} -> Users -> ${KEYCLOAK_ADMIN_USER} -> Role mapping
         -> Assign role -> Filter by clients -> realm-management realm-admin

    b) or re-run using the master-realm admin account:
         KEYCLOAK_ADMIN_REALM=master KEYCLOAK_ADMIN_USER=admin \\
         KEYCLOAK_ADMIN_PASSWORD=... ./registry/keycloak-setup.sh
EOF
    fi
    exit 1
  fi
  printf '%s' "$out"
}

# Reads an id out of an Admin API response that is expected to be a list. Keycloak returns a
# JSON *object* for errors, so indexing blindly turns a 403 into an unhelpful KeyError.
first_id() {
  python3 -c '
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    print(""); sys.exit()
try:
    d = json.loads(raw)
except json.JSONDecodeError:
    print("", file=sys.stdout); sys.exit()
if isinstance(d, list):
    print(d[0]["id"] if d else "")
elif isinstance(d, dict):
    print(d.get("id", ""))
else:
    print("")
'
}

echo "==> Authenticating to Keycloak..."
# Admin may live in the master realm or in the target realm; try master first unless told.
ADMIN_REALMS="${KEYCLOAK_ADMIN_REALM:-master ${REALM}}"
for tokrealm in ${ADMIN_REALMS}; do
  ADMIN_TOKEN="$(curl -sS -X POST \
    "${KEYCLOAK_URL}/realms/${tokrealm}/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=admin-cli \
    --data-urlencode "username=${KEYCLOAK_ADMIN_USER}" \
    --data-urlencode "password=${KEYCLOAK_ADMIN_PASSWORD}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null || true)"
  [ -n "${ADMIN_TOKEN}" ] && { echo "    authenticated via realm '${tokrealm}'"; break; }
done
[ -n "${ADMIN_TOKEN:-}" ] || { echo "ERROR: could not obtain an admin token. Check the username and password." >&2; exit 1; }

# Confirm the token can actually administer the realm before creating anything, so a
# permissions problem surfaces here rather than half way through.
echo "==> Checking Admin API access to realm '${REALM}'..."
api GET "" >/dev/null
echo "    ok"

# --- groups -----------------------------------------------------------------------------
for g in support-engineers platform-approvers admins; do
  existing="$(api GET "/groups?search=${g}&exact=true" | first_id)"
  if [ -n "$existing" ]; then
    echo "==> Group ${g}: exists"
  else
    api POST "/groups" "{\"name\":\"${g}\"}" >/dev/null
    echo "==> Group ${g}: created"
  fi
done

group_id() { api GET "/groups?search=$1&exact=true" | first_id; }

# --- clients ----------------------------------------------------------------------------
umask 077
: > "${ENV_FILE}.tmp"
{
  echo "# Generated by registry/keycloak-setup.sh -- gitignored, do not commit."
  echo "# Client secrets for the demo's service accounts."
} >> "${ENV_FILE}.tmp"

make_client() { # clientId group envprefix
  local cid="$1" grp="$2" prefix="$3"

  local uuid
  uuid="$(api GET "/clients?clientId=${cid}" | first_id)"

  if [ -z "$uuid" ]; then
    api POST "/clients" "$(cat <<JSON
{
  "clientId": "${cid}",
  "protocol": "openid-connect",
  "publicClient": false,
  "serviceAccountsEnabled": true,
  "standardFlowEnabled": false,
  "implicitFlowEnabled": false,
  "directAccessGrantsEnabled": false,
  "description": "cloud-cart-support demo service account"
}
JSON
)" >/dev/null
    uuid="$(api GET "/clients?clientId=${cid}" | first_id)"
    echo "==> Client ${cid}: created"
  else
    echo "==> Client ${cid}: exists"
  fi

  # Groups mapper -- required, see header note about kagent's admin fallback.
  local has_mapper
  has_mapper="$(api GET "/clients/${uuid}/protocol-mappers/models" \
    | python3 -c 'import json,sys; print(any(m.get("name")=="groups" for m in json.load(sys.stdin)))')"
  if [ "$has_mapper" != "True" ]; then
    api POST "/clients/${uuid}/protocol-mappers/models" "$(cat <<'JSON'
{
  "name": "groups",
  "protocol": "openid-connect",
  "protocolMapper": "oidc-group-membership-mapper",
  "config": {
    "claim.name": "Groups",
    "full.path": "false",
    "access.token.claim": "true",
    "id.token.claim": "true",
    "userinfo.token.claim": "true"
  }
}
JSON
)" >/dev/null
    echo "    added Groups mapper"
  fi

  # Put the client's service-account user in the right group.
  local sa_uid gid
  sa_uid="$(api GET "/clients/${uuid}/service-account-user" | first_id)"
  gid="$(group_id "${grp}")"
  if [ -n "$sa_uid" ] && [ -n "$gid" ]; then
    api PUT "/users/${sa_uid}/groups/${gid}" "{}" >/dev/null
    echo "    service account -> group ${grp}"
  fi

  local secret
  secret="$(api POST "/clients/${uuid}/client-secret" "{}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("value",""))')"
  [ -n "$secret" ] || secret="$(api GET "/clients/${uuid}/client-secret" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("value",""))')"

  {
    echo "${prefix}_CLIENT_ID=${cid}"
    echo "${prefix}_CLIENT_SECRET=${secret}"
  } >> "${ENV_FILE}.tmp"
}

make_login_client() { # clientId envprefix redirectUris...
  local cid="$1" prefix="$2"; shift 2
  local redirects="" r
  for r in "$@"; do
    redirects="${redirects:+${redirects},}\"${r}\""
  done

  local uuid
  uuid="$(api GET "/clients?clientId=${cid}" | first_id)"

  # Unlike the service accounts above this one runs the authorization-code flow: the gateway
  # redirects the browser to Keycloak and exchanges the code, so support-ui needs no login code.
  local body
  body="$(cat <<JSON
{
  "clientId": "${cid}",
  "protocol": "openid-connect",
  "publicClient": false,
  "serviceAccountsEnabled": false,
  "standardFlowEnabled": true,
  "implicitFlowEnabled": false,
  "directAccessGrantsEnabled": false,
  "redirectUris": [${redirects}],
  "webOrigins": ["+"],
  "description": "cloud-cart-support gateway OIDC login"
}
JSON
)"

  if [ -z "$uuid" ]; then
    api POST "/clients" "$body" >/dev/null
    uuid="$(api GET "/clients?clientId=${cid}" | first_id)"
    echo "==> Client ${cid}: created (authorization-code flow)"
  else
    api PUT "/clients/${uuid}" "$body" >/dev/null
    echo "==> Client ${cid}: updated (authorization-code flow)"
  fi

  # Same Groups mapper as the service accounts: the gateway's authorization rules match on it.
  local has_mapper
  has_mapper="$(api GET "/clients/${uuid}/protocol-mappers/models" \
    | python3 -c 'import json,sys; print(any(m.get("name")=="groups" for m in json.load(sys.stdin)))')"
  if [ "$has_mapper" != "True" ]; then
    api POST "/clients/${uuid}/protocol-mappers/models" "$(cat <<'JSON'
{
  "name": "groups",
  "protocol": "openid-connect",
  "protocolMapper": "oidc-group-membership-mapper",
  "config": {
    "claim.name": "Groups",
    "full.path": "false",
    "access.token.claim": "true",
    "id.token.claim": "true",
    "userinfo.token.claim": "true"
  }
}
JSON
)" >/dev/null
    echo "    added Groups mapper"
  fi

  local secret
  secret="$(api POST "/clients/${uuid}/client-secret" "{}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("value",""))')"
  {
    echo "${prefix}_CLIENT_ID=${cid}"
    echo "${prefix}_CLIENT_SECRET=${secret}"
  } >> "${ENV_FILE}.tmp"
}

make_client agentregistry-kagent admins  KAGENT_OIDC
make_client cloudcart-automation admins  AUTOMATION
make_client cloudcart-support-ui admins  SUPPORT_UI

# The gateway's browser login. GATEWAY_REDIRECT_URIS defaults to a wildcard so the demo works
# before the gateway address is known; narrow it once the UI route has a stable hostname.
make_login_client cloudcart-gateway GATEWAY ${GATEWAY_REDIRECT_URIS:-"*"}

{
  echo "KEYCLOAK_URL=${KEYCLOAK_URL}"
  echo "KEYCLOAK_REALM=${REALM}"
  echo "OIDC_ISSUER=${KEYCLOAK_URL}/realms/${REALM}"
} >> "${ENV_FILE}.tmp"

mv "${ENV_FILE}.tmp" "${ENV_FILE}"
chmod 600 "${ENV_FILE}"

echo ""
echo "==> Done. Client secrets written to .env.local (chmod 600, gitignored)."
echo ""
echo "    Next:"
echo "      source .env.local"
echo "      ./registry/get-token.sh            # mints a registry token from the automation client"
echo ""
echo "    Note: all three service accounts are in the 'admins' group for now, which makes them"
echo "    registry superusers. Tighten cloudcart-support-ui once the A2A path is proven, and"
echo "    keep support-engineers / platform-approvers for the two human demo personas."
