#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/../terraform"

echo "=== Fetching Event Hubs Kafka config from Terraform ==="
cd "$TF_DIR"
BOOTSTRAP_SERVER=$(terraform output -raw kafka_bootstrap_server)
SASL_CONN_STRING=$(terraform output -raw kafka_sasl_connection_string)

echo "   Bootstrap: ${BOOTSTRAP_SERVER}"

echo "=== Creating auth Secret for Event Hubs (SASL_SSL) ==="
# The Kafka Broker controller reads auth from a Secret referenced in the ConfigMap.
# For Azure Event Hubs:
#   protocol: SASL_SSL
#   sasl.mechanism: PLAIN
#   user: $ConnectionString  (literal string)
#   password: <SAS connection string>
kubectl create secret generic kafka-auth-secret \
  --namespace knative-eventing \
  --from-literal=protocol=SASL_SSL \
  --from-literal=sasl.mechanism=PLAIN \
  --from-literal='user=$ConnectionString' \
  --from-literal=password="${SASL_CONN_STRING}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "=== Configuring kafka-broker-config ConfigMap ==="
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
  auth.secret.ref.name: kafka-auth-secret
EOF

echo "=== Restarting Kafka controller to pick up new config ==="
kubectl rollout restart deployment/kafka-controller -n knative-eventing
kubectl rollout status deployment/kafka-controller -n knative-eventing --timeout=60s

echo "=== Creating a Kafka-backed Broker in default namespace ==="
kubectl delete broker default -n default --ignore-not-found
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
kubectl wait --for=condition=Ready broker/default -n default --timeout=180s

echo ""
echo "✅ Kafka Broker ready! Backed by Azure Event Hubs."
echo ""
echo "To test, send a CloudEvent:"
echo "  kubectl run curl --image=curlimages/curl --rm -it --restart=Never -- \\"
echo "    -v -X POST http://kafka-broker-ingress.knative-eventing.svc.cluster.local/default/default \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -H 'Ce-Id: test-1' \\"
echo "    -H 'Ce-Specversion: 1.0' \\"
echo "    -H 'Ce-Type: dev.knative.test' \\"
echo "    -H 'Ce-Source: /test' \\"
echo "    -d '{\"msg\": \"Hello from Event Hubs!\"}'"
echo ""
echo "Then check logs:"
echo "  kubectl logs -l serving.knative.dev/service=event-display -c user-container -f"
