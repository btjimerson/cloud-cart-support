# You are on `demo/start`

This branch is where the demo begins: the Cloud Cart support app, **not yet wired to any
agent**. Everything else is real — the chat UI, the conversation store, the A2A client, the
four MCP services running in the cluster. What is missing is the answer to three questions,
and the catalog is where those answers live.

Run it and the app tells you as much:

    GET  /health   ->  "agent_source": "unconfigured"
    POST /chat     ->  "This app is not wired to an agent yet."

## What to fill in

`support-ui/src/main/resources/application.yml`:

| Value | Where it comes from |
|---|---|
| `base-url` | the agentregistry address |
| `default-runtime` | **Runtimes** in the registry UI — which runtime the agent is deployed to |
| `concierge-agent` | **Catalog → Agents** — which agent this app should talk to |

You can browse the catalog without leaving your editor:

    ./demo/mcp-config.sh          # then ask: "what agents are published in the registry?"

Credentials are not part of this: they come from `.env.local` via
`k8s/create-support-ui-secret.sh`, and the app mints its own short-lived tokens. There is no
API key in this repo.

## Then

    ./demo/local.sh               # run against the cluster and try the personas below

    CUST-001 / ORD-2024-0001   eligible, delivered 27 days ago
    CUST-010 / ORD-2024-0010   denied, delivered 44 days ago (Platinum)
    CUST-008 / ORD-2024-0008   shipped, not yet delivered

`main` is the finished state if you need to compare. The only difference between the two
branches is this app's configuration — no code changes.
