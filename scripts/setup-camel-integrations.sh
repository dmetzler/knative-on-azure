#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/../terraform"

echo "=== Fetching Service Bus config from Terraform ==="
cd "$TF_DIR"
ASB_CONN_STRING=$(terraform output -raw servicebus_connection_string)
ASB_NAMESPACE=$(terraform output -raw servicebus_namespace)

echo "   Namespace: ${ASB_NAMESPACE}"

echo "=== Creating Service Bus Properties Secret ==="
# Camel-K mount.configs loads secret keys as property files.
# We use a single key 'application.properties' so Camel loads it as a standard properties file.
ASB_PROPS="asb.connection-string=${ASB_CONN_STRING}"

kubectl create secret generic azure-servicebus-props \
  --namespace default \
  --from-literal=application.properties="${ASB_PROPS}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "=== Deploying ASB → Broker integration (inbound) ==="
kubectl apply -f "${SCRIPT_DIR}/../k8s/integrations/asb-to-broker.yaml"

echo "=== Deploying Broker → ASB integration (outbound) ==="
kubectl apply -f "${SCRIPT_DIR}/../k8s/integrations/broker-to-asb.yaml"

echo ""
echo "✅ Camel-K integrations deployed!"
echo ""
echo "Flows:"
echo "  📥 ASB queue 'knative-inbound' → Kafka Broker (default)"
echo "  📤 Broker events (type=asb.outbound.*) → ASB queue 'knative-outbound'"
echo ""
echo "Test inbound:"
echo "  az servicebus queue send -g rg-knative-lab --namespace-name ${ASB_NAMESPACE} \\"
echo "    --queue-name knative-inbound --body '{\"msg\":\"from ASB\"}'"
echo ""
echo "Check event-display:"
echo "  kubectl logs -l serving.knative.dev/service=event-display -c user-container -f"
