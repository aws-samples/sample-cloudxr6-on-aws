#!/bin/bash
set -euo pipefail

# CloudXR 6 on AWS — Proxy Container Build Script
#
# Builds the proxy container image locally. Provided so the proxy source and its
# build are fully inspectable.
#
# Running this is not part of the deployment flow: cloudformation.yaml references a
# pre-built image that ECS pulls automatically, so a standard deployment never needs
# to build the proxy.
#
# Build it if you've modified the proxy source. What you do with the resulting image
# — push it to a registry, run it locally, inspect it — is up to you. To deploy your
# own build, publish it and set PROXY_IMAGE=<your-image-uri> in config.env, then run
# deploy.sh. No template edit is needed.
#
# The image is built for linux/amd64 because the ECS task definition targets x86_64.
#
# Prerequisites:
#   - Docker with buildx (included in Docker Desktop)
#
# Usage:
#   ./build-proxy.sh            # builds cloudxr-proxy:local
#   ./build-proxy.sh mytag      # builds cloudxr-proxy:mytag

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'
NC='\033[0m'
log() { echo -e "${GREEN}[build-proxy]${NC} $1"; }

TAG="${1:-local}"
IMAGE="cloudxr-proxy:$TAG"

log "Building $IMAGE (linux/amd64)..."
docker buildx build --platform linux/amd64 --load -t "$IMAGE" "$SCRIPT_DIR/"

log "Build complete: $IMAGE"
log ""
log "Verify it starts:"
log "  docker run --rm -p 8080:8080 -e AWS_REGION=us-west-2 \\"
log "    -e COGNITO_USER_POOL_ID=dummy -e COGNITO_APP_CLIENT_ID=dummy $IMAGE"
log "  curl http://localhost:8080/health"
