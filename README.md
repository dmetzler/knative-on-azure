# KNative on Azure — Platform Engineering POC

## What is this?

A proof-of-concept that shows how to build a **developer platform on AKS** that handles security automatically. The developer writes a simple YAML describing their service, and the platform generates all the security and networking configuration.

The goal: **make the secure path the easy path.**

## The Problem

In a typical Kubernetes setup, deploying a service means creating and maintaining:
- A Deployment (or KNative Service)
- A Service account
- NetworkPolicies (L3/L4 firewall rules)
- Istio AuthorizationPolicies (L7 identity-based access control)
- mTLS configuration
- Autoscaling rules

That's 6+ YAML files per service, all manually maintained and easy to get wrong. Developers either skip security entirely ("it works without policies") or copy-paste from other services and end up with overly permissive rules.

## The Solution: AcmeService

We use **KRO (Kube Resource Orchestrator)** to define a custom resource called `AcmeService`. The developer declares *what* their service needs, and KRO generates *how* to secure it.

### What the developer writes

```yaml
apiVersion: platform.acme.com/v1alpha1
kind: AcmeService
metadata:
  name: demo-backend
spec:
  template:
    metadata:
      labels:
        app: demo-backend
    spec:
      containers:
        - name: backend
          image: myregistry.azurecr.io/demo-backend:latest
          ports:
            - containerPort: 8000
          env:
            - name: BROKER_URL
              value: "http://kafka-broker-ingress.knative-eventing.svc.cluster.local/default/default"
  service:
    port: 8000
  scaling:
    type: static           # or "knative" for scale-to-zero
  security:
    ingress: false          # not exposed externally
    eventingSink: true      # receives CloudEvents from the broker
    eventingSource: true    # publishes CloudEvents to the broker
    allowFrom:
      - demo-frontend       # only the frontend can call me
```

### What the platform generates

From that single resource, KRO automatically creates:

| Generated Resource | Purpose |
|---|---|
| **ServiceAccount** `demo-backend` | Unique identity in the Istio mesh |
| **Deployment** or **KNative Service** | Based on `scaling.type` |
| **NetworkPolicy** `demo-backend-deny-ingress` | Default deny — no traffic in unless allowed |
| **NetworkPolicy** `demo-backend-allow-eventing` | KNative dispatcher/activator can deliver events |
| **NetworkPolicy** `demo-backend-allow-from-demo-frontend` | Only frontend pods can reach the backend |
| **AuthorizationPolicy** `demo-backend-allow-eventing` | Istio L7: only knative-eventing namespace |
| **AuthorizationPolicy** `demo-backend-allow-from-demo-frontend` | Istio L7: only the `demo-frontend` service account |

**Two layers of security, zero effort from the developer.**

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│  AKS Cluster                                                       │
│                                                                     │
│  ┌─────────────┐    ┌──────────────────────────────────────────┐   │
│  │   KRO       │    │  default namespace (mTLS STRICT)         │   │
│  │ Controller  │    │                                          │   │
│  │             │    │  ┌──────────┐       ┌──────────────┐     │   │
│  │ Watches     │───▶│  │ frontend │──────▶│   backend    │     │   │
│  │ AcmeService │    │  │ (static) │ allow │   (static)   │     │   │
│  │ instances   │    │  └──────────┘  From └──────┬───────┘     │   │
│  └─────────────┘    │       ▲                    │  ▲          │   │
│                     │       │ ingress        pub │  │ events   │   │
│                     │       │                    ▼  │          │   │
│  ┌──────────────┐   │  ┌────┴─────┐    ┌─────────────────┐    │   │
│  │ Istio (AKS)  │   │  │   LB     │    │  Kafka Broker   │    │   │
│  │ asm-1-29     │   │  └──────────┘    │  (Event Hubs)   │    │   │
│  │ mTLS between │   │                  └────────┬────────┘    │   │
│  │ all pods     │   │                           │             │   │
│  └──────────────┘   │                    ┌──────┴───────┐     │   │
│                     │                    │  event-display│     │   │
│  ┌──────────────┐   │                    │  (knative)   │     │   │
│  │ ArgoCD       │   │                    │  scale-to-0  │     │   │
│  │ GitOps       │   │                    └──────────────┘     │   │
│  └──────────────┘   └──────────────────────────────────────────┘   │
│                                                                     │
│  ┌──────────────────┐  ┌──────────────────┐  ┌─────────────────┐   │
│  │ knative-serving   │  │ knative-eventing  │  │ kourier-system  │   │
│  │ (mTLS PERMISSIVE) │  │ (mTLS PERMISSIVE) │  │ (PERMISSIVE)   │   │
│  └──────────────────┘  └──────────────────┘  └─────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

## Why each technology?

### KRO (Kube Resource Orchestrator)
**Problem:** Every service needs 5-8 Kubernetes resources for proper security. Developers won't maintain them.
**Solution:** KRO lets us define a `ResourceGraphDefinition` that takes one simple input and generates all the resources. It supports conditional resources (`includeWhen`) and collections (`forEach`) to dynamically generate policies based on the service's security requirements.

### KNative Serving
**Problem:** Microservices that only handle events shouldn't run 24/7.
**Solution:** `scaling.type: knative` deploys a KNative Service that:
- **Scales to zero** when idle (saves cost)
- **Wakes on demand** when events arrive (sub-second cold start)
- **Manages revisions** — every config change creates a new revision, enabling canary/blue-green deployments
- **Concurrency-based autoscaling** — better for event-driven workloads than CPU-based HPA

### KNative Eventing + Kafka Broker (Azure Event Hubs)
**Problem:** Services need to communicate asynchronously without tight coupling.
**Solution:** A Kafka-backed broker (using Azure Event Hubs as the Kafka backend). Services publish CloudEvents to the broker and subscribe via Triggers. This gives us:
- **Loose coupling** — services don't know about each other
- **Event replay** — Kafka retains events, failed deliveries are retried
- **Fan-out** — one event can trigger multiple subscribers

### Istio Service Mesh (AKS addon)
**Problem:** NetworkPolicies (L3/L4) can't verify *who* is calling — any pod in an allowed namespace can reach any other pod. A compromised pod in `knative-eventing` could call any service.
**Solution:** Istio adds **L7 identity-based security**:
- **mTLS everywhere** — all pod-to-pod traffic is encrypted and authenticated
- **AuthorizationPolicies** — rules based on cryptographic identity (service accounts), not just IP/namespace
- **Two-layer model:** NetworkPolicy blocks unauthorized connections *before* they reach the pod. Istio AuthorizationPolicy verifies identity *at* the pod.

### Why both NetworkPolicy AND Istio?

Defense in depth:

| Layer | What it does | Example |
|---|---|---|
| **NetworkPolicy** (Calico, L3/L4) | Blocks connections at the network level | "Only pods from `knative-eventing` namespace can reach port 8000" |
| **AuthorizationPolicy** (Istio, L7) | Verifies identity of the caller | "Only the `demo-frontend` service account can call this service" |

NetworkPolicies are enforced by the CNI — they work even if Istio is misconfigured. Istio AuthorizationPolicies add fine-grained identity checks. Together, they provide robust security that doesn't rely on a single layer.

### ArgoCD (GitOps)
**Problem:** `kubectl apply` from a developer's laptop is not auditable, reproducible, or safe.
**Solution:** ArgoCD watches the Git repo and applies changes automatically. Every security policy change goes through a Git commit and PR review before deployment. The cluster state always matches what's in Git.

## mTLS Configuration

| Namespace | Istio Sidecar | mTLS Mode | Why |
|---|---|---|---|
| `default` | ✅ Injected | **STRICT** | Application pods — all traffic must be mTLS |
| `knative-serving` | ✅ Injected | **PERMISSIVE** | Internal components use plaintext for webhooks, probes |
| `knative-eventing` | ✅ Injected | **PERMISSIVE** | Dispatcher needs mTLS to reach `default`, but internal traffic is mixed |
| `kourier-system` | ✅ Injected | **PERMISSIVE** | Ingress gateway — accepts external plaintext, speaks mTLS to pods |

## Scaling Modes

| Mode | Backend | Use case | Example |
|---|---|---|---|
| `static` | Deployment + Service | Always-on services, APIs, UIs | `demo-frontend`, `demo-backend` |
| `knative` | KNative Service (ksvc) | Event-driven, bursty, idle-most-of-the-time | `event-display`, `broker-to-asb` |

## Repo Structure

```
├── terraform/              # Infrastructure: AKS, Event Hubs, ACR, Istio, DAPR, ArgoCD, KRO
├── k8s/
│   ├── root-app.yaml       # ArgoCD bootstrap (apply once manually)
│   ├── argocd-apps/        # App-of-apps pattern
│   │   ├── knative-config.yaml
│   │   ├── demo-apps.yaml
│   │   └── kro.yaml
│   ├── knative/            # Broker config, triggers
│   ├── apps/               # Demo apps + manual security policies
│   │   ├── backend.yaml, frontend.yaml, trigger.yaml
│   │   ├── peer-authentication.yaml          # mTLS STRICT for default
│   │   ├── authz-policies.yaml               # Istio AuthorizationPolicies
│   │   └── network-policy-*.yaml             # NetworkPolicies
│   ├── istio/              # Istio config for KNative namespaces
│   │   └── peer-authentication-knative.yaml  # mTLS PERMISSIVE
│   └── kro/                # KRO ResourceGraphDefinition
│       ├── acmeservice-rgd.yaml              # The AcmeService CRD definition
│       └── examples/
│           ├── demo-backend.yaml
│           ├── demo-frontend.yaml
│           └── event-display.yaml
├── demo-backend/           # Python FastAPI backend (CloudEvents + REST)
└── demo-frontend/          # React frontend
```

## Bootstrap

```bash
# 1. Deploy infrastructure
cd terraform && terraform apply

# 2. Bootstrap ArgoCD (once)
kubectl apply -f k8s/root-app.yaml

# 3. Enable Istio sidecar injection
for ns in default knative-serving knative-eventing kourier-system; do
  kubectl label namespace $ns istio.io/rev=asm-1-29
done

# 4. Apply KNative namespace Istio config
kubectl apply -f k8s/istio/peer-authentication-knative.yaml

# 5. Restart pods for sidecar injection
kubectl rollout restart deployment -n knative-serving
kubectl rollout restart deployment -n knative-eventing
kubectl rollout restart statefulset -n knative-eventing
kubectl rollout restart deployment -n kourier-system

# 6. ArgoCD syncs everything else from Git
```

## Security Flow Example

When `demo-frontend` calls `demo-backend`:

1. **NetworkPolicy** `demo-backend-allow-from-demo-frontend` checks: is the source pod labeled `app: demo-frontend`? ✅
2. **Istio sidecar** intercepts the connection and establishes mTLS
3. **AuthorizationPolicy** `demo-backend-allow-from-demo-frontend` checks: is the source identity `cluster.local/ns/default/sa/demo-frontend`? ✅
4. Request reaches the backend container

If a rogue pod tries to call the backend:
1. **NetworkPolicy** blocks it (wrong label) ❌ — connection never reaches the pod
2. Even if NetworkPolicy is misconfigured, **AuthorizationPolicy** blocks it (wrong service account) ❌

## What's Next

- [ ] Deploy KRO and validate the `AcmeService` ResourceGraphDefinition
- [ ] Replace manual policies in `k8s/apps/` with `AcmeService` instances
- [ ] Add DAPR integration for state/pubsub
- [ ] Upstream PR: KNative OAUTHBEARER support for Azure Event Hubs
