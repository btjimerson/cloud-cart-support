# Cloud Cart Support (Agentic) - Claude Code Context

## Project Overview

Registry-governed multi-agent customer service demo. Every agent, MCP server, skill, and
prompt is an artifact in **Solo Enterprise for agentregistry**; **agentgateway** enforces
what those agents may do at runtime; **kagent** and **AWS Bedrock AgentCore** are the two
runtimes they deploy to.

Narrated as a day in the life of an engineer who builds a working multi-agent app without
writing agent code. See `docs/plan.md` for the full design, the verified product surface,
and the demo beats.

## Relationship to `cloud-cart-support-old`

This is a **separate variant**, not a branch of it. This repo took over the
`cloud-cart-support` name; the original now lives at
[`cloud-cart-support-old`](https://github.com/btjimerson/cloud-cart-support-old) (locally at
`~/Foundry/cloud-cart-support-old`). It tells a *migration* story across nine branches
(in-app plumbing moves out to the gateway). This repo tells a *greenfield* story: the agents
were never in the app.

The four MCP services and their seed data were carried over from that repo and will drift.
That is accepted. Do **not** import its nine-branch propagation rule or its version-sync
table -- neither applies here.

## The rule that matters most

**No agent logic in this repo.** No agent classes, no prompt-to-tool wiring in code, no
model clients, no MCP client. If a change would put agent behaviour into Java, it belongs
in a catalog artifact under `registry/` instead. `support-ui` is a chat frontend and a
conversation context store; that is all it is allowed to be.

## Layout

| Path | What it is |
|---|---|
| `services/*` | The four MCP servers. Own their data, expose tools over SSE. Carried over unchanged. |
| `support-ui/` | Chat UI + conversation context + `A2AClient`. No agents, no API keys. |
| `registry/` | **The source of truth.** Artifact manifests applied to agentregistry. |
| `k8s/` | Workloads only -- MCP servers and the frontend. Never agents. |
| `demo/`, `docs/` | Runner and recipe. |

## File Change Checklist

- **Tool added/removed in a `*Tools.java`** → update the MCP server artifact in
  `registry/mcp-servers/`, and any `RuntimeAccessPolicy` in `registry/policies/` that names
  the tool in `mcpTools`. A tool that exists in Java but is not granted is denied at the
  gateway -- which is a demo beat, so make that state deliberate rather than accidental.
- **Prompt or skill content changed** → bump the artifact tag. Consumers pin by tag, so an
  edit without a bump changes nothing at runtime.
- **Agent composition changed** → `registry/agents/`. Never in Java.
- **Version bump** → `.env.example`, `demo/run-demo.sh`, `docs/recipe.md`, `README.md`.
- **New workload** → `k8s/services/`, `k8s/deploy.sh`, `k8s/cleanup.sh`, the matrix in
  `.github/workflows/build-images.yml`, and `k8s/build-images.sh`. Image names in the
  workflow matrix must match the `image:` lines in `k8s/services/*.yaml` exactly.
- **Module moved or renamed** → its `Dockerfile` copies paths that mirror the repo layout,
  because each pom resolves its parent by `relativePath`. Moving a module without updating
  its Dockerfile produces a build that fails only in CI.
- **Anything published to the registry** → `k8s/cleanup.sh` must remove it. Registry state
  lives in Postgres and survives a namespace delete.
- **Demo script change** → mirror in `docs/recipe.md`, and vice versa.

## Environment

- Cluster context: `bjimerson-ai`. Namespace: `agentic-demo`.
- `agentgateway-demo` belongs to the user's other demo -- leave it alone.
- Model provider is **OpenAI**; several models are registered as `Model` artifacts.
- Installed versions: agentgateway `v2026.8.0`, kagent `0.5.4`, agentregistry `v2026.7.1`.
  These are calendar-versioned and much newer than the sibling repo's pins.
- Local JDK is Homebrew **26** at `/opt/homebrew/opt/openjdk`; it is not registered with
  `java_home`, so builds need `JAVA_HOME` set explicitly. The build targets Java 21.
