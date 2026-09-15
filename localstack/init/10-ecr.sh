#!/bin/bash
set -euo pipefail

awslocal ecr create-repository --repository-name rosa/release >/dev/null 2>&1 || true
echo "LocalStack ECR repository ready: rosa/release"
