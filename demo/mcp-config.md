# Pointing an IDE at the catalog

The registry runs its own MCP server, so an editor can query the catalog without leaving it.
This is what makes demo step 3 a developer beat rather than an ops one.

**Endpoint:** port `31313` on the agentregistry LoadBalancer, path `/mcp`
(`/` and `/sse` also answer). **Auth:** a bearer token — a client-credentials token from
`registry/get-token.sh` is accepted, so no interactive OAuth flow is needed.

Tools exposed (10): `list_agents`, `list_servers`, `list_skills`, `list_deployments`,
`get_agent`, `get_server`, `get_skill`, `get_deployment`, `registry_health`,
`registry_version`. Each returns the artifact as a `v1alpha1` envelope, so the editor sees
exactly what the catalog holds.

## Generate the config

    ./demo/mcp-config.sh            # writes .mcp.json and .vscode/mcp.json

Both files are gitignored: the token is short-lived and personal, so it is generated rather
than committed. Re-run when the token expires.

## Try it

Ask the editor "what agents are published in the registry?" — it should answer with the five
Cloud Cart agents and their tags, straight from the catalog.
