.PHONY: localstack-up localstack-down localstack-logs localstack-test test build

localstack-up:
	docker compose -f docker-compose.localstack.yaml up -d

localstack-down:
	docker compose -f docker-compose.localstack.yaml down

localstack-logs:
	docker compose -f docker-compose.localstack.yaml logs -f localstack

localstack-test: localstack-up
	LOCALSTACK_INTEGRATION=1 go test ./internal/controller -run LocalStack

test:
	go test ./...

build:
	go build ./cmd/ecr-creds-sync
