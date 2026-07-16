#!/bin/bash
set -euo pipefail

# This script sets up Azure Event Hubs as a KNative Eventing source.
# Prerequisites:
#   - AKS cluster with KNative Eventing installed
#   - terraform output available (for connection strings)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/../terraform"

echo "=== Fetching Event Hub connection string from Terraform ==="
cd "$TF_DIR"
CONN_STRING=$(terraform output -raw eventhub_listen_connection_string)
EVENTHUB_NAME=$(terraform output -raw eventhub_name)

echo "=== Creating Kubernetes secret for Event Hub credentials ==="
kubectl create namespace knative-eventing-sources 2>/dev/null || true

kubectl create secret generic azure-eventhub-secret \
  --namespace knative-eventing-sources \
  --from-literal=connectionString="${CONN_STRING}" \
  --from-literal=eventHubName="${EVENTHUB_NAME}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "=== Deploying Azure Event Hubs source ==="
# Use the Knative ContainerSource approach with the Azure SDK
# This is a lightweight approach — alternatively use the dedicated
# knative-extensions/eventing-azure package when it matures.
kubectl apply -f "${SCRIPT_DIR}/../k8s/knative/eventhubs-source.yaml"

echo ""
echo "✅ Event Hubs source configured!"
echo "   Send events to your hub and they'll appear as CloudEvents in the cluster."
echo ""
echo "To send a test event:"
echo "  SEND_CONN=\$(cd ${TF_DIR} && terraform output -raw eventhub_send_connection_string)"
echo "  az eventhubs eventhub send --connection-string \"\$SEND_CONN\" --body '{\"hello\":\"knative\"}'"
