#!/usr/bin/env bash
set -euo pipefail

# Publishes this directory to agentregistry via POST /v0/apply.
#
# Order matters. The registry resolves references against *stored* state, not against the
# rest of the batch: an Agent that references a Prompt in the same request still fails with
# "referenced resource not found". So leaves are applied first, then the agents that compose
# them, then the policies that govern them. Teardown runs in reverse.
#
# Usage:
#   ./publish.sh                 # apply
#   ./publish.sh --dry-run       # validate, mutate nothing
#   ./publish.sh --delete        # remove everything this script publishes
#   ./publish.sh --skip runtimes # publish the catalog before the runtime credential exists
#
# Each wave also publishes registry/inventory/<wave> when present: artifacts owned by other
# teams that make the catalog worth browsing. They are never deployed.
#
# Requires AGENTREGISTRY_URL and AGENTREGISTRY_TOKEN.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
: "${AGENTREGISTRY_URL:?set AGENTREGISTRY_URL (e.g. http://localhost:12121)}"
: "${AGENTREGISTRY_TOKEN:?set AGENTREGISTRY_TOKEN to an OIDC access token}"

MODE="apply"
QUERY=""
SKIP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) QUERY="?dryRun=true" ;;
    --delete)  MODE="delete" ;;
    # Publish the catalog before a wave's prerequisites exist -- notably `runtimes`, which
    # needs a Keycloak client for the registry-to-kagent call. Repeatable.
    --skip)    SKIP="${SKIP} ${2:?--skip needs a wave name}"; shift ;;
    *)         echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

# Leaves first, then composites, then policy.
WAVES=(
  "runtimes"
  "mcp-servers"
  "skills"
  "prompts"
  "agents"
  "policies"
)

send() { # $1 = http method, $2 = directory
  local method="$1" dir="$2"
  local files=("${SCRIPT_DIR}/${dir}"/*.yaml)
  [ -e "${files[0]}" ] || { echo "  (${dir}: nothing to apply)"; return 0; }

  local payload
  payload="$(awk 'FNR==1 && NR!=1 {print "---"} {print}' "${files[@]}")"

  local response http
  response="$(printf '%s' "$payload" | curl -sS -X "$method" \
    "${AGENTREGISTRY_URL}/v0/apply${QUERY}" \
    -H "Authorization: Bearer ${AGENTREGISTRY_TOKEN}" \
    -H "Content-Type: application/yaml" \
    --data-binary @- \
    -w $'\n%{http_code}')"
  http="$(printf '%s' "$response" | tail -n1)"
  body="$(printf '%s' "$response" | sed '$d')"

  if [ "$http" != "200" ]; then
    echo "  ${dir}: HTTP ${http}" >&2
    echo "${body}" >&2
    return 1
  fi

  # Surface per-document failures: /v0/apply returns 200 even when individual documents fail.
  if printf '%s' "$body" | grep -q '"status":"failed"'; then
    echo "  ${dir}: one or more documents failed" >&2
    printf '%s' "$body" | python3 -c "
import json,sys
for r in json.load(sys.stdin).get('results', []):
    if r.get('status') == 'failed':
        print(f\"    {r.get('kind')}/{r.get('name')}: {r.get('error')}\", file=sys.stderr)
" || printf '%s\n' "$body" >&2
    return 1
  fi

  printf '%s' "$body" | python3 -c "
import json,sys
for r in json.load(sys.stdin).get('results', []):
    print(f\"    {r.get('kind')}/{r.get('name')}:{r.get('tag','-')} {r.get('status')}\")
" || printf '%s\n' "$body"
}

if [ "$MODE" = "delete" ]; then
  echo "==> Removing artifacts from agentregistry (reverse dependency order)..."
  for (( i=${#WAVES[@]}-1 ; i>=0 ; i-- )); do
    w="${WAVES[$i]}"
    case " ${SKIP} " in *" ${w} "*) echo "  wave: ${w} (skipped)"; continue ;; esac
    echo "  wave: ${w}"
    # Inventory first: it is the outer layer, and nothing of ours depends on it.
    send DELETE "inventory/${w}" || true
    send DELETE "${w}" || true   # keep going: partial state should still drain
  done
  echo "==> Registry teardown complete."
else
  [ -n "$QUERY" ] && echo "==> Validating (dry run) ..." || echo "==> Publishing to agentregistry..."
  for w in "${WAVES[@]}"; do
    case " ${SKIP} " in *" ${w} "*) echo "  wave: ${w} (skipped)"; continue ;; esac
    echo "  wave: ${w}"
    send POST "$w"
    # The wider estate other teams own. Catalog-only -- published so the inventory is worth
    # browsing, never deployed, so an unreachable decoy cannot break anything.
    send POST "inventory/${w}"
  done
  echo ""
  if [ -n "$QUERY" ]; then
    echo "==> Validation complete. Nothing was changed."
    echo "    Note: agents and policies will report missing references on a dry run against an"
    echo "    empty catalog, because a dry run does not persist the leaves they point at."
  else
    echo "==> Published. The catalog now holds the app; nothing is deployed yet."
    echo "    Next: deploy an agent onto a runtime from the catalog UI."
  fi
fi
