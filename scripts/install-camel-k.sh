#!/bin/bash
set -euo pipefail

# Install Camel-K operator via Kustomize (no OLM required)
CAMEL_K_VERSION="${CAMEL_K_VERSION:-2.10.0}"

echo "=== Installing Camel-K operator v${CAMEL_K_VERSION} ==="
kubectl create ns camel-k --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -k "github.com/apache/camel-k/install/overlays/all-namespaces?ref=v${CAMEL_K_VERSION}" --server-side

echo "=== Waiting for Camel-K operator to be ready ==="
kubectl wait --for=condition=Available deployment/camel-k-operator -n camel-k --timeout=300s

echo ""
echo "=== Configuring Camel-K IntegrationPlatform ==="
cat <<'EOF' | kubectl apply -f -
apiVersion: camel.apache.org/v1
kind: IntegrationPlatform
metadata:
  name: camel-k
  namespace: camel-k
spec:
  build:
    registry:
      # Uses ephemeral registry — images are rebuilt on pod restart.
      # For production, configure a persistent registry (ACR, GHCR, etc.)
      insecure: true
EOF

echo ""
echo "✅ Camel-K operator installed!"
echo ""
echo "Next steps:"
echo "  1. terraform apply (creates Service Bus)"
echo "  2. ./scripts/setup-camel-integrations.sh (deploys ASB ↔ Broker bridges)"
