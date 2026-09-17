#!/bin/bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

export GOCACHE=$(mktemp -d /tmp/gocache.XXXXXX)
export GOMODCACHE=$(mktemp -d /tmp/gomodcache.XXXXXX)
export GOFLAGS=-mod=mod

make test-unit
