# Cloud Cart Support — Registry Edition

Build plan for a **variation** of the Cloud Cart Support demo in which agentregistry is the source of truth for every agent, MCP server, skill, and prompt, and agentgateway is the enforcement point. Narrated as a day in the life of a software engineer building the app.

Sibling to `docs/agentregistry-demo-brief.md` in the [`cloud-cart-support-old`](https://github.com/btjimerson/cloud-cart-support-old) repo, not a replacement. That brief plans a *migration chapter* appended to the existing recipe. This plans a *separate greenfield demo in its own repo*.

**Status:** product surface verified against the live cluster (context `bjimerson-ai`) on 2026-08-12. See §3.

---

## 1. How this differs from the existing demo

The existing recipe (Steps 0–8) is a migration story: *take the plumbing out of the app.* By Step 7 the Java agents are already deleted and replaced with kagent `Agent` CRs — so "remove the Java agents" is not the new material.

The variation is a **greenfield build** story:

> The app was never the place any of this belonged. Watch an engineer build a working multi-agent support system in one day without writing a line of agent code — by composing governed artifacts out of a catalog — and ship it onto Kubernetes with a gateway that decides what it's allowed to do.

| | Existing demo | Registry Edition |
|---|---|---|
| Frame | Migration — before/after per step | Greenfield — one engineer, one workday |
| Arc unit | Capability moved to the gateway | Hour of a workday |
| Protagonist | The platform | The engineer |
| Starting state | A monolith with everything in it | Four backend services another team runs |
| Agent code written | Deleted over 8 steps | Never written |
| Applause moment | "The app got smaller" | "They composed it — and the platform said no" |

## 2. Decisions taken

| Decision | Choice | Rationale |
|---|---|---|
| Location | **Separate repo** (suggested `cloud-cart-registry`) | No inherited 9-branch rule, no version-sync table for steps that don't exist here. Cost: MCP services and seed data duplicated, will drift. Accepted. |
| Engineer loop | **IDE pulls from registry, UI governs** | **Confirmed viable** — the registry ships its own MCP server (§3.2). Claude Code talks to the catalog directly. |
| Visual surface | **Live product UIs + topology panel + diagrams** | Products carry the proof; the panel makes it legible; diagrams carry the narrative. |
| Multi-runtime | **Core — kagent + AgentCore, both first-class** | Hyperscaler runtime integration is what customers relate to. This is a narrative pillar, not an optional Act. See §4.1. |
| Java MCP servers | **Carried over unchanged** | They're the workload, not the agents. Their seed data is what makes the demo deterministic. |

## 3. Verified product surface

Everything below is confirmed from the live install, the Helm-rendered config, and the public OpenAPI document. **Not verified:** the contents of the registry (all artifact endpoints are 401 behind Keycloak) and the UI's specific capabilities — see §9.

### 3.1 It is not CRD-based

agentregistry registers **zero CRDs**. It is a standalone server (`server:v2026.7.1`) backed by **PostgreSQL** for artifacts and **ClickHouse** for telemetry, fronted by a LoadBalancer on three ports:

| Port | Purpose |
|---|---|
| `12121` | UI + REST API (`/v0/...`), OpenAPI at `/openapi.json`, Swagger at `/docs` |
| `21212` | gRPC — agentgateway sync |
| `31313` | **MCP server** (401 without auth) |

Consequence: artifacts are **not** `kubectl apply`-ed. This is a distinct control plane with its own storage, identity, and API.

### 3.2 The IDE loop is a first-class product surface

`AGENT_REGISTRY_MCP_PORT=31313` — the registry exposes itself over MCP. Claude Code connects to the catalog as a tool server: search artifacts, read tool schemas, compose, publish. The "IDE pulls from registry" decision is a supported path, not a workaround.

### 3.3 Publishing is declarative apply

```
POST   /v0/apply?dryRun=true    # multi-doc YAML stream of v1alpha1 resources
DELETE /v0/apply                # same, for teardown
```

`kubectl apply` semantics against the registry, with a real dry-run. A `registry/` directory of YAML manifests is exactly the right shape, and `dryRun` gives the engineer a validate step on camera.

### 3.4 An Agent is literally a composition

```yaml
AgentSpec:
  title, description
  instructions: ResourceRef       # → a Prompt artifact
  skills:       [ResourceRef]     # → Skill artifacts
  mcpServers:   [ResourceRef]     # → MCPServer artifacts
  plugins:      [ResourceRef]     # → Plugin artifacts
  modelName, modelProvider
  source:       image | repository{url, branch, commit, subfolder}
  compatibleHarnesses
```

Every `ResourceRef` carries `kind`, `name`, `namespace`, **`tag`**. Versioning is tag-based like OCI, and each reference pins its own tag. The 09:30 "compose, don't build" beat is the product's own data model, and the 14:30 "skill v2" beat is a tag change on one ref.

`SkillSource` and `AgentSource` resolve from a **Git repo** (`url`/`branch`/`commit`/`subfolder`), so the existing `seed-data/policies/*.md` become Skill artifacts by pointing at the repo path. Repo holds the content; registry holds the version, owner, and consumers.

Artifact types are richer than the brief assumed: **Agents, MCPServers, Skills, Prompts, Models, Plugins, Secrets, Gateways, Runtimes, Deployments**.

### 3.5 Two distinct policy layers — the plan previously conflated these

| | `AccessPolicy` | `RuntimeAccessPolicy` |
|---|---|---|
| Shape | `principals[] + rules[{actions, resources}]` | `rules[{from[], to[]}]` |
| Governs | **Registry RBAC** — who may publish/approve/delete which artifacts | **Runtime traffic** — which agent may call which tool or agent |
| Demo beat | 11:00 approver's authority | 10:30 denial, 11:00 grant |

`ToRef` carries **`mcpTools: []string`** — tool-level granularity, exactly as the brief promised. It also carries `inboundAccess`.

`FromRef` carries **`onBehalfOf`** — delegated user identity propagated through agent calls. Not in the brief; a stronger governance beat than anything currently planned. Worth a dedicated moment.

### 3.6 The registry drives agentgateway

The Helm config ships `AGW_SYNC_BIN_URL` (an `agw-sync` binary), `AGENTGATEWAY_BIN_URL`, and `STS_BIN_URL` (a security token service), with gRPC on 21212. **Registry is the control plane; agentgateway is the enforcement point; the sync between them is a real product mechanism.** Diagram 3 draws an existing pipe, not an aspiration.

### 3.7 Identity, approval, runtimes

- **OIDC** via Keycloak (`.../realms/solo`), `RBAC_ROLE_CLAIM=Groups`, `RBAC_SUPERUSER_ROLE=admins`. Two-persona engineer/approver = two Keycloak users in different groups. **Resolves open question 3.**
- **`REQUIRE_CREATE_APPROVAL=false`** — the approval gate is a real, configurable knob, currently off. The demo turns it on.
- **`ENABLED_RUNTIMES=agentcore,kagent,virtual,foundry,copilotstudio`** — five runtimes. `aws-creds` is already present, so the AgentCore leg is part-built.
- `DeploymentSpec` binds `targetRef` (artifact) to `runtimeRef` (runtime) with `desiredState` — deploy-from-UI, multi-runtime, is a first-class concept.
- `/v0/a2a/sessions/{runtime}/agents/{deploymentName}` — how `support-ui` invokes agents. Runtime-parameterized, so the app's client is runtime-agnostic.
- `/v0/deployments/{name}/logs` — logs available through the API.

### 3.8 UI walkthrough (as `admin-user`, 2026-08-12)

Nav: **Dashboard · Instances · Tracing · Access Policies · Secrets · Catalog · Runtimes · Gateways · Settings**

| View | State | Bearing on the plan |
|---|---|---|
| **Catalog** | **Empty** — 0 agents, 0 MCP servers, 0 skills, 0 prompts | Clean slate. Nothing to clean up, nothing else depends on it. Create buttons exist for all four types, so publishing works from UI *and* `/v0/apply`. |
| **Runtimes** | AgentCore `aws-bedrock` (us-east-1) **Synced** · Foundry **Failed** · Virtual | **AgentCore is already connected and healthy** — resolves open question 7. Foundry's failure is irrelevant to us. |
| | **kagent is NOT registered** | Gap. Must be added in Phase 4 — one form: connection name, kagent-controller URL, namespace, telemetry endpoint, outbound OIDC (issuer/client/secret), optional cloud pod identity. |
| **Add Runtime** | AWS · Kubernetes · Foundry · Copilot Studio | AWS onboards via a generated **CloudFormation template** — a genuinely good visual for the hyperscaler-integration beat. |
| **Access Policies** | Empty; 3-step wizard **Policy → Principals → Rules** | The authorization beat has a real wizard. |
| **Tracing** | First-class view, time-window selector, Input/Output panels | Backed by the registry's own ClickHouse. **No traces exist yet** — see §9. |
| **Dashboard** | Agent Runs / Operations / Token Usage, per-runtime, time-windowed | The cross-runtime "one pane of glass" is built in. |
| **Settings** | Read-only display of env vars | **`REQUIRE_CREATE_APPROVAL` is a Helm value, not a UI toggle.** Turning the approval gate on is a `helm upgrade`, not a click. Plan Phase 4 accordingly. |

The catalog UI surfaces four types (Agents, MCP Servers, Skills, Prompts); the API also exposes Models, Plugins, Secrets, Gateways, Runtimes. Secrets and Gateways have their own nav; Models and Plugins aren't visible in the catalog view.

### 3.9 Version drift from this repo

| Component | Repo `.env.example` | Installed |
|---|---|---|
| agentgateway | `2.2.0-beta.4` | **`v2026.8.0`** |
| kagent | `0.3.11` | **`0.5.4`** |
| agentregistry | — | **`v2026.7.1`** |

Calendar versioning now. The existing recipe is stale against this cluster. The new repo pins to installed versions from day one. New kagent CRDs worth a look: `agentharnesses`, `sandboxagents`, `mcpservers` (alongside `remotemcpservers`), `accesspolicies.policy.kagent-enterprise.solo.io`.

### 3.10 Manifest ground truth (verified by dry-run, 2026-08-12)

Established by submitting deliberately invalid documents to `/v0/apply?dryRun=true` and
reading the validation errors. None of this is in the OpenAPI document.

| Fact | Value |
|---|---|
| `apiVersion` | **`ar.dev/v1alpha1`** |
| Runtime types | **`Kagent`**, **`BedrockAgentCore`** (also Foundry, Virtual, CopilotStudio) |
| `RuntimeAccessPolicy` `from[].kind` | **`Deployment`** or **`Role`** — *not* `Agent` |
| `RuntimeAccessPolicy` `to[].kind` | **`Deployment`** or **`MCPServer`** |
| `ToRef.inboundAccess` | empty or **`GatewayOnly`** |
| `AccessPolicy.principals[].kind` | **`Deployment`** or **`Role`** |
| Default namespace | `default` |

Three consequences that change how this gets built:

**Policy is written against deployments, not catalog artifacts.** `from` takes a `Deployment`
or a `Role`, never an `Agent`. Policy governs running things, and `Role` is the seam where a
rule can be scoped to the end user's identity rather than the agent's — the same seam
`onBehalfOf` uses.

**References do not resolve within a batch.** An Agent that references a Prompt in the *same*
`/v0/apply` request still fails with `referenced resource not found`; the registry resolves
against stored state only. Publishing therefore runs in dependency waves — mcp-servers,
skills, prompts, then agents, then policies — and teardown runs in reverse. `publish.sh`
does this. A corollary worth remembering: a full dry-run against an empty catalog will always
report missing references for agents, because a dry run persists nothing.

**Composition requires a harness.** An Agent that sets `instructions`, `skills`, or `plugins`
must also declare `compatibleHarnesses`, because the registry delivers that content *to a
harness* rather than to a plain declarative runtime. The value is **not validated** — any
string is accepted — so the correct one is not knowable from the API. kagent's
`agentharnesses.kagent.dev` CRD offers backends `openclaw` and `hermes`; the manifests
currently use **`openclaw`**, and this is the single most likely thing to be wrong. Confirm at
first real deploy. Note also that kagent's own `Agent` CRD has `spec.type` of `Declarative`
or `BYO`, and a Declarative kagent agent takes a plain `systemMessage` — so skills and prompts
as *reusable artifacts* only pay off on the harness path. That is the path this demo needs.

### 3.11 Free determinism

`agentgateway-demo` namespace already runs **`mock-llm`** and `mock-llm-broken`. A deterministic LLM and a deliberately broken one — direct mitigation for the stage-variance risk, and `mock-llm-broken` is a ready-made failure-handling beat.

## 4. Artifact catalog

**MCP servers (4)** — owned by backend teams, published independently:

| Artifact | Owner persona | Carries |
|---|---|---|
| `cloudcart-catalog` | Merchandising | read-only |
| `cloudcart-orders` | Fulfillment | **sensitive** — `cancelOrder`, `initiateReturn`, `generateReturnLabel` |
| `cloudcart-customers` | Customer Data | **sensitive** — `issueStoreCredit` |
| `cloudcart-notifications` | Comms | **sensitive** — `sendEmail`, `sendSms`, `escalateToSupervisor` |

**Skills (3)** — sourced from the repo's `seed-data/policies/*.md`, owned by the Policy team:
`returns-eligibility`, `shipping-exceptions`, `warranty-triage`

The strongest reuse story in the demo: the return window is encoded **once**, by the team that owns the policy, and three agents consume it.

**Prompts (5)** — from `prompts/*.txt`, tag-versioned:
`support-concierge`, `order-agent`, `returns-agent`, `complaint-agent`, `product-agent`

**Agents (5)** — compositions:

| Agent | Composes | Reaches |
|---|---|---|
| `support-concierge` | concierge prompt | A2A → four specialists |
| `returns-agent` | returns prompt + `returns-eligibility` | orders, customers |
| `order-agent` | order prompt + `shipping-exceptions` | orders |
| `complaint-agent` | complaint prompt + `warranty-triage` | customers, notifications |
| `product-agent` | product prompt | catalog |

**Policies** — one `RuntimeAccessPolicy` set per environment (`dev` permissive, `prod` capped); `AccessPolicy` defining the engineer and approver roles against Keycloak groups.

### 4.1 Runtime placement — kagent + AgentCore

Hyperscaler runtime integration is the thing most customers see themselves in, so this is a pillar of the demo rather than an optional closing Act.

**What makes it work cleanly** — three verified facts:

- `DeploymentSpec` binds `targetRef` (the artifact) to `runtimeRef` (the runtime). **One catalog entry can carry two Deployments to two runtimes.** That is the entire multi-runtime story in one screen.
- `/v0/a2a/sessions/{runtime}/agents/{deploymentName}` is runtime-parameterized, so `support-ui`'s client is runtime-agnostic. Moving an agent across runtimes is not an application change.
- `RuntimeSpec` carries its own `telemetryEndpoint`. Traces from both runtimes land in the registry's ClickHouse — **one pane of glass across runtimes**, which is the payoff hyperscaler-curious customers actually want and rarely get.

**Placement:**

| Agent | Runtime | Why |
|---|---|---|
| `support-concierge` | kagent | Orchestrator; A2A fan-out and the tightest enforcement path |
| `returns-agent` | kagent | Carries the 10:30 denial — must be bulletproof |
| `order-agent` | kagent | |
| `complaint-agent` | kagent → **AgentCore candidate** | See below |
| `product-agent` | **AgentCore** | Read-only, catalog-only, no sensitive tools. If the AWS leg fails, the core story survives. Framing: the merchandising team runs in their own AWS account. |

**The placement tension, stated plainly.** Risk says put the *safest* agent on the fragile leg — that's `product-agent`, and it's the right call for the baseline. But narrative says the cross-runtime claim only bites when a *sensitive* tool is governed identically on the hyperscaler side. A read-only agent can't demonstrate that.

Recommendation: build `product-agent` on AgentCore first as the proven baseline. Once the leg is stable, evaluate promoting `complaint-agent` (which reaches `sendEmail` and `escalateToSupervisor`) to AgentCore. That upgrade turns "it runs over there too" into "the same tool-level policy stops it over there too" — a materially stronger claim. Decide after Phase 5, not before.

**Cross-runtime beat:** the concierge on kagent calls `product-agent` on AgentCore over A2A, and the A2A hop itself is governed by `RuntimeAccessPolicy`. The enforcement point differs (mesh waypoint vs. managed gateway); the policy model does not.

**Constraints carried from the original brief — all still apply:**

- AgentCore's A2A support is a text-chat compatibility bridge. Invocations are **stateless** — a fresh conversation per call. Fine for request/response across the boundary; not fine for multi-turn state. Keep the AgentCore agent on one-shot interactions.
- AgentCore builds images server-side from GitHub source, and a JVM image is slow. **Nothing on that path happens live.** Pre-bake it.
- Open: whether an AgentCore runtime can bind to a Kubernetes-hosted gateway. If it can, take it — one gateway across both runtimes is a much cleaner story than two enforcement points.

## 5. The day in the life

Eight beats on a clock. Each has one visible moment; a beat without one gets cut.

**Personas:** Priya, platform engineer (Support team). Marcus, approver — separate Keycloak identity, second screen.

**Ticket:** *"Customers can't self-serve returns. Ship a returns capability into support chat this week."*

---

**09:00 — The ticket.** Nothing exists but four backend services other teams run. Priya searches the registry for "returns": finds `cloudcart-orders` published by Fulfillment, and `returns-eligibility`, a skill the Policy team already published. She builds neither, and files no ticket to discover they exist.
→ *Catalog search, owners, tags, consumers.*

**09:30 — Compose, don't build.** In Claude Code, connected to the registry's MCP server, Priya reads the tool schemas inline and composes `returns-agent`: two `mcpServers` refs, one `skills` ref, one `instructions` ref. `POST /v0/apply?dryRun=true` validates it. **Zero agent code** — the entire agent is a manifest of references.
→ *The IDE session; the dry-run passing; the manifest that is the whole agent.*

**10:30 — The platform says no.** Deploy to the dev runtime. The agent reaches for `issueStoreCredit`. agentgateway denies it — at the span, not as a generic error. The point for the room: *listing `cloudcart-customers` in `mcpServers` did not grant every tool on it.* `RuntimeAccessPolicy` scopes to `mcpTools`. Priya misconfigured nothing; default-deny is working.
→ *The denied span and the policy that denied it.*

**11:00 — Request the grant, not a code change.** Priya requests `issueStoreCredit`. Marcus approves in the UI on screen two. `agw-sync` pushes it to the gateway. **No redeploy, no rebuild, no image.** Same query, now succeeds.
→ *Approval on screen two, behavior change on screen one.* **This is the centerpiece.**

**13:00 — The concierge.** Register `support-concierge`, wire A2A to the four specialists. The dependency view shows the whole application as a graph of governed artifacts with ownership boundaries through it. The topology panel shows the same graph live, per turn.
→ *Dependency graph; panel lighting up during a real conversation.*

**14:30 — Someone else's change lands on you.** Policy team publishes `returns-eligibility:v2` — Platinum gets 90 days. Blast radius first: three agents consume this tag. With `REQUIRE_CREATE_APPROVAL=true` it lands pending and deploy is blocked. Approve, re-run as CUST-010 Thomas Brown (Platinum), and the answer changes materially. Roll back by re-pinning the tag, live.
→ *Blast radius before the change; blocked deploy; the answer changing; rollback.*

**15:30 — The other runtime.** Merchandising runs in their own AWS account. Priya adds a **second Deployment** against the *same* `product-agent` catalog entry, `runtimeRef` → AgentCore. No new artifact, no code change, no fork. The concierge calls it over A2A across the runtime boundary, and the A2A hop is governed by the same `RuntimeAccessPolicy` as every in-cluster hop. Both runtimes' traces land in one view.
→ *One catalog entry with two deployments; the cross-runtime A2A hop in a single trace.* **This is the beat hyperscaler-curious customers came for.**

**16:00 — Ship to prod.** Same artifact tags, `prod` `RuntimeAccessPolicy` — tighter caps. One catalog, environment-specific enforcement, across both runtimes.
→ *Identical versions, different policy, different verdict.*

**16:45 — Shadow AI.** Someone `kubectl apply`s a kagent `Agent` that never went through the registry. It appears as discovered and unmanaged: visible, inert, holding no gateway grants.
→ *The ungoverned agent appearing, and doing nothing.*

---

**Candidate additional beat** — `onBehalfOf` (§3.5): the agent acts as the *customer*, not as itself, and the gateway enforces what that customer may do. Strong, and not in the original brief. Slot after 11:00 if it demos cleanly.

Beats 10:30, 11:00, and 15:30 are the demo — governance and multi-runtime. 14:30 and 16:45 are the cuttable ones if time runs short.

## 6. The topology panel

New build work in `support-ui`. Three regions:

- **Catalog (left)** — artifacts in play with tags and owning team, from `/v0/agents`, `/v0/skills`, `/v0/mcpservers`. Static per deploy.
- **Turn (center)** — live flow: agent, A2A hops, tool calls. From the app's own view of `/v0/a2a/sessions/...`.
- **Verdicts (right)** — allowed/denied per tool call with the deciding policy. From traces.

**Degradation is a requirement.** The right column depends on trace correlation, the shakiest link. Losing traces must cost that column and nothing else — the other two render from sources the app controls.

Palette: Solo purple `#290C47` allowed/with, gray `#9DA1BD` denied/without, ink `#151927`, light `#EDEEF7`, Figtree. **No red/green** — per brand, and it stops the denial reading as a failure when it's the product working correctly.

## 7. Diagrams

1. **Build vs. compose** — five agent classes, a registry, a handoff manager, against one composition manifest.
2. **The application as an artifact graph** — dependency DAG with team ownership boundaries. The picture that sells reuse.
3. **Control, runtime, enforcement** — registry → `agw-sync` → agentgateway, with enforcement marked at agent→MCP and agent→agent. Per §3.6 this draws a real pipe.

## 8. Phases

**Phase 0 — Surface discovery. Complete to the limit of an empty catalog** (§3). API, data model, policy layers, identity, runtimes, and UI navigation are confirmed. Three views and the trace-denial rendering can only be verified once artifacts exist — folded into Phases 2 and 3 rather than blocking.

**Phase 1 — Repo bootstrap.** Create the repo. Carry over the four MCP services, seed data, policy markdown, prompts, k8s scripts. Strip all agent Java from `support-ui`. Pin to installed versions (§3.8). Prove the services come up and serve tools.

**Phase 2 — Artifact authoring.** Write `registry/` manifests: 4 MCPServers, 3 Skills, 5 Prompts, 5 Agents. Validate every one with `POST /v0/apply?dryRun=true` before anything is published for real.

**Phase 3 — Baseline runtime. Workloads done; agents outstanding.** **Stabilize before the
registry enters** — isolates registry problems from runtime problems, and is the fallback
demo if the registry leg fails on the day.

*Verified 2026-08-13:* all five workloads deployed to `agentic-demo` and healthy. All **19
MCP tools live and advertised** over a full MCP handshake against each of the four servers.
Every tool granted in `registry/policies/` exists on its server, and exactly two are
deliberately ungranted: `issueCredit` (the 11:00 beat) and `sendSms`. `support-ui` serves at
its LoadBalancer, and `POST /chat` degrades cleanly to a system-attributed message.

Transport detail worth keeping: the servers announce their message endpoint on the SSE
stream as `data:/mcp/message?sessionId=...` — **no space after `data:`**, which will silently
defeat a naive parser.

Still outstanding: no agent is deployed, so nothing answers yet. That needs Phase 4.

**Phase 3b — `support-ui` needs a machine identity.** The A2A client reaches the registry and
gets a clean **HTTP 401**: the network path is fine, but the pod has no credential. The
`agentregistry-token` secret is referenced as `optional: true` and does not exist. This needs
a Keycloak service account for `support-ui` (client-credentials grant), refreshed rather than
a pasted token. Worth noting that this is *on message* rather than an annoyance: even the
frontend has to authenticate to reach an agent.

**Phase 4 — Registry integration. Authored; blocked on two credentials.**

Done and validated locally:
- `registry/runtimes/kagent.yaml` — config keys `kagentUrl` and `namespace`, confirmed from
  the registry UI's own runtime fixtures rather than guessed. Runtime `type` values are
  `BedrockAgentCore`, `Kagent`, `MicrosoftFoundry`, `MicrosoftCopilotStudio`.
- `publish.sh` gained a `runtimes` wave, ordered first — nothing deploys without it.
- `validate.py` knows `Runtime` and `Secret`, and enforces the runtime-type enum.

**Blocker 1 — a Keycloak client for the registry→kagent call.** kagent-controller serves
`/health` anonymously but rejects `/api/agents` with *"Failed to get user ID: no session
found"*, so the runtime connection needs the `oidc` block, which needs a confidential
Keycloak client in realm `solo` plus its secret stored as an agentregistry `Secret`.

**Blocker 2 — a token for `publish.sh`.** Every artifact endpoint is 401. The UI's token is
browser-held and short-lived (4h), so the durable answer is the same as Phase 3b: a
service-account client whose credentials `publish.sh` and `support-ui` both use.

Both resolve with one piece of work: **create service-account clients in Keycloak.** That is
the next action and it needs someone who can log into Keycloak.

Still to do once unblocked: publish the catalog, wire the Claude Code ↔ registry MCP loop,
create Deployments, turn on `REQUIRE_CREATE_APPROVAL` via `helm upgrade` (not a UI toggle),
and confirm `bob` / `admin-user` map onto the engineer / approver personas.

**Phase 5 — Policy set.** The 10:30 denial and 11:00 grant, tuned until both are reliable on repeat. Plus the A2A denial. Record a fallback capture of both.

**Phase 5b — AgentCore leg.** Validate first, build second: confirm the stateless A2A bridge carries a one-shot `product-agent` exchange before anything else is committed. Pre-bake the image — the server-side build from GitHub source is slow and never happens live. Then the second Deployment against the same catalog entry, the cross-runtime A2A hop, and confirm both runtimes' telemetry reaches one view. Decide the `complaint-agent` promotion (§4.1) here, once the leg's stability is known.

**Phase 6 — Topology panel,** including the degradation path. Must render the runtime each agent is deployed to — the multi-runtime story needs to be legible in the app, not only in the registry UI.

**Phase 7 — Diagrams.**

**Phase 8 — Recipe, runner, cleanup.** `docs/recipe.md` mirroring `demo/run-demo.sh`; `cleanup.sh` covering everything created — including published artifacts via `DELETE /v0/apply` and the shadow agent.

Phases 1–3 don't touch the registry and can start now. 4–6 depend on the Phase 0 remainder.

## 9. Risks

| Risk | Severity | Handling |
|---|---|---|
| **Three views still unverified — and each carries a beat.** The catalog is empty, so nothing could be confirmed that only renders with artifacts present: **dependency graph / blast radius** (13:00, 14:30), **shadow-AI discovery** (16:45), **approval workflow** (14:30, needs the Helm flag on) | **High** | Not resolvable by inspection — they need artifacts in the catalog. Re-verify at the end of Phase 2, when the first artifacts exist. Treat those three beats as provisional until then. |
| **A denial's appearance in a trace is unverified** — the 10:30 punchline *is* a trace, and no traces exist yet | **High** | Earliest possible check in Phase 3, before the policy work in Phase 5 is designed around it. Panel degrades. Record a fallback capture. |
| kagent is not registered as a runtime | Low | One form in Phase 4 (§3.8). Called out only because it's easy to assume it's already wired — AgentCore is, kagent isn't. |
| **AgentCore leg is now core, not optional** — a demo-critical beat depends on AWS | **High** | Phase 5b validates the stateless A2A bridge before any build. Pre-baked image, never built live. Recorded fallback for 15:30. If the leg dies on the day, 15:30 is the only beat lost — nothing upstream depends on it. |
| AgentCore A2A is stateless — fresh conversation per call | Medium | Keep the AgentCore agent on one-shot request/response. Never route multi-turn state across the boundary. |
| Two enforcement points (mesh waypoint vs. managed gateway) complicate the "same policy" claim | Medium | Check whether AgentCore can bind to the Kubernetes-hosted gateway (§4.1). If yes, one gateway across both runtimes and the claim gets simpler. |
| Registry has its own Postgres + ClickHouse + OIDC + LB | Medium | More install surface than the existing demo. Budget setup time; `cleanup.sh` must cover registry state, not just Kubernetes. |
| Two identities, two screens | Medium | Keycloak groups resolve the mechanism (§3.7); rehearse the choreography. |
| Repo recipe is stale vs. installed versions | Medium | New repo pins to installed (§3.8). Don't port the old version table. |
| LLM variance on stage | Low–Medium | `mock-llm` already exists (§3.9). Pin model and temperature; keep A2A two tiers deep. |
| Duplicated MCP services drift | Low | Accepted cost of separate-repo. Note in both repos' `CLAUDE.md`. |

## 10. Open questions

1. ~~Keycloak credentials~~ — supplied. Direct access grants are disabled on `solo-ui-frontend` and `ar-backend` is confidential, so API enumeration needs either the `ar-backend` client secret or a browser session. UI walkthrough is the path.
2. ~~Repo name~~ — **resolved:** `cloud-cart-support`.
3. ~~Approver RBAC~~ — **resolved:** Keycloak groups via `RBAC_ROLE_CLAIM` (§3.7). `bob` is a natural fit for the low-privilege engineer persona; `admin-user` for the approver.
4. **Model pinning — partly resolved, one constraint found.** OpenAI is the provider, set on
   each agent via `modelProvider: openai` / `modelName` (free-form strings). But
   **`ModelSpec.provider` only accepts `bedrock`** — the `Model` *artifact* kind cannot
   represent an OpenAI model. So "several models registered as catalog artifacts" is only
   available for Bedrock. Two options, needs a decision:
   **(a)** Register Bedrock `Model` artifacts for the AgentCore leg and leave the kagent side
   on `modelProvider`/`modelName` — the model-governance beat then belongs to the AgentCore
   half of the story, which is arguably where a hyperscaler audience expects it.
   **(b)** Drop the Model-artifact beat and treat model choice as an agent field throughout.
   Currently built as (b), with no `registry/models/` content.
5. ~~Multi-runtime~~ — **resolved:** kagent + AgentCore, both first-class (§4.1).
6. ~~Namespace~~ — **resolved:** new namespace **`agentic-demo`**. `agentgateway-demo` is the user's and stays untouched.
7. ~~Existing AgentCore runtime?~~ — **resolved:** `aws-bedrock` is connected in us-east-1 and **Synced** (§3.8). Phase 5b starts from a working connection.
8. ~~Foundry runtime~~ — **resolved:** leave it. Azure credentials lack permissions; to be tackled later. Not on the demo path.
