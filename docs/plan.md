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

**Phase 4 — Catalog published and live. Deployment to kagent is blocked by a product gap.**

*Done 2026-08-13:* Keycloak service accounts created; `kagent-oidc` Secret stored in the
registry; **kagent runtime registered and reporting `Synced` / `SyncOK`**; the full catalog
published — 4 MCP servers, 3 skills, 5 prompts, 5 agents, 3 AccessPolicies, 1
RuntimeAccessPolicy.

**The blocker: a kagent-deployed agent gets no model, and there is no way to give it one.**

Deploying `returns-agent` onto kagent produces a kagent `Agent` CR of type **BYO** whose
entire spec is `image` plus four env vars — `MCP_SERVERS_CONFIG`, `KAGENT_URL`,
`KAGENT_NAME`, `KAGENT_NAMESPACE`. The pod then crash-loops:

```
ValidationError: 1 validation error for AgentConfig
model  Input should be a valid dictionary or object ... input_value=None
```

Two things are missing from that translation, and both matter:

1. **No model.** The adapter never sets `modelConfig` and never translates the Agent
   artifact's `modelProvider`/`modelName`. Ruled out by test: `Model` artifacts are
   **Bedrock-only** (`invalid format: "openai" (known: [bedrock])`), so `DeploymentSpec.modelRef`
   cannot carry an OpenAI model; `runtimeConfig.modelConfig` is ignored; and provider casing
   (`openai` vs `OpenAI`) makes no difference. kagent's own `default-model-config` (OpenAI,
   gpt-4.1-mini) exists and is never referenced.
2. **No instructions and no skills.** Only `mcpServers` survives the translation. The Prompt
   and Skill references — the composition the whole demo is about — do not reach the runtime.

Note the bind: omitting `source.image` fails with *"image must be specified for kagent agent
deployment"*, but supplying one forces type `BYO`, and BYO is precisely the mode where kagent
does not manage model or instructions. There is no declarative path through this adapter in
v2026.7.1.

**Root cause, traced to the bottom.** kagent's `Agent` CRD is `v1alpha2`, where `modelConfig`,
`systemMessage`, and `tools` live under **`spec.declarative`**. `spec.byo` carries only
`deployment`. A BYO agent therefore *structurally cannot* hold a model or an instruction —
kagent generates its `config.json` as `{"model": null, "instruction": ""}` and the app, which
reads the model only from that file, exits on validation. `spec.modelConfig` is rejected as an
unknown field on v1alpha2.

That leaves three paths to a kagent agent, and none is currently open:

| Path | Model? | Status |
|---|---|---|
| **BYO** — what the adapter emits today | No — no field for it | Crash-loops. No injection route: `Model` is Bedrock-only, `runtimeConfig.modelConfig` ignored, `spec.modelConfig` rejected, app reads model only from `config.json` |
| **Declarative** — `modelConfig` + `systemMessage` + `tools` | Yes, and kagent's OpenAI `default-model-config` already exists | **The adapter never emits it.** Supplying `source.image` forces BYO; omitting it errors |
| **Harness** — what `compatibleHarnesses` targets | Yes, via `AgentHarness.modelConfigRef` | Requires an `AgentHarness` whose `substrate` needs an **`ate.dev` WorkerPool**. No `ate.dev` CRDs are installed — this is a separate VM-substrate stack |

Deploying without an image and with `harness: {type: openclaw}` fails at
`resolve harness config: harness image is required: openclaw`, which is the registry looking
for an `AgentHarness` that does not exist.

**So the decision is one of three:**

- **(a)** Treat the missing Declarative path as a product gap and raise it. This is the
  cheapest fix by far and the one that preserves the demo exactly as designed — kagent already
  has the OpenAI ModelConfig sitting there unused.
- **(b)** Install the Agent Substrate (`ate.dev`) stack and use the harness path. Heaviest, but
  it is evidently the path `compatibleHarnesses`, `skills`, and `prompts` were designed for.
- **(c)** Build a registry-aware BYO image that fetches its prompt, skills, and model from the
  registry and writes `config.json` before starting. Keeps "engineers compose, they don't
  build" intact — the platform team builds the harness once — at the cost of maintaining it.

`compatibleHarnesses` is not validated at apply time and the BYO path ignores it, so the
`openclaw` guess was neither right nor wrong.

**AgentCore tested 2026-08-13 — same shape of problem, different words:**

```
agentcore: agent "product-agent" image "ghcr.io/kagent-dev/kagent/app:0.10.0-beta10"
is not an ECR reference and no source repository is set;
AgentCore requires an ECR image or a git repository
```

So the finding generalises, and it is the real headline:

> **Neither adapter deploys a composition. Both require an agent implementation** — kagent
> wants an image (BYO) or a harness; AgentCore wants an ECR image or a git repo it builds
> server-side. A catalog entry made of prompt + skills + MCP servers is not, by itself,
> something either runtime can run.

**This reframes option (c) into the strongest path.** An ECR-hosted, registry-aware harness
image satisfies *both* adapters — AgentCore takes ECR images, and kagent takes any image via
BYO. One harness image, two runtimes, and the 15:30 "one catalog entry, two deployments"
beat works as designed. The harness would, on startup, read its own name from the injected
`KAGENT_NAME`, fetch its Agent artifact from the registry (instructions, skills, model), write
`config.json`, and exec. `MCP_SERVERS_CONFIG` is already injected by the kagent adapter, and
`KAGENT_SKILLS_FOLDER` is already understood by kagent's app.

The demo story survives intact under this option: the *platform team* builds one harness; the
*engineers* still only compose. That is arguably a better story than "no images anywhere",
because it is what a real platform team would actually do.

**RESOLVED 2026-08-13 — the harness works and `returns-agent` is live on kagent.**

`harness/` is kagent's app image plus a startup shim that resolves the agent's own artifact
from the catalog. `kubectl get agents -n kagent` reports `READY=True`, and the agent answers
over A2A. The proof that the whole chain works is *which* answer it gives: asked about the
return window it replies "30 days from the delivery date" with the full condition list — text
that exists only in `returns-eligibility/SKILL.md`, because the policy was deliberately
stripped out of the prompt in Phase 2. Catalog → harness → prompt + skill + MCP servers →
model → A2A, end to end.

Two decisions worth keeping:

**The model routes through agentgateway.** `MODEL_BASE_URL` points at
`agentgateway-proxy.agentgateway-system.svc:8080`, which already has an `openai-primary`
backend and a `/chat` route. It answers chat completions **with no API key from the caller** —
the gateway holds and injects it. So no OpenAI key is stored on the agent, and every LLM call
is under gateway policy and tracing. This is the sibling demo's Step 1 arriving for free.

**One security wart, and it is the registry's to fix.** `DeploymentSpec.env` is
`map[string]string` — a nested `secretRef` is rejected with *"cannot unmarshal object into Go
struct field DeploymentSpec.spec.env of type string"*. So the harness's OIDC client secret sits
in the Deployment as plaintext in the registry's Postgres. The registry redacts its own Secret
values on read (only `status.dataKeys` comes back), so the harness cannot fetch it either.
**Ask for `secretRef` support in deployment env**; until then, treat that client as
demo-only and low-privilege.

**Also confirmed while testing: the shadow-AI beat (16:45) works today, with real data.**
There are 15 `discovered-*` deployments from the connected runtimes — AgentCore agents with
live ARNs, `Ready=True`, `Discovered=True`, annotated
`agentregistry.solo.io/origin: discovered`. They appear as Deployments whose `targetRef` names
an agent that has no catalog entry (`tag: unknown`), which is precisely the "visible, not
interactable, because it did not come through the registry" behaviour that beat calls for. No
build work needed.

`compatibleHarnesses` turned out to be irrelevant on this path: it is not validated at apply
time and the kagent adapter ignores it. The `openclaw` guess was neither right nor wrong.

**End to end as of 2026-08-13.** All five agents are `READY` on kagent and the chat UI answers
through the full chain: browser → `support-ui` → registry A2A proxy → `support-concierge` →
A2A → specialist → MCP tool → domain service, with the model routed through agentgateway.

Three things worth keeping from getting there:

- **The orchestrator's peers come from policy.** The harness builds `remote_agents` by reading
  `RuntimeAccessPolicy` for rules whose `from` is this deployment. Which agents it may call is
  a property of policy, not of the agent artifact, so deriving the list from the rules that
  authorise the calls means the two cannot drift apart.
- **Pin the harness image to a SHA tag, never `:latest`.** The kagent adapter does not set
  `imagePullPolicy: Always`, so a moving tag silently keeps whatever the node already cached.
  A harness change appeared to deploy while the old code kept running — the concierge came up
  `READY` with zero peers and nothing in the logs said why.
- **`support-ui` mints its own tokens** via client-credentials and refreshes a minute early.
  Registry tokens are short-lived, so a pasted token would have the chat failing silently a
  few hours into a demo. Its credentials live in a Kubernetes Secret, not in the deployment.

**Seed data — fixed 2026-08-13.** Order dates were absolute 2024 timestamps, so against a
30-day return window the entire dataset had expired and the returns flow could only answer
"no". The seeder now shifts every date by a constant so the newest lands a day before startup,
preserving the spacing between orders exactly. Verified through the chat UI:

| Persona | Order | State | Answer |
|---|---|---|---|
| CUST-001 | ORD-2024-0001 | delivered 27d ago | **eligible** — offers to generate a label |
| CUST-010 Platinum | ORD-2024-0010 | delivered 44d ago | **denied** under v1, offers store credit instead |
| CUST-008 | ORD-2024-0008 | shipped, not delivered | **not yet** — must be delivered first |

CUST-010 was deliberately re-dated to 44 days so it falls outside the standard window but
inside a 90-day tier exception: that is what makes publishing `returns-eligibility` v2 visibly
change the answer at 14:30. Tests pin these ages so a change that moves them fails rather than
quietly breaking a beat.

A useful accident: denied at 44 days, the agent *volunteers* store credit as an alternative.
That is a natural run-up to the 10:30 beat — it reaches for `issueCredit` on its own, and the
gateway refuses.

## Spike results (2026-08-18)

All three spikes from the developer-flow plan resolved, two of them better than assumed.

**Catalog over MCP — works.** The registry's MCP bridge on port `31313` accepts a plain bearer
token (the client-credentials token from `get-token.sh`), so an IDE needs no interactive OAuth.
It exposes ten catalog tools — `list_agents`, `list_servers`, `list_skills`, `list_deployments`,
the matching `get_*`, plus health and version — each returning a `v1alpha1` envelope.
`demo/mcp-config.sh` generates Claude Code and VS Code config.

**Browser login at the gateway — supported.** ext-auth (0.84.0) parsed a full
`oauth2.oidcAuthorizationCode` AuthConfig and rejected it only for a missing client secret. So
the gateway can run the login and **support-ui needs no auth code**. `keycloak-setup.sh` now
creates a fourth client, `cloudcart-gateway`, for the authorization-code flow.

**Token exchange — already running; nothing to deploy.** The plan assumed an STS had to be
stood up from `STS_BIN_URL`. That binary turns out to be the enterprise-gateway controller
v2.3.2, which the registry downloads when provisioning a *managed gateway in AWS* — consistent
with `GatewaySpec` being AWS-only, and not what the in-cluster path uses. The real STS is
already listening on **port 7777 of the `enterprise-agentgateway` service**:

```
grant_types_supported: ["urn:ietf:params:oauth:grant-type:token-exchange"]
token_endpoint:        …:7777/oauth2/token
jwks_uri:              …:7777/.well-known/jwks.json
token_expiration:      14400
```

A real exchange was performed against it. Given a Keycloak token as `subject_token` it returns a
JWT that **preserves `sub` and `client_id`** while re-issuing under the gateway's own issuer:

| | issuer | sub | other |
|---|---|---|---|
| subject (Keycloak) | `…/realms/solo` | `3549ec9e…` | `Groups: [admins]` |
| exchanged (STS) | `enterprise-agentgateway…:7777` | `3549ec9e…` | `scope: "profile email"` |

**The exchanged token does not carry `Groups`.** Identity survives the exchange; group
membership does not. A beat built on "two users get different answers" therefore needs the
original claims propagated as well (`OBO_CLAIMS_TO_PROPAGATE`), not the exchanged token alone.

`k8s/agentgateway/token-exchange.yaml` holds the policy, validated by server-side dry run. Its
`targetRefs` points at the MCP route until the A2A route exists.

## Phase 5 — Authorization

**The published policy was not enforced, and could not be.** Asked to issue store credit —
a tool `RuntimeAccessPolicy` deliberately withholds — `returns-agent` did it:

> "The $50.00 store credit has been successfully issued to customer CUST-010."

The cause is structural. The kagent adapter hands agents MCP URLs and they connect straight to
the services, so nothing sits in the path to refuse a call. Three separate confirmations that
the catalog had no way to enforce anything:

- **No enforcement point.** `MCP_SERVERS_CONFIG` pointed at `orders-service.agentic-demo.svc`
  directly.
- **kagent's own policy has nothing to bind to.** `accesspolicies.policy.kagent-enterprise.solo.io`
  supports exactly what we want — `action`, `from.subjects`, `targetRef` with `tools` — but
  `targetRef.kind: MCPServer` needs a kagent MCPServer resource, and the BYO path creates none.
  Zero policies existed; the registry synced nothing.
- **The registry cannot drive an in-cluster gateway.** `GatewaySpec` requires `networkId` and
  `subnetId` and carries an AWS config block: the `Gateway` kind provisions a *managed gateway
  in AWS*. There is no way to register the agentgateway running in this cluster, so the
  published `RuntimeAccessPolicy` has no consumer on the kagent path at all.

**Built: MCP now routes through agentgateway** (`k8s/agentgateway/mcp-federation.yaml`). An
`AgentgatewayBackend` federates all four servers behind `/cloudcart/mcp`, on its own prefix so
it does not collide with the `/mcp` route belonging to the other demo. All 19 tools resolve
through it. Three things it required, none obvious:

| Requirement | Symptom when missing |
|---|---|
| `appProtocol: agentgateway.dev/mcp` on the service port | `mcp: no backends configured`, 503 |
| `URLRewrite` stripping the `/cloudcart` prefix | backends see `/cloudcart/mcp`, answer 404 |
| Streamable HTTP instead of SSE | the federation backend speaks streamable to `/mcp` |

That last one surfaced a latent bug: `catalog-service` pinned
`spring-ai-starter-mcp-server-webmvc` **1.0.3** while its three siblings inherited 1.1.2. The
older release has no streamable transport, so it silently ignored `protocol: STREAMABLE` and
kept serving SSE — one federation target 404ing while the rest worked.

**Next, to finish the beat:** point the MCPServer artifacts at the gateway URL so agents go
through it, then write the deny rule. Note the gateway prefixes federated tool names by target
(`orders-service-8080_getOrderStatus`), so policy and any tool allow-list must use the prefixed
form — and the prefix derives from service+port, not from the target `name` in the backend.

**The open question this leaves for the product team.** With `Gateway` being AWS-only, the
11:00 beat as designed — change policy in the registry, gateway enforces, no redeploy — cannot
work on kagent in v2026.7.1. The enforcement we can build lives in agentgateway CRDs, so the
control point is `kubectl`, not the catalog. Ask for either registry-driven in-cluster gateways
or generation of kagent `AccessPolicy` resources from `RuntimeAccessPolicy`.

Still to do: the Claude Code ↔ registry MCP loop, `REQUIRE_CREATE_APPROVAL` via `helm upgrade`,
the persona check, and the topology panel (Phase 6).

**Previously — the credential work, now complete:**

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
