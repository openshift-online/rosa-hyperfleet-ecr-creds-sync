.PHONY: localstack localstack-up localstack-down localstack-logs localstack-test test build

localstack: localstack-up

localstack-up:
	LOCALSTACK_PORT=$(LOCALSTACK_PORT) CONTAINER_ENGINE=$(CONTAINER_ENGINE) ./hack/start-localstack.sh

localstack-down:
	$(CONTAINER_ENGINE) rm -f ecr-creds-sync-localstack 2>/dev/null || true

localstack-logs:
	$(CONTAINER_ENGINE) logs -f ecr-creds-sync-localstack

localstack-test: localstack-up
	LOCALSTACK_INTEGRATION=1 LOCALSTACK_ENDPOINT=http://127.0.0.1:$(LOCALSTACK_PORT) go test ./internal/controller -run LocalStack

test:
	go test ./...

build:
	go build ./cmd/ecr-creds-sync

LOCALSTACK_PORT ?= 4566
CONTAINER_ENGINE ?= $(shell command -v podman 2>/dev/null || command -v docker 2>/dev/null)
