#!/usr/bin/env bash
set -euo pipefail

# Writes MCP client config so an IDE can query the agentregistry catalog.
#
# The registry's MCP server accepts a bearer token, so the client-credentials token from
# get-token.sh is enough -- no interactive OAuth. Tokens are short-lived; re-run to refresh.
# Both output files are gitignored because the token is personal and expires.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

: "${AGENTREGISTRY_URL:?set AGENTREGISTRY_URL, e.g. http://34.144.188.89:12121}"

# The MCP bridge listens on its own port, not the API port.
MCP_URL="${AGENTREGISTRY_MCP_URL:-$(printf '%s' "$AGENTREGISTRY_URL" | sed -E 's|:[0-9]+$||'):31313/mcp}"
TOKEN="$(./registry/get-token.sh)"

write_config() { # $1 = path, $2 = top-level key
  local path="$1" key="$2"
  mkdir -p "$(dirname "$path")"
  python3 - "$path" "$key" "$MCP_URL" "$TOKEN" <<'PY'
import json, sys
path, key, url, token = sys.argv[1:5]
json.dump({key: {"agentregistry": {
    "type": "http",
    "url": url,
    "headers": {"Authorization": f"Bearer {token}"},
}}}, open(path, "w"), indent=2)
PY
  chmod 600 "$path"
  echo "  wrote ${path#$REPO_ROOT/}"
}

write_config "${REPO_ROOT}/.mcp.json" mcpServers          # Claude Code
write_config "${REPO_ROOT}/.vscode/mcp.json" servers      # VS Code

echo "==> Catalog MCP configured at ${MCP_URL}"
echo "    Try: \"what agents are published in the registry?\""
