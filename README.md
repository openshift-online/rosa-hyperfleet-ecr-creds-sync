# ECR credentials sync

This controller replaces the management-cluster Quay pull-secret dependency for HyperShift HostedClusters. It uses the AWS SDK default credential chain, including EKS Pod Identity, to call `ecr:GetAuthorizationToken`.

## Development

Run `go test ./...` and `go build ./cmd/ecr-creds-sync`.

### LocalStack development

LocalStack for AWS 4.10 added EKS Pod Identity and EKS Auth emulation. With an Ultimate account, set `LOCALSTACK_AUTH_TOKEN` and start the development services:

```bash
export LOCALSTACK_AUTH_TOKEN=...
make localstack-up
```

The compose stack enables ECR, EKS, EKS Auth, IAM, and STS and provisions the `rosa/release` repository. The LocalStack EKS provider and credential webhook can then be used for a Pod Identity development cluster according to the [LocalStack EKS documentation](https://docs.localstack.cloud/aws/services/eks/). This is preferable to pretending a kind node has EKS Pod Identity.

For a controller process running outside the emulated cluster, point the AWS SDK at LocalStack explicitly:

```bash
AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
ECR_REPOSITORY=000000000000.dkr.ecr.us-east-1.localhost.localstack.cloud/rosa/release \
AWS_REGION=us-east-1 AWS_ENDPOINT_URL=http://localhost:4566 \
go run ./cmd/ecr-creds-sync
```

Run the LocalStack API smoke test with `make localstack-test`. It is skipped during the normal test suite unless `LOCALSTACK_INTEGRATION=1` is set.

For every `HostedCluster`, it reads `spec.pullSecret.name` and writes a Kubernetes `kubernetes.io/dockerconfigjson` Secret with that name in the HostedCluster namespace. It does not modify the HostedCluster spec. HyperShift already copies that Secret to the HCP namespace as `pull-secret`, where the existing ignition and HCP consumers use it.

## Configuration

- `--ecr-repository` or `ECR_REPOSITORY`: ECR repository URI, including its path.
- `--aws-region` or `AWS_REGION`: AWS region. If omitted, the AWS SDK configuration is used.
- `--aws-endpoint-url` or `AWS_ENDPOINT_URL`: optional endpoint override for LocalStack and other AWS emulators; leave unset in production.

The controller refreshes credentials every 10 hours. ECR authorization tokens are valid for 12 hours.

## Pod identity

Create an EKS Pod Identity association (or an equivalent workload identity binding) for the `hypershift/ecr-creds-sync` ServiceAccount with the policy in `config/iam-policy.json`. No AWS access keys are stored in Kubernetes.

Replace the example repository, region, and image in `config/deployment.yaml` before applying `config/rbac.yaml` and `config/deployment.yaml`. Build with `docker build -t ecr-creds-sync .`.
