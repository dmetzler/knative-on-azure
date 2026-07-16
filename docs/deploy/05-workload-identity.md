# Workload Identity (No Static Credentials)

!!! warning "Experimental"
    This is a follow-up to the SAS-based auth. KNative's Kafka Broker does **not** natively support Azure OAUTHBEARER — this uses a workaround via token refresh.

## Problem

The default setup uses a static SAS connection string (`$ConnectionString` + key) in a Kubernetes Secret. This works but:

- Requires manual rotation
- Static credentials are a security risk
- Doesn't align with zero-trust / Workload Identity standards

## Solution

Azure Event Hubs accepts **OAuth2 tokens via SASL/PLAIN** — a lesser-known feature where:

- **Username**: `$aad` (literal string, tells Event Hubs to expect an OAuth token)
- **Password**: A valid Azure AD access token (with Event Hubs audience)

Combined with **AKS Workload Identity**, we can:

1. Bind K8s ServiceAccounts to an Azure Managed Identity (via OIDC federation)
2. Use a CronJob to refresh the token every 5 minutes
3. Write the token into the same `kafka-auth-secret` the Broker already uses

```
┌─ AKS Pod (CronJob) ──────────────────────────────┐
│                                                   │
│  ServiceAccount ──► Projected Token ──► Azure AD  │
│                         (OIDC)          Token     │
│                                          │        │
│  kubectl create secret ◄─────────────────┘        │
│  (kafka-auth-secret: user=$aad, password=<token>) │
└───────────────────────────────────────────────────┘
         │
         ▼
┌─ Kafka Broker ────────────────────────────────────┐
│  Reads kafka-auth-secret                          │
│  Connects to Event Hubs with SASL_SSL + PLAIN     │
│  username=$aad, password=<Azure AD token>          │
└───────────────────────────────────────────────────┘
```

## Setup

### 1. Deploy Terraform (includes Workload Identity resources)

```bash
cd terraform
terraform apply
```

This creates:

| Resource | Purpose |
|----------|---------|
| `id-knative-kafka-broker` | User-Assigned Managed Identity |
| Federated Credential (data-plane SA) | Binds `knative-kafka-broker-data-plane` SA → Identity |
| Federated Credential (controller SA) | Binds `kafka-controller` SA → Identity |
| Role Assignment | `Azure Event Hubs Data Owner` on the EH namespace |

### 2. Install KNative (if not done)

```bash
./scripts/install-knative.sh
./scripts/reinstall-kafka-components.sh
```

### 3. Configure Workload Identity

```bash
./scripts/setup-workload-identity.sh
```

This:

1. Annotates ServiceAccounts for Workload Identity
2. Creates a `kafka-token-refresh` CronJob (runs every 5 min)
3. Runs an initial token refresh
4. Configures `kafka-broker-config` with the secret reference
5. Restarts Kafka components

### 4. Create the Broker

```bash
kubectl apply -f k8s/demo/broker.yaml
kubectl wait --for=condition=Ready broker/default -n default --timeout=180s
```

## Verify

```bash
# Check the CronJob is running
kubectl get cronjob kafka-token-refresh -n knative-eventing

# Check the secret has been updated
kubectl get secret kafka-auth-secret -n knative-eventing -o jsonpath='{.data.user}' | base64 -d
# Should output: $aad

# Check token refresh jobs
kubectl get jobs -n knative-eventing | grep token

# Test the event flow (same as SAS-based)
kubectl run curl --image=curlimages/curl --rm -it --restart=Never -- \
  -X POST http://kafka-broker-ingress.knative-eventing.svc.cluster.local/default/default \
  -H 'Content-Type: application/json' \
  -H 'Ce-Id: test-wi-1' -H 'Ce-Specversion: 1.0' \
  -H 'Ce-Type: dev.knative.test' -H 'Ce-Source: /test/wi' \
  -d '{"msg": "Hello from Workload Identity!"}'
```

## Limitations

### Why not native OAUTHBEARER?

KNative's Kafka Broker OAUTHBEARER support is **AWS MSK-only** as of v1.22.1:

- **Control plane (Go/Sarama)**: `tokenProvider` in the auth secret only accepts `MSKAccessTokenProvider` and `MSKRoleAccessTokenProvider`
- **Data plane (Java/Vert.x)**: Same limitation — the token issuer interface has no Azure implementation

The architecture is clean though — both sides use a `tokenIssuer` / `AccessTokenProvider` interface. An upstream PR adding `AzureAccessTokenProvider` would make this native.

**Relevant upstream issue:** [knative-extensions/eventing-kafka-broker#3514](https://github.com/knative-extensions/eventing-kafka-broker/issues/3514) (AWS MSK, same pattern needed for Azure)

### Token Refresh Latency

- CronJob runs every **5 minutes**
- Azure AD tokens are valid for **60-90 minutes**
- Worst case: a token could be ~5 minutes old when the Broker uses it
- The Kafka client does **not** dynamically reload secrets — pods may need a restart if the token format changes

### RBAC Requirement

The Workload Identity setup requires `Microsoft.Authorization/roleAssignments/write` permission on the Event Hubs namespace. On corporate subscriptions where this is restricted, you may need an admin to create the role assignment:

```bash
az role assignment create \
  --assignee-object-id <managed-identity-principal-id> \
  --role "Azure Event Hubs Data Owner" \
  --scope /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.EventHub/namespaces/<ns>
```

## Future: Native Support

When KNative adds Azure OAUTHBEARER support (similar to AWS MSK), the setup simplifies to:

```yaml
# Future: native Azure auth in the Secret
apiVersion: v1
kind: Secret
metadata:
  name: kafka-auth-secret
  namespace: knative-eventing
stringData:
  protocol: SASL_SSL
  sasl.mechanism: OAUTHBEARER
  tokenProvider: AzureAccessTokenProvider  # future
```

No CronJob, no token rotation — the Kafka client would fetch tokens directly from the projected service account token. The Terraform + Federated Credentials from this branch would remain unchanged.
