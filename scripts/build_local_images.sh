#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "==> Construyendo control_plane"
docker build \
  -f deploy/docker/control_plane.Dockerfile \
  -t deceptionmesh-control-plane:local \
  .

echo
echo "==> Construyendo sensor_agent"
docker build \
  -f deploy/docker/sensor_agent.Dockerfile \
  -t deceptionmesh-sensor-agent:local \
  .

echo
echo "Imágenes locales listas:"
docker image ls | grep deceptionmesh || true