#!/usr/bin/env bash
set -euo pipefail

# Builds the five demo images locally.
#
# Pushing is deliberately opt-in and guarded. Pushing an image name to GHCR *before* CI has
# ever created that package leaves an orphan package the workflow cannot then write to --
# the run fails with a write_package denial, and the fix is to delete the package and let CI
# recreate it. So: let the workflow create each package once, and only then push by hand.
#
# Usage:
#   ./build-images.sh              # build only
#   ./build-images.sh --push       # build and push (refuses if the package does not exist)

REGISTRY="${REGISTRY:-ghcr.io/btjimerson/cloud-cart-support}"
OWNER="${OWNER:-btjimerson}"
PUSH=false
[ "${1:-}" = "--push" ] && PUSH=true

cd "$(dirname "$0")/.."

declare -a IMAGES=(
  "catalog-service:services/catalog-service/Dockerfile"
  "orders-service:services/orders-service/Dockerfile"
  "customers-service:services/customers-service/Dockerfile"
  "notifications-service:services/notifications-service/Dockerfile"
  "support-ui:support-ui/Dockerfile"
)

package_exists() { # $1 = image name
  gh api "user/packages/container/$(printf '%s' "cloud-cart-support/$1" | sed 's|/|%2F|g')" \
    >/dev/null 2>&1
}

for entry in "${IMAGES[@]}"; do
  name="${entry%%:*}"
  dockerfile="${entry#*:}"

  echo "==> Building ${name}..."
  docker build -t "${REGISTRY}/${name}:latest" -f "${dockerfile}" .

  if [ "$PUSH" = true ]; then
    if package_exists "$name"; then
      echo "==> Pushing ${name}..."
      docker push "${REGISTRY}/${name}:latest"
    else
      echo "!!! Refusing to push ${name}: no GHCR package exists for it yet." >&2
      echo "    Let .github/workflows/build-images.yml create it first (push to main or run" >&2
      echo "    the workflow manually), then re-run this with --push." >&2
    fi
  fi
done

echo ""
if [ "$PUSH" = true ]; then
  echo "==> Done."
else
  echo "==> Built locally. Nothing was pushed; CI publishes these on push to main."
fi
