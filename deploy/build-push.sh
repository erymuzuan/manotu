#!/usr/bin/env bash
# Builds the Gimano images (api, worker, importer, backoffice) from this git checkout and pushes them to ACR.
# Linux equivalent of deploy/build-push.ps1 (e.g. on 172.30.30.150).
#   deploy/build-push.sh myhiro.azurecr.io [tag]      # tag defaults to the git short sha; also tags :latest
#   DRY_RUN=1 deploy/build-push.sh myhiro.azurecr.io  # print what would run
# Log in first (never in this script): `az acr login --name myhiro` or `docker login myhiro.azurecr.io`.
# Prefix with sudo if your user isn't in the docker group (sudo -E keeps DRY_RUN).
set -euo pipefail
REGISTRY="${1:?usage: build-push.sh <registry>.azurecr.io [tag]}"
REGISTRY="${REGISTRY%/}"
cd "$(git rev-parse --show-toplevel)"
TAG="${2:-$(git rev-parse --short HEAD)}"
REV="$(git rev-parse HEAD)"
run() { if [[ "${DRY_RUN:-}" == "1" ]]; then echo "+ $*"; else "$@"; fi; }
[[ -z "$(git status --porcelain -- backend deploy data/moderation)" ]] || echo "warning: uncommitted changes; the image won't match tag $TAG" >&2

for img in api worker importer backoffice; do
  repo="$REGISTRY/gimano-$img"
  run docker build --pull -f "deploy/Dockerfile.$img" -t "$repo:$TAG" -t "$repo:latest" --label "org.opencontainers.image.revision=$REV" .
  run docker push "$repo:$TAG"
  run docker push "$repo:latest"
  if [[ "${DRY_RUN:-}" != "1" ]]; then
    printf '%-16s %-10s %s\n' "gimano-$img" "$TAG" "$(docker inspect --format '{{index .RepoDigests 0}}' "$repo:$TAG")"
  fi
done
echo "Set TAG=$TAG in deploy/.env.prod, then pull + up -d (see deploy/PRODUCTION.md)."
