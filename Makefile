-include .env
export

.PHONY: localstack localstack-up localstack-down localstack-logs localstack-ecr-test localstack-test e2e-localstack-eks \
	test test-unit test-integration build fmt vet lint tidy verify-mod verify

TOOLS_DIR := ./hack/tools
TOOLS_BIN_DIR := $(TOOLS_DIR)/bin
GOLANGCI_LINT := $(abspath $(TOOLS_BIN_DIR)/golangci-lint)

$(GOLANGCI_LINT): $(TOOLS_DIR)/go.mod $(TOOLS_DIR)/tools.go
	cd $(TOOLS_DIR); go build -tags=tools -o $(abspath $(TOOLS_BIN_DIR))/golangci-lint github.com/golangci/golangci-lint/v2/cmd/golangci-lint

localstack: localstack-up

localstack-up:
	@if [ "$(notdir $(CONTAINER_ENGINE))" = "podman" ]; then systemctl --user enable --now podman.socket 2>/dev/null || true; fi
	LOCALSTACK_PORT=$(LOCALSTACK_PORT) CONTAINER_ENGINE=$(CONTAINER_ENGINE) ./hack/start-localstack.sh

localstack-down:
	$(CONTAINER_ENGINE) rm -f ecr-creds-sync-localstack 2>/dev/null || true

localstack-logs:
	$(CONTAINER_ENGINE) logs -f ecr-creds-sync-localstack

localstack-ecr-test: localstack-up
	LOCALSTACK_INTEGRATION=1 LOCALSTACK_ENDPOINT=http://127.0.0.1:$(LOCALSTACK_PORT) go test ./internal/controller -run LocalStack

localstack-test: e2e-localstack-eks

e2e-localstack-eks:
	./hack/e2e-localstack-eks.sh

test:
	$(MAKE) test-unit

test-unit:
	go test ./...

test-integration: localstack-test

build:
	go build ./cmd/ecr-creds-sync

fmt:
	go fmt ./...

vet:
	go vet ./...

lint: $(GOLANGCI_LINT)
	$(GOLANGCI_LINT) run --config .golangci.yml --timeout 5m ./...

tidy:
	go mod tidy

verify-mod: tidy
	git diff --exit-code go.mod go.sum

verify: verify-mod

LOCALSTACK_PORT ?= 4566
CONTAINER_ENGINE ?= $(shell command -v podman 2>/dev/null || command -v docker 2>/dev/null)
