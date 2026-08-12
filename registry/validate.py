#!/usr/bin/env python3
"""Validate registry manifests against agentregistry's OpenAPI schema.

Checks YAML syntax, required fields, unknown fields, enum values, and that every
ResourceRef points at a manifest that actually exists in this directory.

This is a local pre-flight, not a substitute for the registry's own validation: it cannot
see what is already published, and it does not check repository sources resolve. Run
`publish.sh --dry-run` against a live registry for that.

Usage:
    python3 validate.py [--spec openapi.json]

The spec is fetched from $AGENTREGISTRY_URL/openapi.json when not supplied.
"""
import argparse
import json
import os
import pathlib
import sys
import urllib.request

import yaml

WAVES = ["mcp-servers", "skills", "prompts", "agents", "policies"]

# Enum constraints the OpenAPI document does not express, recovered from the live API by
# submitting deliberately invalid values to /v0/apply?dryRun=true.
EXTRA_ENUMS = {
    ("FromRef", "kind"): ["Deployment", "Role"],
    ("ToRef", "kind"): ["Deployment", "MCPServer"],
    ("ToRef", "inboundAccess"): ["", "GatewayOnly"],
    ("Principal", "kind"): ["Deployment", "Role"],
    ("ResourceRef", "kind"): ["Agent", "MCPServer", "Skill", "Prompt", "Plugin", "Model"],
}

KIND_TO_SPEC = {
    "MCPServer": "MCPServerSpec",
    "Skill": "SkillSpec",
    "Prompt": "PromptSpec",
    "Agent": "AgentSpec",
    "Model": "ModelSpec",
    "AccessPolicy": "AccessPolicySpec",
    "RuntimeAccessPolicy": "RuntimeAccessPolicySpec",
}

API_VERSION = "ar.dev/v1alpha1"


def load_spec(path_or_url):
    if path_or_url and os.path.exists(path_or_url):
        return json.load(open(path_or_url))
    base = os.environ.get("AGENTREGISTRY_URL", "http://localhost:12121").rstrip("/")
    with urllib.request.urlopen(f"{base}/openapi.json", timeout=15) as r:
        return json.load(r)


def is_type(prop, wanted):
    """True if the property admits `wanted`.

    OpenAPI 3.1 expresses a nullable array as {"type": ["array", "null"]}, so a plain
    equality check silently skips every optional list -- which is most of this schema.
    """
    t = prop.get("type")
    return t == wanted or (isinstance(t, list) and wanted in t)


def check_object(schemas, schema_name, value, path, errors):
    schema = schemas.get(schema_name)
    if schema is None or not isinstance(value, dict):
        return
    props = schema.get("properties") or {}
    required = set(schema.get("required") or [])

    for key in required:
        if key not in value:
            errors.append(f"{path}: missing required field '{key}'")

    for key, val in value.items():
        if key not in props:
            errors.append(f"{path}: unknown field '{key}' (not in {schema_name})")
            continue
        prop = props[key]
        child = f"{path}.{key}"

        enum = prop.get("enum") or EXTRA_ENUMS.get((schema_name, key))
        if enum and isinstance(val, str) and val not in enum:
            errors.append(f"{child}: '{val}' not one of {enum}")

        if is_type(prop, "array") and isinstance(val, list):
            item_name = (prop.get("items") or {}).get("$ref", "").split("/")[-1]
            for i, entry in enumerate(val):
                if item_name and isinstance(entry, dict):
                    check_object(schemas, item_name, entry, f"{child}[{i}]", errors)
        elif "$ref" in prop and isinstance(val, dict):
            check_object(schemas, prop["$ref"].split("/")[-1], val, child, errors)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--spec", default=None)
    args = ap.parse_args()

    here = pathlib.Path(__file__).parent
    schemas = load_spec(args.spec)["components"]["schemas"]

    docs = []       # (file, doc)
    declared = set()  # (kind, name)
    errors = []

    for wave in WAVES:
        for f in sorted((here / wave).glob("*.yaml")):
            try:
                loaded = list(yaml.safe_load_all(f.read_text()))
            except yaml.YAMLError as e:
                errors.append(f"{f.relative_to(here)}: YAML parse error: {e}")
                continue
            for doc in loaded:
                if doc is None:
                    continue
                docs.append((f.relative_to(here), doc))
                kind, meta = doc.get("kind"), doc.get("metadata") or {}
                if kind and meta.get("name"):
                    declared.add((kind, meta["name"]))

    for f, doc in docs:
        kind = doc.get("kind")
        name = (doc.get("metadata") or {}).get("name", "?")
        where = f"{f}[{kind}/{name}]"

        if doc.get("apiVersion") != API_VERSION:
            errors.append(f"{where}: apiVersion is '{doc.get('apiVersion')}', expected '{API_VERSION}'")
        if kind not in KIND_TO_SPEC:
            errors.append(f"{where}: unknown kind")
            continue

        check_object(schemas, "ObjectMeta", doc.get("metadata") or {}, f"{where}.metadata", errors)
        check_object(schemas, KIND_TO_SPEC[kind], doc.get("spec") or {}, f"{where}.spec", errors)

        spec = doc.get("spec") or {}

        # An agent composing instructions/skills/plugins must declare compatibleHarnesses.
        # The registry rejects this at apply time; catching it here saves a round trip.
        if kind == "Agent":
            composes = any(spec.get(k) for k in ("instructions", "skills", "plugins"))
            if composes and not spec.get("compatibleHarnesses"):
                errors.append(f"{where}: composes instructions/skills/plugins but declares no compatibleHarnesses")

        # Every ResourceRef must point at something this directory actually defines.
        for key in ("instructions", "skills", "mcpServers", "plugins"):
            val = spec.get(key)
            refs = val if isinstance(val, list) else ([val] if isinstance(val, dict) else [])
            for ref in refs:
                target = (ref.get("kind"), ref.get("name"))
                if target not in declared:
                    errors.append(f"{where}.spec.{key}: references {target[0]}/{target[1]}, which is not defined here")

    print(f"checked {len(docs)} documents across {len(WAVES)} waves")
    if errors:
        print(f"\n{len(errors)} problem(s):\n")
        for e in errors:
            print(f"  - {e}")
        return 1
    print("all manifests valid")
    return 0


if __name__ == "__main__":
    sys.exit(main())
