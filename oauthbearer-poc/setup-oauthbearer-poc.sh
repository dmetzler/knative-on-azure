#!/bin/bash
set -euo pipefail
#
# setup-oauthbearer-poc.sh
#
# Phase 1: Deploy OAUTHBEARER PoC — Conduktor handler + native OAUTHBEARER auth
# to Azure Event Hubs via Workload Identity. No static credentials anywhere.
#
# Prerequisites:
#   - AKS cluster with OIDC Issuer + Workload Identity enabled
#   - terraform apply done (Managed Identity + Federated Credentials)
#   - KNative Eventing + Kafka Broker installed
#   - Derived images pushed to ACR (make acr-login build-oauthbearer-poc push-oauthbearer-poc)
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/../terraform"

echo "=== Fetching config from Terraform ==="
cd "$TF_DIR"
ACR_LOGIN_SERVER=$(terraform output -raw acr_login_server)
CLIENT_ID=$(terraform output -raw kafka_broker_identity_client_id)
BOOTSTRAP_SERVER=$(terraform output -raw kafka_bootstrap_server)
EVENTHUBS_NAMESPACE=$(terraform output -raw eventhubs_namespace)

echo "   ACR:           ${ACR_LOGIN_SERVER}"
echo "   Client ID:     ${CLIENT_ID}"
echo "   Bootstrap:     ${BOOTSTRAP_SERVER}"
echo "   EH Namespace:  ${EVENTHUBS_NAMESPACE}"

RECEIVER_IMG="${ACR_LOGIN_SERVER}/knative-kafka-receiver-oauthbearer:latest"
DISPATCHER_IMG="${ACR_LOGIN_SERVER}/knative-kafka-dispatcher-oauthbearer:latest"

# OAUTHBEARER JAAS config with Event Hubs scope
JAAS_CONFIG="org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required scope=\"https://${EVENTHUBS_NAMESPACE}.servicebus.windows.net/.default\";"
CALLBACK_HANDLER='io.conduktor.kafka.security.oauthbearer.azure.AzureManagedIdentityCallbackHandler'

# ── Step 1: Auth Secret ──────────────────────────────────────────────────
echo ""
echo "=== [1/6] Creating auth secret (OAUTHBEARER, no user/password) ==="
# The secret must have sasl.mechanism=OAUTHBEARER — otherwise the old PLAIN
# mechanism in the secret overrides the ConfigMap and the Conduktor handler
# receives the wrong mechanism.
kubectl create secret generic kafka-auth-secret \
  --namespace knative-eventing \
  --from-literal=protocol=SASL_SSL \
  --from-literal=sasl.mechanism=OAUTHBEARER \
  --dry-run=client -o yaml | kubectl apply -f -

# ── Step 2: ConfigMap ────────────────────────────────────────────────────
echo ""
echo "=== [2/6] Patching data-plane ConfigMap (JAAS + callback handler) ==="
# KafkaClientsAuth.java does nothing for OAUTHBEARER (empty code path),
# so these ConfigMap properties won't be overridden by the secret logic.
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

# ── Step 3: ServiceAccount ───────────────────────────────────────────────
echo ""
echo "=== [3/6] Configuring ServiceAccount for Workload Identity ==="
kubectl annotate serviceaccount knative-kafka-broker-data-plane \
  -n knative-eventing \
  azure.workload.identity/client-id="${CLIENT_ID}" \
  --overwrite
kubectl label serviceaccount knative-kafka-broker-data-plane \
  -n knative-eventing \
  azure.workload.identity/use=true \
  --overwrite

# ── Step 4: Pod templates ────────────────────────────────────────────────
echo ""
echo "=== [4/6] Patching pod templates (image + WI label + imagePullPolicy) ==="
# The WI mutating webhook only injects env vars when the POD has the label
# azure.workload.identity/use=true — the SA label alone is not enough.
# We also set imagePullPolicy=Always to ensure new image builds are picked up.

# Receiver (Deployment)
kubectl patch deployment kafka-broker-receiver -n knative-eventing --type=json -p="[
  {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/image\", \"value\": \"${RECEIVER_IMG}\"},
  {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/imagePullPolicy\", \"value\": \"Always\"}
]"
kubectl patch deployment kafka-broker-receiver -n knative-eventing \
  --type merge -p '{"spec":{"template":{"metadata":{"labels":{"azure.workload.identity/use":"true"}}}}}'

# Dispatcher (StatefulSet)
kubectl patch statefulset kafka-broker-dispatcher -n knative-eventing --type=json -p="[
  {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/image\", \"value\": \"${DISPATCHER_IMG}\"},
  {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/imagePullPolicy\", \"value\": \"Always\"}
]"
kubectl patch statefulset kafka-broker-dispatcher -n knative-eventing \
  --type merge -p '{"spec":{"template":{"metadata":{"labels":{"azure.workload.identity/use":"true"}}}}}'

# ── Step 5: Rollout ──────────────────────────────────────────────────────
echo ""
echo "=== [5/6] Waiting for rollout ==="
kubectl rollout status deployment/kafka-broker-receiver -n knative-eventing --timeout=120s
kubectl rollout status statefulset/kafka-broker-dispatcher -n knative-eventing --timeout=120s

# ── Step 6: Verify ───────────────────────────────────────────────────────
echo ""
echo "=== [6/6] Verifying Workload Identity injection ==="

verify_wi() {
  local label=$1 container=$2
  local pod
  pod=$(kubectl get pod -n knative-eventing -l "app=${label}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -z "$pod" ]; then
    echo "  ⚠️  No pod found for app=${label}"
    return
  fi
  echo "  Pod: ${pod}"
  local vars
  vars=$(kubectl exec -n knative-eventing "$pod" -c "$container" -- env 2>/dev/null | grep "^AZURE_" || true)
  if [ -n "$vars" ]; then
    echo "$vars" | sed 's/^/    /'
  else
    echo "  ❌ AZURE_* env vars not found — check WI webhook and pod labels"
  fi
}

echo "Receiver:"
verify_wi "kafka-broker-receiver" "kafka-broker-receiver"
echo "Dispatcher:"
verify_wi "kafka-broker-dispatcher" "kafka-broker-dispatcher"

echo ""
echo "✅ OAUTHBEARER PoC deployed!"
echo ""
echo "Verify:"
echo "  kubectl logs -n knative-eventing -l app=kafka-broker-dispatcher -c kafka-broker-dispatcher --tail=20"
echo "  # Look for: 'Setting offset for partition' (successful auth)"
echo "  # Bad:      'SaslAuthenticationException' or 'CredentialUnavailableException'"
echo ""
echo "Test:"
echo "  kubectl run curl --image=curlimages/curl --rm -it --restart=Never -- \\"
echo "    -X POST http://kafka-broker-ingress.knative-eventing.svc.cluster.local/default/default \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -H 'Ce-Id: test-oauthbearer-1' -H 'Ce-Specversion: 1.0' \\"
echo "    -H 'Ce-Type: dev.knative.test' -H 'Ce-Source: /test/oauthbearer' \\"
echo "    -d '{\"msg\": \"Hello from OAUTHBEARER!\"}'"
