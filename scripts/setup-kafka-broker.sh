#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/../terraform"

echo "=== Fetching Event Hubs Kafka config from Terraform ==="
cd "$TF_DIR"
BOOTSTRAP_SERVER=$(terraform output -raw kafka_bootstrap_server)
SASL_CONN_STRING=$(terraform output -raw kafka_sasl_connection_string)

echo "   Bootstrap: ${BOOTSTRAP_SERVER}"

echo "=== Configuring Kafka Broker bootstrap ==="
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
EOF

echo "=== Configuring Kafka Broker data-plane auth (SASL_SSL for Event Hubs) ==="
# Build the properties files and apply via kubectl
PRODUCER_PROPS=$(mktemp)
CONSUMER_PROPS=$(mktemp)

cat > "$PRODUCER_PROPS" <<PROPS
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="\$ConnectionString" password="${SASL_CONN_STRING}";
PROPS

cp "$PRODUCER_PROPS" "$CONSUMER_PROPS"

ADMIN_PROPS=$(mktemp)
cp "$PRODUCER_PROPS" "$ADMIN_PROPS"

kubectl create configmap config-kafka-broker-data-plane \
  --namespace knative-eventing \
  --from-file=config-kafka-broker-producer.properties="$PRODUCER_PROPS" \
  --from-file=config-kafka-broker-consumer.properties="$CONSUMER_PROPS" \
  --from-file=config-kafka-broker-admin.properties="$ADMIN_PROPS" \
  --dry-run=client -o yaml | kubectl apply -f -

rm -f "$PRODUCER_PROPS" "$CONSUMER_PROPS" "$ADMIN_PROPS"

echo "=== Restarting Kafka broker pods to pick up new config ==="
kubectl rollout restart deployment/kafka-broker-receiver -n knative-eventing 2>/dev/null || true
kubectl rollout restart statefulset/kafka-broker-dispatcher -n knative-eventing 2>/dev/null || true

echo "=== Creating a Kafka-backed Broker in default namespace ==="
cat <<'BROKEREOF' | kubectl apply -f -
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
BROKEREOF

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
