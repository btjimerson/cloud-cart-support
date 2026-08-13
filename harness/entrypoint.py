#!/usr/bin/env python3
"""Registry-aware startup shim for kagent's agent app.

Why this exists
---------------
Neither runtime adapter deploys a composition. kagent's registry adapter emits a **BYO**
agent, and in kagent's ``v1alpha2`` CRD ``modelConfig`` and ``systemMessage`` live under
``spec.declarative`` -- ``spec.byo`` has only ``deployment``. So kagent renders
``config.json`` as ``{"model": null, "instruction": ""}`` and the app exits on validation.
AgentCore refuses the deployment outright unless the image is an ECR reference.

This shim closes that gap. On startup it reads its own Agent artifact out of agentregistry,
resolves the referenced Prompt and Skills, writes a complete ``config.json``, and then execs
the stock app. The catalog stays the source of truth: nothing about a given agent is baked
into this image, so one harness serves every agent and both runtimes.

What it reads
-------------
``KAGENT_NAME``           the agent to resolve (injected by the kagent adapter)
``AGENT_TAG``             artifact tag, default ``v1``
``AGENTREGISTRY_URL``     registry base URL
``AGENTREGISTRY_TOKEN``   pre-minted token, or supply the OIDC trio below
``OIDC_ISSUER`` / ``OIDC_CLIENT_ID`` / ``OIDC_CLIENT_SECRET``
``MCP_SERVERS_CONFIG``    injected by the kagent adapter; JSON list of {name,type,url}
``MODEL_BASE_URL``        optional; point the model at agentgateway so LLM calls are governed
``MODEL_TEMPERATURE``     optional, default 0.1 -- low, because A2A multiplies LLM variance

Config and skills are written under /tmp because the app's ``/config`` is a read-only Secret
mount on the kagent path.
"""
from __future__ import annotations

import json
import logging
import os
import shutil
import sys
import urllib.error
import urllib.parse
import urllib.request

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO").upper(),
                    format="%(asctime)s harness %(levelname)s %(message)s")
log = logging.getLogger("harness")

CONFIG_DIR = "/tmp/kagent-config"
SKILLS_DIR = "/tmp/kagent-skills"
MOUNTED_CONFIG = "/config"

# Maps a catalog `modelProvider` onto the app's model discriminator. The app accepts several
# providers; the demo standardises on OpenAI, and anything unrecognised is passed through so a
# new provider does not require a harness rebuild.
PROVIDER_TYPES = {
    "openai": "openai",
    "azure_openai": "azure_openai",
    "anthropic": "anthropic",
    "bedrock": "bedrock",
    "gemini": "gemini",
    "ollama": "ollama",
}


def _get(url: str, token: str | None = None, accept_404: bool = False):
    req = urllib.request.Request(url)
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        if accept_404 and e.code == 404:
            return None
        raise RuntimeError(f"GET {url} -> HTTP {e.code}: {e.read().decode()[:300]}") from e


def mint_token() -> str:
    """Use a pre-minted token when given one, otherwise a client-credentials grant."""
    token = os.getenv("AGENTREGISTRY_TOKEN", "").strip()
    if token:
        return token

    issuer = os.environ["OIDC_ISSUER"].rstrip("/")
    body = urllib.parse.urlencode({
        "grant_type": "client_credentials",
        "client_id": os.environ["OIDC_CLIENT_ID"],
        "client_secret": os.environ["OIDC_CLIENT_SECRET"],
    }).encode()
    req = urllib.request.Request(f"{issuer}/protocol/openid-connect/token", data=body)
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read().decode())["access_token"]


def sse_tools_from_env() -> list[dict]:
    """Translate the adapter's MCP_SERVERS_CONFIG into the app's sse_tools.

    The adapter already resolves the agent's mcpServers refs to concrete URLs, so the harness
    does not re-resolve them -- it only reshapes what it was handed. Which *tools* on those
    servers the agent may actually call is not decided here at all: that is the gateway's
    call, from RuntimeAccessPolicy.
    """
    raw = os.getenv("MCP_SERVERS_CONFIG", "").strip()
    if not raw:
        return []
    tools = []
    for server in json.loads(raw):
        url = server.get("url")
        if not url:
            continue
        tools.append({"params": {"url": url}})
        log.info("MCP server %s -> %s", server.get("name", "?"), url)
    return tools


def fetch_skills(agent_spec: dict, base: str, token: str) -> bool:
    """Materialise each referenced Skill as <SKILLS_DIR>/<name>/SKILL.md.

    Skill content lives in a git repo (url/branch/subfolder), so this reads the raw file over
    HTTPS rather than shelling out to git -- the image has no git binary and a full clone
    would be wasted work for one markdown file.
    """
    refs = agent_spec.get("skills") or []
    if not refs:
        return False

    wrote = 0
    for ref in refs:
        name, tag = ref["name"], ref.get("tag", "v1")
        skill = _get(f"{base}/v0/skills/{name}/{tag}", token, accept_404=True)
        if not skill:
            log.warning("skill %s:%s not found in catalog; skipping", name, tag)
            continue
        repo = ((skill.get("spec") or {}).get("source") or {}).get("repository") or {}
        url, branch, sub = repo.get("url"), repo.get("branch", "main"), repo.get("subfolder", "")
        if not url:
            log.warning("skill %s has no repository source; skipping", name)
            continue

        raw = (url.replace("https://github.com/", "https://raw.githubusercontent.com/").rstrip("/")
               + f"/{branch}/{sub.strip('/')}/SKILL.md")
        try:
            with urllib.request.urlopen(raw, timeout=20) as r:
                content = r.read().decode()
        except Exception as e:  # a missing skill degrades the agent; it should not stop it
            log.warning("could not fetch %s: %s", raw, e)
            continue

        dest = os.path.join(SKILLS_DIR, name)
        os.makedirs(dest, exist_ok=True)
        with open(os.path.join(dest, "SKILL.md"), "w") as f:
            f.write(content)
        wrote += 1
        log.info("skill %s:%s materialised from %s", name, tag, raw)

    return wrote > 0


def remote_agents_from_policy(name: str, base: str, token: str) -> list[dict]:
    """Build the orchestrator's A2A peers from RuntimeAccessPolicy.

    The set of agents an orchestrator can delegate to is not a property of the agent artifact
    -- it is a property of policy, and policy is what the gateway enforces at call time. So
    the harness derives the peer list from the same rules that authorise the calls, rather
    than from a separate list that could drift out of agreement with them.
    """
    policies = _get(f"{base}/v0/runtimeaccesspolicies", token, accept_404=True) or {}
    namespace = os.getenv("KAGENT_NAMESPACE", "kagent")
    peers: dict[str, dict] = {}

    for policy in policies.get("items", []):
        for rule in (policy.get("spec") or {}).get("rules", []):
            froms = rule.get("from") or []
            if not any(f.get("kind") == "Deployment" and f.get("name") == name for f in froms):
                continue
            for to in rule.get("to") or []:
                if to.get("kind") != "Deployment" or to.get("name") == name:
                    continue
                peer = to["name"]
                # ADK exposes each peer to the model as a callable, and hyphens are not
                # valid in an identifier, so the tool name is normalised.
                peers[peer] = {
                    "name": peer.replace("-", "_"),
                    "url": f"http://{peer}.{namespace}.svc:8080",
                    "description": "",
                }

    # A description helps the orchestrator route sensibly, so take it from the catalog when
    # the peer has an entry. Missing entries are not fatal.
    for peer, cfg in peers.items():
        agent = _get(f"{base}/v0/agents/{peer}/{os.getenv('AGENT_TAG', 'v1')}", token, accept_404=True)
        if agent:
            spec = agent.get("spec") or {}
            cfg["description"] = spec.get("description") or spec.get("title") or ""

    for cfg in peers.values():
        log.info("remote agent %s -> %s", cfg["name"], cfg["url"])
    return list(peers.values())


def build_config(agent_spec: dict, instruction: str, remote_agents: list[dict]) -> dict:
    provider = (agent_spec.get("modelProvider") or "openai").lower()
    model = {
        "type": PROVIDER_TYPES.get(provider, provider),
        "model": agent_spec.get("modelName") or "gpt-4.1",
        "temperature": float(os.getenv("MODEL_TEMPERATURE", "0.1")),
    }
    # Routing the model through agentgateway is what puts LLM traffic under the same policy
    # and tracing as everything else. Optional so the harness still runs without the gateway.
    base_url = os.getenv("MODEL_BASE_URL", "").strip()
    if base_url:
        model["base_url"] = base_url

    return {
        "model": model,
        "description": agent_spec.get("description") or agent_spec.get("title") or "",
        "instruction": instruction,
        "sse_tools": sse_tools_from_env(),
        "remote_agents": remote_agents,
        "stream": False,
    }


def write_agent_card(name: str, agent_spec: dict) -> None:
    """Prefer the card kagent generated; synthesise one when it is absent (AgentCore)."""
    src = os.path.join(MOUNTED_CONFIG, "agent-card.json")
    dst = os.path.join(CONFIG_DIR, "agent-card.json")
    if os.path.exists(src):
        shutil.copyfile(src, dst)
        log.info("agent-card.json taken from the mounted config")
        return

    description = agent_spec.get("description") or agent_spec.get("title") or name
    card = {
        "name": name,
        "description": description,
        "url": os.getenv("AGENT_CARD_URL", f"http://{name}:8080"),
        "version": os.getenv("AGENT_TAG", "v1"),
        "protocolVersion": "0.3.0",
        "capabilities": {"streaming": False, "pushNotifications": False},
        "defaultInputModes": ["text/plain"],
        "defaultOutputModes": ["text/plain"],
        "skills": [],
    }
    with open(dst, "w") as f:
        json.dump(card, f)
    log.info("agent-card.json synthesised")


def main() -> None:
    name = os.getenv("KAGENT_NAME") or os.getenv("AGENT_NAME")
    if not name:
        sys.exit("KAGENT_NAME (or AGENT_NAME) must be set: the harness resolves itself by name")

    base = os.environ["AGENTREGISTRY_URL"].rstrip("/")
    tag = os.getenv("AGENT_TAG", "v1")

    os.makedirs(CONFIG_DIR, exist_ok=True)
    os.makedirs(SKILLS_DIR, exist_ok=True)

    token = mint_token()
    log.info("resolving agent %s:%s from %s", name, tag, base)
    agent = _get(f"{base}/v0/agents/{name}/{tag}", token)
    spec = agent.get("spec") or {}

    instruction = ""
    ref = spec.get("instructions")
    if ref:
        prompt = _get(f"{base}/v0/prompts/{ref['name']}/{ref.get('tag', 'v1')}", token, accept_404=True)
        if prompt:
            instruction = (prompt.get("spec") or {}).get("content", "")
            log.info("instruction from prompt %s:%s (%d chars)", ref["name"], ref.get("tag", "v1"), len(instruction))
        else:
            log.warning("prompt %s not found; starting with an empty instruction", ref["name"])

    if fetch_skills(spec, base, token):
        os.environ["KAGENT_SKILLS_FOLDER"] = SKILLS_DIR

    peers = remote_agents_from_policy(name, base, token)
    config = build_config(spec, instruction, peers)
    with open(os.path.join(CONFIG_DIR, "config.json"), "w") as f:
        json.dump(config, f)
    write_agent_card(name, spec)

    log.info("config ready: model=%s/%s tools=%d peers=%d skills=%s",
             config["model"]["type"], config["model"]["model"],
             len(config["sse_tools"]), len(config["remote_agents"]),
             os.getenv("KAGENT_SKILLS_FOLDER", "none"))

    argv = ["kagent-adk", "static", "--filepath", CONFIG_DIR,
            "--host", os.getenv("HOST", "0.0.0.0"), "--port", os.getenv("PORT", "8080")]
    log.info("exec: %s", " ".join(argv))
    os.execvp("/.kagent/.venv/bin/kagent-adk", argv)


if __name__ == "__main__":
    main()
