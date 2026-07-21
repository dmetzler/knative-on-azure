# AcmeService — Platform Abstraction with KRO

## The Vision

A developer should deploy a service by declaring **what** it needs, not **how** to wire it. The platform handles security, scaling, and networking automatically.

```yaml
apiVersion: platform.acme.com/v1alpha1
kind: AcmeService
metadata:
  name: my-service
spec:
  template: ...      # What to run (containers, env, resources)
  service: ...       # How to expose it (port, type)
  scaling: ...       # How it scales (knative or static)
  security: ...      # Who can talk to it
```

## Why KRO?

**KRO (Kube Resource Orchestrator)** lets us define a `ResourceGraphDefinition` — a template that takes a simple custom resource as input and generates multiple Kubernetes resources as output.

Without KRO, deploying a secured service requires the developer to create and maintain:

| Resource | Count | Total |
|----------|:-----:|:-----:|
| ServiceAccount | 1 | 1 |
| Deployment or KNative Service | 1 | 2 |
| Service (if static) | 1 | 3 |
| NetworkPolicy (deny) | 1 | 4 |
| NetworkPolicy (per allowed source) | N | 4+N |
| AuthorizationPolicy (per allowed source) | N | 4+2N |
| NetworkPolicy (eventing) | 0-1 | 5+2N |
| AuthorizationPolicy (eventing) | 0-1 | 6+2N |

For a typical service with 2 callers and eventing: **10 YAML resources**. With KRO: **1 YAML resource**.

## Spec Reference

### `spec.template`

Follows the KNative Serving pattern (`spec.template.spec.containers[]`). This makes it familiar and extensible — you can add volumes, env vars, resource limits, probes, init containers, etc.

```yaml
spec:
  template:
    metadata:
      labels:
        app: my-service         # Required: used for pod selection
      annotations: {}
    spec:
      containers:
        - name: app
          image: myregistry.azurecr.io/my-service:v1
          ports:
            - containerPort: 8080
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: db-credentials
                  key: url
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
```

### `spec.service`

```yaml
spec:
  service:
    port: 8080                  # Service port (maps to container port)
    type: ClusterIP             # ClusterIP (default) or LoadBalancer
```

!!! note
    When `scaling.type` is `knative`, the Service is managed by KNative Serving — the `spec.service` is only used for NetworkPolicy port rules.

### `spec.scaling`

```yaml
spec:
  scaling:
    type: knative               # "knative" or "static"
    minScale: 0                 # Minimum replicas (knative only)
    maxScale: 10                # Maximum replicas (knative only)
    concurrency: 100            # Target concurrent requests per pod (knative only)
```

| Mode | What's Generated | Use Case |
|------|------------------|----------|
| `static` | Deployment + Service | Always-on services: APIs, UIs, databases |
| `knative` | KNative Service (ksvc) | Event-driven, bursty workloads, scale-to-zero |

#### When to Use KNative

Use `scaling.type: knative` when:

- The service processes **events** and is idle most of the time
- You want **scale-to-zero** to save costs
- You need **revision management** (canary, blue-green)
- **Concurrency-based autoscaling** fits better than CPU-based HPA

Use `scaling.type: static` when:

- The service must be **always available** (frontends, APIs with strict latency)
- It manages **persistent connections** (WebSockets, gRPC streams)
- It has **local state** that shouldn't be disrupted by scale events

### `spec.security`

```yaml
spec:
  security:
    ingress: false              # Exposed via external LoadBalancer?
    eventingSink: true          # Receives CloudEvents from KNative dispatcher?
    eventingSource: true        # Publishes CloudEvents to the broker?
    allowFrom:                  # Which other AcmeServices can call this one?
      - frontend
      - admin-api
```

Each field generates specific security resources:

| Field | NetworkPolicy | AuthorizationPolicy |
|-------|:---:|:---:|
| `ingress: true` | Allow all ingress on service port | Allow all (external traffic has no mTLS identity) |
| `eventingSink: true` | Allow from `knative-eventing`, `knative-serving`, `kourier-system` | Allow from those namespaces |
| `allowFrom: [svc]` | Allow from pods labeled `app: <svc>` | Allow principal `cluster.local/ns/<ns>/sa/<svc>` |

!!! info "Service Identity"
    Each AcmeService gets its own **ServiceAccount** (name = service name). This ServiceAccount becomes the pod's identity in the Istio mesh, used by AuthorizationPolicies to verify *who* is calling.

## Generated Resources

For this input:

```yaml
apiVersion: platform.acme.com/v1alpha1
kind: AcmeService
metadata:
  name: demo-backend
spec:
  scaling:
    type: static
  security:
    eventingSink: true
    allowFrom:
      - demo-frontend
```

KRO generates:

```
ServiceAccount/demo-backend
Deployment/demo-backend
Service/demo-backend
NetworkPolicy/demo-backend-deny-ingress              # always
NetworkPolicy/demo-backend-allow-eventing             # eventingSink=true
NetworkPolicy/demo-backend-allow-from-demo-frontend   # allowFrom collection
AuthorizationPolicy/demo-backend-allow-eventing       # eventingSink=true
AuthorizationPolicy/demo-backend-allow-from-demo-frontend  # allowFrom collection
```

8 resources from 1 YAML. Add another caller to `allowFrom` → 2 more resources generated automatically.

## Collections (allowFrom)

KRO's `forEach` directive creates one resource per element in an array. For `allowFrom`, we generate both a NetworkPolicy and an AuthorizationPolicy per allowed source service:

```yaml
# In the ResourceGraphDefinition:
- id: netpol-allow-from
  forEach:
    - svc: ${schema.spec.security.allowFrom}
  template:
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
    metadata:
      name: ${schema.metadata.name}-allow-from-${svc}
    # ...
```

When the user updates `allowFrom` (adds or removes a service), KRO automatically creates or deletes the corresponding policies.

## Examples

See `k8s/kro/examples/` for complete AcmeService definitions:

- **demo-backend** — Static deployment, event sink, called by frontend
- **demo-frontend** — Static deployment, external ingress
- **event-display** — KNative service, event sink, scale-to-zero
