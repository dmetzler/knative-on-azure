#!/bin/bash
set -euo pipefail

# Install Camel-K operator via Helm (no OLM required)
CAMEL_K_VERSION="${CAMEL_K_VERSION:-2.10.0}"

echo "=== Installing Camel-K operator v${CAMEL_K_VERSION} ==="
kubectl create ns camel-k --dry-run=client -o yaml | kubectl apply -f -

helm repo add camel-k https://apache.github.io/camel-k/charts/ 2>/dev/null || true
helm repo update camel-k

helm upgrade --install camel-k camel-k/camel-k \
  --namespace camel-k \
  --version "${CAMEL_K_VERSION}" \
  --set operator.global=true \
  --wait --timeout 5m

echo ""
echo "✅ Camel-K operator installed!"
echo ""
echo "Next steps:"
echo "  1. terraform apply (creates Service Bus)"
echo "  2. ./scripts/setup-camel-integrations.sh (deploys ASB ↔ Broker bridges)"
