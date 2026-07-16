#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/../terraform"

echo "=== Fetching Event Hubs Kafka config from Terraform ==="
cd "$TF_DIR"
BOOTSTRAP_SERVER=$(terraform output -raw kafka_bootstrap_server)
SASL_CONN_STRING=$(terraform output -raw kafka_sasl_connection_string)

echo "   Bootstrap: ${BOOTSTRAP_SERVER}"

echo "=== Creating Kafka secret for the broker ==="
kubectl create secret generic eventhub-kafka-secret \
  --namespace knative-eventing \
  --from-literal=protocol="SASL_SSL" \
  --from-literal=sasl.mechanism="PLAIN" \
  --from-literal=password="$SASL_CONN_STRING" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "=== Configuring Kafka Broker defaults ==="
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: kafka-broker-config
  namespace: knative-eventing
data:
  default.topic.partitions: "2"
  default.topic.replication.factor: "1"
  bootstrap.servers: "${BOOTSTRAP_SERVER}"
  auth.secret.ref.name: eventhub-kafka-secret
  auth.secret.ref.namespace: knative-eventing
EOF

echo "=== Creating a Kafka-backed Broker in default namespace ==="
cat <<EOF | kubectl apply -f -
apiVersion: eventing.knative.dev/v1
kind: Broker
metadata:
  name: default
  namespace: default
  annotations:
    eventing.knative.dev/broker.class: Kafka
spec:
  config:
    apiVersion: v1
    kind: ConfigMap
    name: kafka-broker-config
    namespace: knative-eventing
EOF

echo "=== Deploying event-display sink + trigger ==="
kubectl apply -f "${SCRIPT_DIR}/../k8s/demo/event-display.yaml"

echo ""
echo "=== Waiting for broker to be ready ==="
kubectl wait --for=condition=Ready broker/default -n default --timeout=120s

echo ""
echo "✅ Kafka Broker ready! Backed by Azure Event Hubs."
echo ""
echo "To test, send a CloudEvent:"
echo "  kubectl run curl --image=curlimages/curl --rm -it --restart=Never -- \\"
echo "    -v -X POST http://broker-ingress.knative-eventing.svc.cluster.local/default/default \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -H 'Ce-Id: test-1' \\"
echo "    -H 'Ce-Specversion: 1.0' \\"
echo "    -H 'Ce-Type: dev.knative.test' \\"
echo "    -H 'Ce-Source: /test' \\"
echo "    -d '{\"msg\": \"Hello from Event Hubs!\"}'"
echo ""
echo "Then check logs:"
echo "  kubectl logs -l serving.knative.dev/service=event-display -c user-container -f"
