#!/bin/bash
set -euo pipefail

# Sets up Azure Event Hubs (Kafka protocol) as a KNative Eventing source.
# Prerequisites:
#   - AKS cluster with KNative Eventing + Kafka components installed
#   - terraform outputs available

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/../terraform"

echo "=== Fetching Kafka config from Terraform ==="
cd "$TF_DIR"
BOOTSTRAP_SERVER=$(terraform output -raw kafka_bootstrap_server)
SASL_CONN_STRING=$(terraform output -raw kafka_sasl_connection_string)
EVENTHUB_NAME=$(terraform output -raw eventhub_name)

# Azure Event Hubs Kafka uses SASL_SSL with the connection string as password
# Username is always "$ConnectionString" (literal)
SASL_USERNAME='$ConnectionString'
SASL_PASSWORD="${SASL_CONN_STRING}"

echo "=== Creating Kafka auth secret ==="
kubectl create secret generic kafka-eventhub-secret \
  --namespace default \
  --from-literal=protocol="SASL_SSL" \
  --from-literal=sasl.mechanism="PLAIN" \
  --from-literal=user="${SASL_USERNAME}" \
  --from-literal=password="${SASL_PASSWORD}" \
  --from-literal=ca.crt="" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "=== Deploying KafkaSource ==="
cat <<EOF | kubectl apply -f -
apiVersion: sources.knative.dev/v1beta1
kind: KafkaSource
metadata:
  name: azure-eventhub-kafka-source
  namespace: default
spec:
  consumerGroup: knative-eventing
  bootstrapServers:
    - "${BOOTSTRAP_SERVER}"
  topics:
    - "${EVENTHUB_NAME}"
  net:
    sasl:
      enable: true
      type:
        secretKeyRef:
          name: kafka-eventhub-secret
          key: sasl.mechanism
      user:
        secretKeyRef:
          name: kafka-eventhub-secret
          key: user
      password:
        secretKeyRef:
          name: kafka-eventhub-secret
          key: password
    tls:
      enable: true
  sink:
    ref:
      apiVersion: eventing.knative.dev/v1
      kind: Broker
      name: default
EOF

echo ""
echo "✅ KafkaSource configured!"
echo "   Bootstrap: ${BOOTSTRAP_SERVER}"
echo "   Topic:     ${EVENTHUB_NAME}"
echo "   Consumer:  knative-eventing"
echo ""
echo "Test with kafkacat/kcat:"
echo "  echo '{\"hello\":\"knative\"}' | kcat -b ${BOOTSTRAP_SERVER} -t ${EVENTHUB_NAME} \\"
echo "    -X security.protocol=SASL_SSL -X sasl.mechanism=PLAIN \\"
echo "    -X sasl.username='\$ConnectionString' -X sasl.password='<connection-string>' -P"
