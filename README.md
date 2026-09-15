# ECR credentials sync

This controller replaces the management-cluster Quay pull-secret dependency for HyperShift HostedClusters. It uses the AWS SDK default credential chain, including EKS Pod Identity, to call `ecr:GetAuthorizationToken`.

## Development

Run `go test ./...` and `go build ./cmd/ecr-creds-sync`.

For every `HostedCluster`, it reads `spec.pullSecret.name` and writes a Kubernetes `kubernetes.io/dockerconfigjson` Secret with that name in the HostedCluster namespace. It does not modify the HostedCluster spec. HyperShift already copies that Secret to the HCP namespace as `pull-secret`, where the existing ignition and HCP consumers use it.

## Configuration

- `--ecr-repository` or `ECR_REPOSITORY`: ECR repository URI, including its path.
- `--aws-region` or `AWS_REGION`: AWS region. If omitted, the AWS SDK configuration is used.

The controller refreshes credentials every 10 hours. ECR authorization tokens are valid for 12 hours.

## Pod identity

Create an EKS Pod Identity association (or an equivalent workload identity binding) for the `hypershift/ecr-creds-sync` ServiceAccount with the policy in `config/iam-policy.json`. No AWS access keys are stored in Kubernetes.

Replace the example repository, region, and image in `config/deployment.yaml` before applying `config/rbac.yaml` and `config/deployment.yaml`. Build with `docker build -t ecr-creds-sync .`.
