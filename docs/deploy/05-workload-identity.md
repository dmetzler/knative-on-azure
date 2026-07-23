# Workload Identity with OAUTHBEARER (No Static Credentials)

!!! success "Validated"
    This approach has been validated end-to-end: Kafka Broker producing and consuming
    from Azure Event Hubs using native OAUTHBEARER SASL with Workload Identity —
    **zero static credentials anywhere in the configuration**.

## Problem

The default Kafka Broker setup uses a static SAS connection string in a Kubernetes Secret.
This is problematic because:

- Static shared secrets must be manually rotated
- SAS keys cannot be scoped to individual workloads
- Violates zero-trust / Managed Identity best practices
- Blocked in environments where static secrets are prohibited by policy

## Solution Overview

Azure Event Hubs supports the standard **SASL/OAUTHBEARER** mechanism. Combined with
**AKS Workload Identity**, the Kafka client can authenticate using a federated token
obtained automatically from the Azure AD / Entra ID token endpoint — no secrets stored
anywhere.

```
┌─ AKS Pod (Kafka Broker data-plane) ───────────────────────┐
│                                                            │
│  ServiceAccount                                            │
│       ↓ projected token (OIDC)                             │
│  WorkloadIdentityCredential                                │
│       ↓ exchanges for Azure AD access token                │
│  Conduktor OAuthBearerCallbackHandler                      │
│       ↓ supplies token to Kafka client                     │
│  SASL/OAUTHBEARER handshake with Event Hubs                │
│                                                            │
└────────────────────────────────────────────────────────────┘
```

### Why not SASL/PLAIN with `$aad`?

Azure Event Hubs also accepts OAuth tokens via `SASL/PLAIN` with `username=$aad` and the
token as the password. However, this requires an external token refresh mechanism (CronJob)
because the Kafka client cannot refresh PLAIN credentials. OAUTHBEARER is the native
mechanism — the Kafka client handles token refresh automatically via the callback handler.

### Why a derived image?

KNative's Kafka Broker **does not natively support Azure OAUTHBEARER** as of v1.22.
The OAUTHBEARER code path in `KafkaClientsAuth.java` is an empty stub — it sets the
mechanism but provides no JAAS config or callback handler. See the
[Phase 0 Recon](../phase0-recon.md) for details.

To bridge this gap without modifying upstream code, we build **derived data-plane images**
that add a third-party callback handler JAR to the classpath.

## Architecture

### Components

| Component | Role |
|---|---|
| **Azure Managed Identity** | `id-knative-kafka-broker` — User-Assigned MI with `Azure Event Hubs Data Owner` role |
| **Federated Credentials** | Bind K8s ServiceAccounts to the MI via OIDC federation |
| **Workload Identity Webhook** | Injects `AZURE_*` env vars + projected token volume into pods |
| **Conduktor callback handler** | [`conduktor/azure-kafka-oauthbearer`](https://github.com/conduktor/azure-kafka-oauthbearer) — implements `AuthenticateCallbackHandler` using `azure-identity` SDK |
| **Derived data-plane images** | Upstream receiver/dispatcher images + Conduktor JAR on the classpath |
| **ConfigMap properties** | `sasl.jaas.config` + `sasl.login.callback.handler.class` injected via `config-kafka-broker-data-plane` |

### Auth flow

1. AKS Workload Identity webhook injects a projected service account token into the pod
2. The Conduktor callback handler uses `WorkloadIdentityCredential` to exchange this token
   for an Azure AD access token (with Event Hubs audience/scope)
3. The Kafka client presents the access token via SASL/OAUTHBEARER during the handshake
4. On token expiry (~1h), the Kafka client calls the handler again for a fresh token —
   **automatic refresh, no CronJob needed**

## Prerequisites

- AKS cluster with **OIDC Issuer** and **Workload Identity** enabled:
  ```bash
  az aks update -g <rg> -n <cluster> --enable-oidc-issuer --enable-workload-identity
  ```
- Terraform applied (creates Managed Identity + Federated Credentials + role assignment)
- KNative Eventing + Kafka Broker installed
- Java 17+ and Maven (for building the Conduktor JAR from source)
- Docker (for building derived images)

## Setup

### 1. Build the Conduktor JAR

The callback handler is not published to Maven Central, so we build from source:

```bash
make build-conduktor-jar
```

This clones `conduktor/azure-kafka-oauthbearer` tag **0.5.0** (Kafka 3.x compatible),
injects the `maven-shade-plugin` to produce a fat JAR with all dependencies, and copies
the result to `oauthbearer-poc/conduktor-azure-oauthbearer.jar`.

!!! warning "Version compatibility"
    Use tag **0.5.0** (targets `kafka-clients 3.7.0`). The `main` branch and 0.6.0+ target
    Kafka 4.2 which introduces `JwtRetriever` (KIP-768) — a class that does not exist in
    KNative 1.22's `kafka-clients 3.9.1`, causing `NoClassDefFoundError` at runtime.

### 2. Build and push derived images

```bash
make acr-login build-oauthbearer-poc push-oauthbearer-poc
```

This builds two Docker images:

- `knative-kafka-receiver-oauthbearer:latest` — receiver with Conduktor JAR
- `knative-kafka-dispatcher-oauthbearer:latest` — dispatcher with Conduktor JAR

#### How the image works

The upstream data-plane images are built with **Jib** (Google's container image builder
for Java). Jib does not use a fat/uber JAR — instead, it stores dependencies in
`/app/libs/` and defines the classpath in a file at `/app/jib-classpath-file`:

```
java --enable-preview -cp @/app/jib-classpath-file <MainClass>
```

Simply copying a JAR to `/app/libs/` is **not enough** — the JAR must be explicitly
appended to `/app/jib-classpath-file`:

```dockerfile
FROM gcr.io/knative-releases/knative-kafka-broker-receiver-loom@sha256:e7d7...
USER root
COPY conduktor-azure-oauthbearer.jar /app/libs/conduktor-azure-oauthbearer.jar
RUN echo ":/app/libs/conduktor-azure-oauthbearer.jar" >> /app/jib-classpath-file
USER 185
```

### 3. Deploy the OAUTHBEARER configuration

```bash
make deploy-oauthbearer-poc
```

Or manually:

```bash
./oauthbearer-poc/setup-oauthbearer-poc.sh
```

This script:

1. **Updates the auth secret** to `OAUTHBEARER` (removes any `PLAIN`/`$aad` credentials)
2. **Patches the ConfigMap** `config-kafka-broker-data-plane` with OAUTHBEARER properties
3. **Annotates and labels** the data-plane ServiceAccount for Workload Identity
4. **Patches and labels pod templates** so the WI webhook injects env vars
5. **Swaps the container images** to the derived versions
6. **Restarts** the data-plane pods

### 4. Verify

```bash
# Check WI env vars are injected
kubectl exec -n knative-eventing \
  $(kubectl get pod -n knative-eventing -l app=kafka-broker-dispatcher \
    -o jsonpath='{.items[0].metadata.name}') \
  -c kafka-broker-dispatcher -- env | grep AZURE

# Expected output:
# AZURE_CLIENT_ID=<managed-identity-client-id>
# AZURE_TENANT_ID=<tenant-id>
# AZURE_FEDERATED_TOKEN_FILE=/var/run/secrets/azure/tokens/azure-identity-token
# AZURE_AUTHORITY_HOST=https://login.microsoftonline.com/

# Check dispatcher logs for successful offset fetch (no auth errors)
kubectl logs -n knative-eventing -l app=kafka-broker-dispatcher \
  -c kafka-broker-dispatcher --tail=20

# Send a test event
kubectl run curl --image=curlimages/curl --rm -it --restart=Never -- \
  -X POST http://kafka-broker-ingress.knative-eventing.svc.cluster.local/default/default \
  -H 'Content-Type: application/json' \
  -H 'Ce-Id: test-oauthbearer-1' -H 'Ce-Specversion: 1.0' \
  -H 'Ce-Type: dev.knative.test' -H 'Ce-Source: /test/oauthbearer' \
  -d '{"msg": "Hello from OAUTHBEARER + Workload Identity!"}'
```

## Pitfalls & Lessons Learned

These are the issues encountered during the PoC, documented for future reference.

### 1. GCR image paths

The upstream images are **not** at the path you'd expect from the Go module:

| ❌ Wrong | ✅ Correct |
|---|---|
| `gcr.io/knative-releases/knative.dev/eventing-kafka-broker/cmd/receiver` | `gcr.io/knative-releases/knative-kafka-broker-receiver-loom` |

And they are published by **digest only** (no tags). Get the correct references from
the release YAML:

```bash
curl -sL "https://github.com/knative-extensions/eventing-kafka-broker/releases/download/knative-v1.22.1/eventing-kafka-broker.yaml" \
  | grep "image:.*gcr" | sort -u
```

### 2. Jib classpath file

Jib-built images use `-cp @/app/jib-classpath-file`, not a `/app/libs/*` glob.
Adding a JAR to `/app/libs/` without appending it to the classpath file means
the JVM will never load it → `ClassNotFoundException`.

### 3. Kafka version mismatch (Conduktor 0.6+ vs KNative 1.22)

Conduktor `main` and `0.6.0` depend on `kafka-clients 4.2.0` which introduces
`org.apache.kafka.common.security.oauthbearer.JwtRetriever` (KIP-768). This class
does not exist in KNative 1.22's `kafka-clients 3.9.1`:

```
NoClassDefFoundError: org/apache/kafka/common/security/oauthbearer/JwtRetriever
```

**Fix:** Use Conduktor tag **0.5.0** which targets `kafka-clients 3.7.0`.

### 4. Secret overrides ConfigMap

The data-plane merges properties as: **ConfigMap (base) → Secret (override)**.
If the auth secret still contains `sasl.mechanism=PLAIN` from a previous setup,
it will override the `OAUTHBEARER` mechanism set in the ConfigMap:

```
Unexpected SASL mechanism: PLAIN
```

**Fix:** Update the auth secret to `sasl.mechanism=OAUTHBEARER` and remove
`user`/`password` keys.

### 5. Workload Identity pod label

The WI mutating webhook injects env vars only when the **pod** (not just the
ServiceAccount) has the label `azure.workload.identity/use: "true"`. The pod
template in the Deployment/StatefulSet must be patched:

```bash
kubectl patch statefulset kafka-broker-dispatcher -n knative-eventing \
  --type merge \
  -p '{"spec":{"template":{"metadata":{"labels":{"azure.workload.identity/use":"true"}}}}}'
```

Without this, the SA annotation is ignored and `AZURE_*` env vars are not injected.

### 6. OAUTHBEARER scope is required

The JAAS config **must** include a `scope` parameter pointing to the Event Hubs
namespace. Without it, the Azure Identity SDK has no resource/audience to request
a token for:

```
CredentialUnavailableException: EnvironmentCredential authentication unavailable
```

The scope format is:
```
https://<eventhubs-namespace>.servicebus.windows.net/.default
```

### 7. Container names in kubectl set image

The container names in the data-plane pods are `kafka-broker-receiver` and
`kafka-broker-dispatcher` (not `receiver`/`dispatcher`):

```bash
kubectl set image deployment/kafka-broker-receiver -n knative-eventing \
  kafka-broker-receiver="${IMAGE}"   # not just "receiver"
```

## Configuration Reference

### Auth Secret (`kafka-auth-secret`)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: kafka-auth-secret
  namespace: knative-eventing
stringData:
  protocol: SASL_SSL
  sasl.mechanism: OAUTHBEARER
  # No user/password — tokens come from Workload Identity
```

### ConfigMap (`config-kafka-broker-data-plane`)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: config-kafka-broker-data-plane
  namespace: knative-eventing
data:
  config-kafka-broker-producer.properties: |
    bootstrap.servers=evhns-knative-lab.servicebus.windows.net:9093
    security.protocol=SASL_SSL
    sasl.mechanism=OAUTHBEARER
    sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required scope="https://evhns-knative-lab.servicebus.windows.net/.default";
    sasl.login.callback.handler.class=io.conduktor.kafka.security.oauthbearer.azure.AzureManagedIdentityCallbackHandler
  config-kafka-broker-consumer.properties: |
    bootstrap.servers=evhns-knative-lab.servicebus.windows.net:9093
    security.protocol=SASL_SSL
    sasl.mechanism=OAUTHBEARER
    sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required scope="https://evhns-knative-lab.servicebus.windows.net/.default";
    sasl.login.callback.handler.class=io.conduktor.kafka.security.oauthbearer.azure.AzureManagedIdentityCallbackHandler
```

### ServiceAccount annotations

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: knative-kafka-broker-data-plane
  namespace: knative-eventing
  annotations:
    azure.workload.identity/client-id: "<managed-identity-client-id>"
  labels:
    azure.workload.identity/use: "true"
```

### Terraform resources

| Resource | Purpose |
|---|---|
| `azurerm_user_assigned_identity.kafka_broker` | Managed Identity for the Kafka Broker |
| `azurerm_federated_identity_credential.kafka_broker` | Binds `knative-kafka-broker-data-plane` SA → MI |
| `azurerm_federated_identity_credential.kafka_controller` | Binds `kafka-controller` SA → MI |
| `azurerm_role_assignment.kafka_broker_eventhubs` | `Azure Event Hubs Data Owner` on the namespace |

## Known Limitations

### Control plane (Go) cannot use OAUTHBEARER

The Go control plane uses Sarama, which has its own OAUTHBEARER implementation.
The `sasl.login.callback.handler.class` is a **Java class** — Sarama cannot use it.
The Go side currently only supports MSK token providers for OAUTHBEARER.

This means **topic creation and admin operations** still require either:

- SAS credentials on the control plane (separate secret)
- Pre-created topics
- A future Go-side Azure token provider (out of scope for this PoC)

### Requires operator-supplied JAR

The Conduktor callback handler is **not shipped** with KNative. The operator must
build the derived images and maintain them across KNative upgrades.

### Upstream fix needed for production

This PoC works by injecting OAUTHBEARER properties via the ConfigMap, which bypasses
the empty `KafkaClientsAuth` OAUTHBEARER code path. For production use, an upstream
PR to `knative-extensions/eventing-kafka-broker` should allow passing
`sasl.jaas.config` and `sasl.login.callback.handler.class` through the auth secret
directly.

## Next Steps

- [ ] **Phase 2:** Token refresh soak test (2.5h+ continuous operation)
- [ ] **Phase 3:** Upstream PR to `eventing-kafka-broker` (Java data plane)
- [ ] **Phase 4:** Upstream PR to `eventing-kafka-broker` (Go control plane)
- [ ] **Phase 5:** Tests
- [ ] **Phase 6:** Upstream documentation
