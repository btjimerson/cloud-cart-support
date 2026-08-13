# Registry-aware harness: kagent's agent app plus a startup shim that resolves the agent's
# prompt, skills and model from agentregistry before handing over.
#
# Built on kagent's published app image rather than reimplementing the agent runtime -- the
# only thing missing on the BYO path is configuration, and that is all this adds.
#
# The same image serves both runtimes: kagent accepts any image via BYO, and AgentCore accepts
# an ECR reference, so publish it to both GHCR and ECR.
ARG KAGENT_APP_VERSION=0.10.0-beta10
FROM ghcr.io/kagent-dev/kagent/app:${KAGENT_APP_VERSION}

# The base image runs as nonroot 65532 and mounts /config read-only, so the shim writes the
# rendered config under /tmp instead.
COPY harness/entrypoint.py /harness/entrypoint.py

USER 65532:65532
EXPOSE 8080

ENTRYPOINT ["python3", "/harness/entrypoint.py"]
