#!/bin/bash
set -euo pipefail
#
# setup-oauthbearer-poc.sh
#
# Phase 1: Deploy OAUTHBEARER PoC — Conduktor handler + OAUTHBEARER config
# via data-plane ConfigMaps (bypassing the broken KafkaClientsAuth code path).
#
# Prerequisites:
#   - AKS cluster running with Workload Identity enabled
#   - terraform apply done (Managed Identity + Federated Credentials exist)
#   - KNative + Kafka Broker installed
#   - Derived images pushed to ACR (make build-oauthbearer-poc push-oauthbearer-poc)
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/../terraform"

echo "=== Fetching config from Terraform ==="
cd "$TF_DIR"
ACR_LOGIN_SERVER=$(terraform output -raw acr_login_server)
CLIENT_ID=$(terraform output -raw kafka_broker_identity_client_id)
BOOTSTRAP_SERVER=$(terraform output -raw kafka_bootstrap_server)
EVENTHUBS_NAMESPACE=$(terraform output -raw eventhubs_namespace)

echo "   ACR:        ${ACR_LOGIN_SERVER}"
echo "   Client ID:  ${CLIENT_ID}"
echo "   Bootstrap:  ${BOOTSTRAP_SERVER}"
echo "   Namespace:  ${EVENTHUBS_NAMESPACE}"

RECEIVER_IMG="${ACR_LOGIN_SERVER}/knative-kafka-receiver-oauthbearer:latest"
DISPATCHER_IMG="${ACR_LOGIN_SERVER}/knative-kafka-dispatcher-oauthbearer:latest"

echo ""
echo "=== Phase 1: OAUTHBEARER via ConfigMap properties ==="
echo ""
echo "Strategy: Set OAUTHBEARER properties in the data-plane ConfigMap."
echo "The ConfigMap is the BASE, but since KafkaClientsAuth does nothing for"
echo "OAUTHBEARER, nothing will override these properties from the secret."
echo ""

# The JAAS config for the Conduktor handler
JAAS_CONFIG='org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required;'
CALLBACK_HANDLER='io.conduktor.kafka.security.oauthbearer.azure.AzureManagedIdentityCallbackHandler'

echo "=== Patching config-kafka-broker-data-plane ConfigMap ==="
# We patch both producer and consumer properties
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: config-kafka-broker-data-plane
  namespace: knative-eventing
data:
  config-kafka-broker-producer.properties: |
    bootstrap.servers=${BOOTSTRAP_SERVER}
    security.protocol=SASL_SSL
    sasl.mechanism=OAUTHBEARER
    sasl.jaas.config=${JAAS_CONFIG}
    sasl.login.callback.handler.class=${CALLBACK_HANDLER}
  config-kafka-broker-consumer.properties: |
    bootstrap.servers=${BOOTSTRAP_SERVER}
    security.protocol=SASL_SSL
    sasl.mechanism=OAUTHBEARER
    sasl.jaas.config=${JAAS_CONFIG}
    sasl.login.callback.handler.class=${CALLBACK_HANDLER}
EOF

echo "=== Ensuring ServiceAccounts have Workload Identity labels ==="
kubectl annotate serviceaccount knative-kafka-broker-data-plane \
  -n knative-eventing \
  azure.workload.identity/client-id="${CLIENT_ID}" \
  --overwrite
kubectl label serviceaccount knative-kafka-broker-data-plane \
  -n knative-eventing \
  azure.workload.identity/use=true \
  --overwrite

echo "=== Patching data-plane deployments with derived images ==="
# Receiver
kubectl set image deployment/kafka-broker-receiver \
  -n knative-eventing \
  receiver="${RECEIVER_IMG}"

# Dispatcher
kubectl set image statefulset/kafka-broker-dispatcher \
  -n knative-eventing \
  dispatcher="${DISPATCHER_IMG}"

echo "=== Restarting data-plane to pick up new images + WI injection ==="
kubectl rollout restart deployment/kafka-broker-receiver -n knative-eventing
kubectl rollout restart statefulset/kafka-broker-dispatcher -n knative-eventing

echo ""
echo "=== Waiting for rollout ==="
kubectl rollout status deployment/kafka-broker-receiver -n knative-eventing --timeout=120s
kubectl rollout status statefulset/kafka-broker-dispatcher -n knative-eventing --timeout=120s

echo ""
echo "=== Verifying WI env vars in receiver pod ==="
POD=$(kubectl get pod -n knative-eventing -l app=kafka-broker-receiver -o jsonpath='{.items[0].metadata.name}')
echo "Pod: $POD"
kubectl exec -n knative-eventing "$POD" -c receiver -- env | grep -E "AZURE_|IDENTITY" || echo "⚠️  WI env vars not found — check mutating webhook"

echo ""
echo "✅ OAUTHBEARER PoC deployed!"
echo ""
echo "Next steps:"
echo "  1. Create a Broker:  kubectl apply -f k8s/demo/broker.yaml"
echo "  2. Send a test event and check logs:"
echo "     kubectl logs -n knative-eventing -l app=kafka-broker-receiver -c receiver --tail=50"
echo "  3. Look for successful SASL handshake (no SaslAuthenticationException)"
