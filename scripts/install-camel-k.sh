#!/bin/bash
set -euo pipefail

# Install Camel-K operator via Helm (no OLM required)
CAMEL_K_VERSION="${CAMEL_K_VERSION:-2.10.0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/../terraform"

echo "=== Installing Camel-K operator v${CAMEL_K_VERSION} ==="
kubectl create ns camel-k --dry-run=client -o yaml | kubectl apply -f -

helm repo add camel-k https://apache.github.io/camel-k/charts/ 2>/dev/null || true
helm repo update camel-k

helm upgrade --install camel-k camel-k/camel-k \
  --namespace camel-k \
  --version "${CAMEL_K_VERSION}" \
  --set-string operator.global=true \
  --wait --timeout 5m

echo ""
echo "=== Configuring ACR registry for Camel-K builds ==="
cd "$TF_DIR"
ACR_SERVER=$(terraform output -raw acr_login_server)
ACR_USER=$(terraform output -raw acr_admin_username)
ACR_PASS=$(terraform output -raw acr_admin_password)

kubectl create secret docker-registry camel-k-registry \
  --namespace camel-k \
  --docker-server="${ACR_SERVER}" \
  --docker-username="${ACR_USER}" \
  --docker-password="${ACR_PASS}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "=== Configuring IntegrationPlatform with registry ==="
cat <<EOF | kubectl apply -f -
apiVersion: camel.apache.org/v1
kind: IntegrationPlatform
metadata:
  name: camel-k
  namespace: camel-k
spec:
  build:
    publishStrategy: Jib
    registry:
      address: "${ACR_SERVER}"
      organization: camel-k
      secret: camel-k-registry
EOF

echo ""
echo "=== Waiting for IntegrationPlatform to be ready ==="
kubectl wait --for=jsonpath='{.status.phase}'=Ready integrationplatform/camel-k -n camel-k --timeout=120s 2>/dev/null || echo "⚠️  Platform not ready yet — check: kubectl get integrationplatform -n camel-k"

echo ""
echo "✅ Camel-K operator installed with ACR registry!"
echo ""
echo "Next steps:"
echo "  1. ./scripts/setup-camel-integrations.sh (deploys ASB ↔ Broker bridges)"
