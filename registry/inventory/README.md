# The wider estate

Artifacts owned by *other* teams at Cloud Cart. They exist so the catalog is worth browsing:
a developer arriving at step 3 should have to choose what they need, not find a catalog
containing exactly and only the answer.

These are **catalog-only**. Nothing here is ever deployed, so an unreachable decoy cannot
break the demo — which is also realistic, since a catalog routinely lists things you are not
running. `publish.sh` applies them in the same dependency waves as the app's own artifacts.

| Artifact | Owner | Why it is here |
|---|---|---|
| `cloudcart-inventory` (MCP) | warehouse | Plausible and adjacent — a developer might reasonably wonder if returns needs it |
| `cloudcart-payments` (MCP) | payments | Carries genuinely sensitive tools, so "why didn't you wire this in?" is a good question to be asked |
| `billing-agent` | billing | Another team's agent, already published and versioned |
| `logistics-agent` | warehouse | Same, and consumes the warehouse MCP server |
| `fraud-signals` (skill) | risk | Shows skills are shared across teams, not per-app |
| `warehouse-slotting` (skill) | warehouse | |
