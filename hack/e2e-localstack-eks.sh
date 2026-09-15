#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export AWS_REGION="${AWS_REGION:-us-east-1}"
export LOCALSTACK_ENDPOINT="${LOCALSTACK_ENDPOINT:-http://127.0.0.1:4566}"
export KUBECONFIG="${KUBECONFIG:-${ROOT_DIR}/.local/ecr-creds-sync.kubeconfig}"
# LocalStack accepts these conventional dummy credentials. Keep the E2E path
# independent from any real AWS profile and prevent metadata lookups.
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_EC2_METADATA_DISABLED="true"
CLUSTER_NAME="${EKS_CLUSTER_NAME:-ecr-creds-sync}"
IMAGE_TAG="${IMAGE_TAG:-dev}"
ACCOUNT_ID="000000000000"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.localhost.localstack.cloud:4566"
IMAGE="${REGISTRY}/ecr-creds-sync:${IMAGE_TAG}"
HYPERSHIFT_DIR="${HYPERSHIFT_DIR:-${ROOT_DIR}/../hypershift}"
CONTAINER_ENGINE="${CONTAINER_ENGINE:-$(command -v podman 2>/dev/null || command -v docker 2>/dev/null)}"

if [[ -z "${CONTAINER_ENGINE}" ]]; then
  echo "ERROR: podman or docker is required" >&2
  exit 1
fi
if [[ ! -d "${HYPERSHIFT_DIR}" ]]; then
  echo "ERROR: HyperShift checkout not found at ${HYPERSHIFT_DIR}; set HYPERSHIFT_DIR" >&2
  exit 1
fi

aws_local() {
  if command -v lstk >/dev/null 2>&1; then
    lstk aws "$@"
  elif command -v awslocal >/dev/null 2>&1; then
    awslocal "$@"
  else
    aws --endpoint-url "${LOCALSTACK_ENDPOINT}" "$@"
  fi
}

role() {
  local name="$1" trust="$2"
  aws_local iam get-role --role-name "${name}" >/dev/null 2>&1 || \
    aws_local iam create-role --role-name "${name}" --assume-role-policy-document "${trust}" >/dev/null
}

mkdir -p "$(dirname "${KUBECONFIG}")"
"${ROOT_DIR}/hack/start-localstack.sh"

CLUSTER_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"eks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
NODE_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
POD_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"pods.eks.amazonaws.com"},"Action":["sts:AssumeRole","sts:TagSession"]}]}'
ECR_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"ecr:GetAuthorizationToken","Resource":"*"}]}'

role ecr-creds-sync-eks-role "${CLUSTER_TRUST}"
role ecr-creds-sync-node-role "${NODE_TRUST}"
role ecr-creds-sync-pod-role "${POD_TRUST}"
aws_local iam put-role-policy --role-name ecr-creds-sync-pod-role --policy-name ecr-auth --policy-document "${ECR_POLICY}"

VPC_ID="$(aws_local ec2 create-vpc --cidr-block 10.42.0.0/16 --query 'Vpc.VpcId' --output text 2>/dev/null || true)"
if [[ -z "${VPC_ID}" || "${VPC_ID}" == "None" ]]; then
  VPC_ID="$(aws_local ec2 describe-vpcs --query 'Vpcs[0].VpcId' --output text)"
fi
SUBNET_A="$(aws_local ec2 create-subnet --vpc-id "${VPC_ID}" --cidr-block 10.42.1.0/24 --availability-zone "${AWS_REGION}a" --query 'Subnet.SubnetId' --output text)"
SUBNET_B="$(aws_local ec2 create-subnet --vpc-id "${VPC_ID}" --cidr-block 10.42.2.0/24 --availability-zone "${AWS_REGION}b" --query 'Subnet.SubnetId' --output text)"

if ! aws_local eks describe-cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1; then
  aws_local eks create-cluster --name "${CLUSTER_NAME}" \
    --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/ecr-creds-sync-eks-role" \
    --resources-vpc-config "{\"subnetIds\":[\"${SUBNET_A}\",\"${SUBNET_B}\"]}" >/dev/null
fi
aws_local eks wait cluster-active --name "${CLUSTER_NAME}"

if ! aws_local eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" --nodegroup-name workers >/dev/null 2>&1; then
  aws_local eks create-nodegroup --cluster-name "${CLUSTER_NAME}" --nodegroup-name workers \
    --node-role "arn:aws:iam::${ACCOUNT_ID}:role/ecr-creds-sync-node-role" \
    --subnets "${SUBNET_A}" "${SUBNET_B}" --scaling-config desiredSize=1 >/dev/null
fi
aws_local eks wait nodegroup-active --cluster-name "${CLUSTER_NAME}" --nodegroup-name workers

aws_local eks create-pod-identity-association --cluster-name "${CLUSTER_NAME}" \
  --namespace hypershift --service-account ecr-creds-sync \
  --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/ecr-creds-sync-pod-role" >/dev/null 2>&1 || true

export KUBECONFIG
if command -v lstk >/dev/null 2>&1; then
  lstk aws eks update-kubeconfig --name "${CLUSTER_NAME}" >/dev/null
else
  aws_local eks update-kubeconfig --name "${CLUSTER_NAME}" >/dev/null
fi

aws_local ecr create-repository --repository-name ecr-creds-sync >/dev/null 2>&1 || true
"${CONTAINER_ENGINE}" build -t "${IMAGE}" "${ROOT_DIR}"
aws_local ecr get-login-password | "${CONTAINER_ENGINE}" login --username AWS --password-stdin "${REGISTRY}"
"${CONTAINER_ENGINE}" push "${IMAGE}"

kubectl create namespace hypershift --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${ROOT_DIR}/config/rbac.yaml"
kubectl apply -f "${HYPERSHIFT_DIR}/api/hypershift/v1beta1/zz_generated.featuregated-crd-manifests/hostedclusters.hypershift.openshift.io/AAA_ungated.yaml"
kubectl apply -f "${ROOT_DIR}/config/deployment.yaml"
kubectl -n hypershift set image deployment/ecr-creds-sync controller="${IMAGE}"
kubectl -n hypershift set env deployment/ecr-creds-sync \
  ECR_REPOSITORY="${REGISTRY}/rosa/release" AWS_REGION="${AWS_REGION}"
kubectl -n hypershift rollout status deployment/ecr-creds-sync --timeout=180s

kubectl create namespace clusters --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f - <<'EOF'
apiVersion: hypershift.openshift.io/v1beta1
kind: HostedCluster
metadata:
  name: ecr-test
  namespace: clusters
spec:
  autoscaling: {}
  capabilities: {}
  configuration: {}
  controllerAvailabilityPolicy: SingleReplica
  dns:
    baseDomain: example.com
  fips: false
  infraID: ecr-test-local
  networking:
    clusterNetwork:
    - cidr: 10.132.0.0/14
    networkType: OVNKubernetes
    serviceNetwork:
    - cidr: 172.31.0.0/16
  platform:
    type: Agent
  pullSecret:
    name: ecr-pull-secret
  release:
    image: quay.io/openshift-release-dev/ocp-release:latest
EOF

for _ in $(seq 1 60); do
  if kubectl -n clusters get secret ecr-pull-secret >/dev/null 2>&1; then
    echo "E2E PASS: ecr-pull-secret was reconciled in the HostedCluster namespace."
    kubectl -n clusters get secret ecr-pull-secret -o jsonpath='{.type}{"\n"}'
    exit 0
  fi
  sleep 2
done

kubectl -n hypershift logs deployment/ecr-creds-sync --tail=100
echo "E2E FAIL: ecr-pull-secret was not created" >&2
exit 1
