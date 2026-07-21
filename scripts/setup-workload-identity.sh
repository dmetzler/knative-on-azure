#!/bin/bash
set -euo pipefail
#
# setup-workload-identity.sh
#
# Configures the KNative Kafka Broker to use Azure Workload Identity
# instead of static SAS connection strings.
#
# Prerequisites:
#   - terraform apply (creates Managed Identity + Federated Credentials)
#   - install-knative.sh + reinstall-kafka-components.sh already run
#
# What this does:
#   1. Annotates the Kafka Broker ServiceAccounts for Workload Identity
#   2. Deploys a token-refresh CronJob that writes Azure AD tokens
#      into the Kafka auth secret
#   3. Configures kafka-broker-config to use the secret
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/../terraform"

echo "=== Fetching Workload Identity config from Terraform ==="
cd "$TF_DIR"
CLIENT_ID=$(terraform output -raw kafka_broker_identity_client_id)
BOOTSTRAP_SERVER=$(terraform output -raw kafka_bootstrap_server)
EVENTHUBS_NAMESPACE=$(terraform output -raw eventhubs_namespace)
SUBSCRIPTION_ID=$(terraform output -raw subscription_id 2>/dev/null || echo "")

echo "   Client ID:  ${CLIENT_ID}"
echo "   Bootstrap:  ${BOOTSTRAP_SERVER}"
echo "   EH Namespace: ${EVENTHUBS_NAMESPACE}"

echo "=== Annotating ServiceAccounts for Workload Identity ==="
# The data plane SA
kubectl annotate serviceaccount knative-kafka-broker-data-plane \
  -n knative-eventing \
  azure.workload.identity/client-id="${CLIENT_ID}" \
  --overwrite

# The controller SA (needs admin access for topic creation)
kubectl annotate serviceaccount kafka-controller \
  -n knative-eventing \
  azure.workload.identity/client-id="${CLIENT_ID}" \
  --overwrite

echo "=== Labeling ServiceAccounts for Workload Identity injection ==="
kubectl label serviceaccount knative-kafka-broker-data-plane \
  -n knative-eventing \
  azure.workload.identity/use=true \
  --overwrite

kubectl label serviceaccount kafka-controller \
  -n knative-eventing \
  azure.workload.identity/use=true \
  --overwrite

echo "=== Creating token-refresh ServiceAccount ==="
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kafka-token-refresh
  namespace: knative-eventing
  annotations:
    azure.workload.identity/client-id: "${CLIENT_ID}"
  labels:
    azure.workload.identity/use: "true"
EOF

echo "=== Deploying token-refresh CronJob ==="
cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: CronJob
metadata:
  name: kafka-token-refresh
  namespace: knative-eventing
spec:
  schedule: "*/5 * * * *"
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      template:
        metadata:
          labels:
            azure.workload.identity/use: "true"
        spec:
          serviceAccountName: kafka-token-refresh
          restartPolicy: OnFailure
          containers:
          - name: refresh
            image: mcr.microsoft.com/azure-cli:latest
            command:
            - /bin/bash
            - -c
            - |
              set -euo pipefail
              echo "Logging in with federated token..."
              az login --federated-token "\$(cat \$AZURE_FEDERATED_TOKEN_FILE)" \
                --service-principal -u "\$AZURE_CLIENT_ID" -t "\$AZURE_TENANT_ID" \
                --allow-no-subscriptions --output none

              echo "Fetching Azure AD token for Event Hubs..."
              TOKEN=\$(az account get-access-token \
                --resource "https://${EVENTHUBS_NAMESPACE}.servicebus.windows.net" \
                --query accessToken -o tsv)

              if [ -z "\$TOKEN" ]; then
                echo "ERROR: Failed to get Azure AD token"
                exit 1
              fi

              echo "Token obtained (length: \${#TOKEN}), updating secret..."

              # Create/update the auth secret with OAUTHBEARER-style credentials
              # Note: We use SASL_SSL + PLAIN because KNative's Go control plane
              # doesn't support Azure OAUTHBEARER natively yet.
              # The trick: Event Hubs accepts OAuth tokens via SASL/PLAIN where
              # username = "\\\$aad" and password = the OAuth access token.
              kubectl create secret generic kafka-auth-secret \
                --namespace knative-eventing \
                --from-literal=protocol=SASL_SSL \
                --from-literal=sasl.mechanism=PLAIN \
                --from-literal='user=\$aad' \
                --from-literal=password="\$TOKEN" \
                --dry-run=client -o yaml | kubectl apply -f -

              echo "Secret updated successfully"
EOF

echo "=== Running initial token refresh ==="
kubectl create job --from=cronjob/kafka-token-refresh kafka-token-refresh-init \
  -n knative-eventing 2>/dev/null || true
echo "   Waiting for initial token..."
kubectl wait --for=condition=complete job/kafka-token-refresh-init \
  -n knative-eventing --timeout=120s 2>/dev/null || echo "   ⚠️  Initial refresh may still be running"

echo "=== Configuring kafka-broker-config ==="
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

echo "=== Restarting Kafka components to pick up Workload Identity ==="
kubectl rollout restart deployment/kafka-controller -n knative-eventing
kubectl rollout restart statefulset/kafka-broker-dispatcher -n knative-eventing
kubectl rollout restart deployment/kafka-broker-receiver -n knative-eventing

kubectl rollout status deployment/kafka-controller -n knative-eventing --timeout=120s
kubectl rollout status deployment/kafka-broker-receiver -n knative-eventing --timeout=120s

echo ""
echo "✅ Workload Identity configured!"
echo ""
echo "How it works:"
echo "  - CronJob runs every 5 minutes to refresh the Azure AD token"
echo "  - Token is written to kafka-auth-secret as SASL_SSL/PLAIN credentials"
echo "  - Event Hubs accepts OAuth tokens via SASL/PLAIN with username='\$aad'"
echo "  - No static SAS connection strings needed"
echo ""
echo "To verify: kubectl get secret kafka-auth-secret -n knative-eventing -o yaml"
echo "To check token refresh: kubectl get jobs -n knative-eventing | grep token"
