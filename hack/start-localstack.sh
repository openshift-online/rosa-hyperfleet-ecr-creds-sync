#!/usr/bin/env bash
set -euo pipefail

CONTAINER_ENGINE="${CONTAINER_ENGINE:-$(command -v podman 2>/dev/null || command -v docker 2>/dev/null)}"
CONTAINER_NAME="ecr-creds-sync-localstack"
PORT="${LOCALSTACK_PORT:-4566}"
HEALTH_URL="http://127.0.0.1:${PORT}/_localstack/health"
HEALTH_TIMEOUT="${LOCALSTACK_HEALTH_TIMEOUT:-60}"
ENGINE_NAME="$(basename "${CONTAINER_ENGINE}")"
SERVICES="ecr,ec2,eks,eks-auth,iam,sts"

if [[ -z "${CONTAINER_ENGINE}" ]]; then
  echo "ERROR: podman or docker is required" >&2
  exit 1
fi

if [[ "${ENGINE_NAME}" == "podman" ]]; then
  systemctl --user enable --now podman.socket 2>/dev/null || true
fi

if [[ -z "${LOCALSTACK_AUTH_TOKEN:-}" ]]; then
  echo "ERROR: LOCALSTACK_AUTH_TOKEN is required for LocalStack 2026.08.0" >&2
  exit 1
fi
IMAGE="localstack/localstack:2026.08.0"
AUTH_ARGS=(-e "LOCALSTACK_AUTH_TOKEN=${LOCALSTACK_AUTH_TOKEN}")

SOCKET_ARGS=(
  -v /var/run/docker.sock:/var/run/docker.sock
  -e DOCKER_HOST=unix:///var/run/docker.sock
  -e DOCKER_SOCK=/var/run/docker.sock
)
NETWORK_ARGS=()
if [[ "${ENGINE_NAME}" == "podman" ]]; then
  PODMAN_SOCKET="${DOCKER_SOCK:-${XDG_RUNTIME_DIR:-}/podman/podman.sock}"
  if [[ ! -S "${PODMAN_SOCKET}" ]]; then
    echo "ERROR: Podman socket not found at ${PODMAN_SOCKET}; start podman.socket first" >&2
    exit 1
  fi
  SOCKET_ARGS=(
    -v "${PODMAN_SOCKET}:/var/run/docker.sock:Z"
    -e "DOCKER_HOST=unix:///var/run/docker.sock"
    -e "DOCKER_SOCK=/var/run/docker.sock"
  )
  NETWORK_ARGS=(--network podman)
fi

wait_healthy() {
  echo "Waiting for LocalStack at ${HEALTH_URL} ..."
  local i=0
  until curl -sf "${HEALTH_URL}" >/dev/null 2>&1; do
    i=$((i + 1))
    if [[ ${i} -ge ${HEALTH_TIMEOUT} ]]; then
      echo "ERROR: LocalStack did not become healthy within ${HEALTH_TIMEOUT}s." >&2
      exit 1
    fi
    sleep 1
  done
  echo "LocalStack is healthy."
}

seed_ecr() {
  "${CONTAINER_ENGINE}" exec "${CONTAINER_NAME}" awslocal ecr create-repository \
    --repository-name rosa/release >/dev/null 2>&1 || true
  echo "LocalStack ECR repository ready: rosa/release"
}

if "${CONTAINER_ENGINE}" inspect "${CONTAINER_NAME}" --format '{{.State.Status}}' 2>/dev/null | grep -q '^running$'; then
  CURRENT_SERVICES="$("${CONTAINER_ENGINE}" inspect "${CONTAINER_NAME}" --format '{{index .Config.Labels "ecr-creds-sync.services"}}' 2>/dev/null || true)"
  CURRENT_RUNTIME="$("${CONTAINER_ENGINE}" inspect "${CONTAINER_NAME}" --format '{{index .Config.Labels "ecr-creds-sync.runtime"}}' 2>/dev/null || true)"
  if [[ "${CURRENT_SERVICES}" == "${SERVICES}" && "${CURRENT_RUNTIME}" == "${ENGINE_NAME}" ]]; then
    echo "LocalStack container '${CONTAINER_NAME}' already running on port ${PORT}."
    wait_healthy
    seed_ecr
    exit 0
  fi
  echo "Recreating LocalStack container to enable services: ${SERVICES}"
fi

"${CONTAINER_ENGINE}" rm -f "${CONTAINER_NAME}" 2>/dev/null || true

echo "Starting ${IMAGE} on 127.0.0.1:${PORT} ..."
"${CONTAINER_ENGINE}" run -d \
  --name "${CONTAINER_NAME}" \
  --label "ecr-creds-sync.services=${SERVICES}" \
  --label "ecr-creds-sync.runtime=${ENGINE_NAME}" \
  -p "127.0.0.1:${PORT}:4566" \
  "${SOCKET_ARGS[@]}" \
  "${NETWORK_ARGS[@]}" \
  --user 0 \
  --privileged \
  -e "SERVICES=${SERVICES}" \
  -e "AWS_DEFAULT_REGION=${AWS_REGION:-us-east-1}" \
  -e "LOCALSTACK_HOST=localhost.localstack.cloud" \
  -e "DEBUG=${LOCALSTACK_DEBUG:-0}" \
  "${AUTH_ARGS[@]}" \
  "${IMAGE}"

wait_healthy
seed_ecr
echo "LocalStack ready on http://127.0.0.1:${PORT}."
echo "Stop with: ${CONTAINER_ENGINE} rm -f ${CONTAINER_NAME}"
