#!/usr/bin/env bash
set -euo pipefail

# Creates the Secret the chat frontend uses to mint its own registry tokens.
#
# Reads .env.local (written by registry/keycloak-setup.sh) and never prints the values.
# Run this before k8s/deploy.sh, or any time the client secret is rotated.
#
# Unlike the harness -- whose credentials must sit in the registry Deployment as plaintext,
# because DeploymentSpec.env is map[string]string -- the frontend is a normal Kubernetes
# workload, so its credentials live in a Secret where they belong.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
NAMESPACE="${NAMESPACE:-agentic-demo}"

[ -f "${REPO_ROOT}/.env.local" ] || {
  echo "ERROR: ${REPO_ROOT}/.env.local not found. Run registry/keycloak-setup.sh first." >&2
  exit 1
}
set -a; . "${REPO_ROOT}/.env.local"; set +a

: "${KEYCLOAK_URL:?missing from .env.local}"
: "${KEYCLOAK_REALM:?missing from .env.local}"
: "${SUPPORT_UI_CLIENT_ID:?missing from .env.local}"
: "${SUPPORT_UI_CLIENT_SECRET:?missing from .env.local}"

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl create secret generic support-ui-oidc \
  -n "${NAMESPACE}" \
  --from-literal=issuer="${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}" \
  --from-literal=clientId="${SUPPORT_UI_CLIENT_ID}" \
  --from-literal=clientSecret="${SUPPORT_UI_CLIENT_SECRET}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> support-ui-oidc secret is in place in ${NAMESPACE}."
