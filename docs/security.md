# Security Model

## The Problem

In a standard Kubernetes deployment, each service requires multiple security resources to be properly isolated:

- **NetworkPolicies** — Layer 3/4 firewall rules
- **ServiceAccounts** — Pod identity
- **Istio AuthorizationPolicies** — Layer 7 identity-based access control
- **mTLS configuration** — Encryption and mutual authentication

That's 5-8 YAML files per service, all manually maintained. In practice, developers either skip security entirely ("it works without policies") or copy-paste from other services and end up with overly permissive rules.

**Our goal: make the secure path the easy path.**

## Two-Layer Defense

We enforce security at two independent layers. If one fails, the other still blocks unauthorized traffic.

### Layer 1: NetworkPolicy (Calico, L3/L4)

NetworkPolicies are enforced by the CNI plugin (Azure CNI with Calico in our case). They control which pods can establish TCP connections to which other pods, based on labels and namespaces.

```yaml
# Example: only pods from knative-eventing can reach demo-backend on port 8000
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: demo-backend-allow-eventing
spec:
  podSelector:
    matchLabels:
      app: demo-backend
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: knative-eventing
      ports:
        - port: 8000
```

!!! info "Default Deny"
    We apply a **default deny ingress** policy per service. No traffic is allowed unless explicitly permitted by another policy.

### Layer 2: AuthorizationPolicy (Istio, L7)

Istio AuthorizationPolicies verify the **cryptographic identity** of the caller via mTLS certificates. This is stronger than NetworkPolicies because:

- NetworkPolicies check *where* traffic comes from (namespace, labels)
- AuthorizationPolicies check *who* is calling (service account identity)

```yaml
# Example: only the demo-frontend service account can call demo-backend
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: demo-backend-allow-from-demo-frontend
spec:
  selector:
    matchLabels:
      app: demo-backend
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - cluster.local/ns/default/sa/demo-frontend
```

### Why Both?

| Scenario | NetworkPolicy | AuthorizationPolicy |
|----------|:---:|:---:|
| Attacker in wrong namespace | ❌ Blocked | ❌ Blocked |
| Compromised pod, right namespace, wrong SA | ✅ Allowed | ❌ Blocked |
| Istio sidecar misconfigured | N/A (works independently) | ⚠️ May not enforce |
| CNI plugin bug | ⚠️ May not enforce | N/A (works independently) |

Neither layer depends on the other. Even if Istio is completely down, NetworkPolicies still enforce network isolation at the kernel level.

## mTLS Configuration

### Strict vs Permissive

| Namespace | Mode | Reason |
|-----------|------|--------|
| `default` | **STRICT** | Application pods — all traffic must be mutually authenticated |
| `knative-serving` | **PERMISSIVE** | Internal KNative components use plaintext for webhooks and probes |
| `knative-eventing` | **PERMISSIVE** | Dispatcher needs mTLS to reach `default`, but internal traffic is mixed |
| `kourier-system` | **PERMISSIVE** | Accepts external plaintext from LoadBalancer, speaks mTLS to pods |

!!! warning "Why not STRICT everywhere?"
    KNative's internal components (webhooks, admission controllers, liveness probes from kubelet) communicate without mTLS. Setting STRICT on these namespaces breaks KNative. PERMISSIVE allows both plaintext and mTLS, so the sidecar can speak mTLS to pods in `default` while still accepting internal plaintext.

### Istio Sidecar Injection

All namespaces participating in the mesh are labeled for injection:

```bash
kubectl label namespace <ns> istio.io/rev=asm-1-29
```

!!! tip "Resource Overhead"
    Each Istio sidecar adds CPU/memory overhead. For a POC with many KNative pods, reduce the sidecar resource requests:
    ```bash
    kubectl annotate namespace <ns> \
      sidecar.istio.io/proxyCPU=10m \
      sidecar.istio.io/proxyMemory=64Mi
    ```

## Security Flow Example

When `demo-frontend` calls `demo-backend`:

```
demo-frontend pod
    │
    │ 1. NetworkPolicy check: source pod has label app=demo-frontend? ✅
    │
    ▼
demo-backend's Istio sidecar
    │
    │ 2. mTLS handshake: verify frontend's certificate
    │ 3. AuthorizationPolicy: source is cluster.local/ns/default/sa/demo-frontend? ✅
    │
    ▼
demo-backend container (port 8000)
```

When a **rogue pod** tries to call `demo-backend`:

```
rogue-pod
    │
    │ 1. NetworkPolicy check: source pod has label app=demo-frontend? ❌ BLOCKED
    │    Connection never reaches the pod.
    │
    │ Even if NetworkPolicy is misconfigured:
    │ 2. AuthorizationPolicy: source is cluster.local/ns/default/sa/rogue-pod? ❌ BLOCKED
    │
    ✗ Request denied
```

## KNative-Specific Considerations

### Ports

KNative Serving uses multiple ports for its internal routing:

| Port | Component | Purpose |
|------|-----------|---------|
| 8080 | user-container | Application port |
| 8012 | queue-proxy | HTTP/1.1 ingress |
| 8013 | queue-proxy | H2C (HTTP/2 cleartext) — used by the private service |
| 8443 | queue-proxy | HTTPS |
| 9090, 9091 | queue-proxy | Metrics, profiling |

!!! warning "Don't forget port 8013"
    The KNative private service routes traffic on port 80 → targetPort **8013** (not 8012 or 8080). If your NetworkPolicy doesn't allow 8013, the dispatcher will get 504 Gateway Timeout errors.

### Namespaces That Need Access

For a pod that receives CloudEvents (an eventing sink), three namespaces need access:

| Namespace | Component | Why |
|-----------|-----------|-----|
| `knative-eventing` | Kafka dispatcher | Delivers events to the subscriber |
| `knative-serving` | Activator | Wakes scaled-to-zero pods, proxies initial requests |
| `kourier-system` | Kourier | Routes traffic to the correct pod/revision |
