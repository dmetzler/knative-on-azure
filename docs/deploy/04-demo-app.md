# 4. Demo Application

The demo application showcases the full messaging flow:

- **Backend** (FastAPI) — receives CloudEvents, exposes REST API, WebSocket for live updates, ASB explorer
- **Frontend** (React + Vite) — two tabs: Interactive Demo (send/receive events) and Jupyter Notebook; ASB Explorer sidebar
- **Jupyter** (JupyterLab) — interactive notebook demonstrating the `messaging` Python library

```
┌─────────────────────────────────────────────────┐
│                    Frontend                      │
│  ┌──────────────┐  ┌──────────┐  ┌───────────┐ │
│  │ Interactive   │  │ Jupyter  │  │   ASB     │ │
│  │ Demo Tab     │  │ Tab      │  │ Explorer  │ │
│  └──────┬───────┘  └────┬─────┘  └─────┬─────┘ │
│         │               │              │        │
│         └───────┬───────┘              │        │
│                 │ nginx proxy          │        │
│         ┌───────▼───────┐      ┌───────▼──────┐ │
│         │   Backend     │      │  ASB APIs    │ │
│         │   /api/*      │      │  /api/asb/*  │ │
│         │   /events/    │      └──────────────┘ │
│         │   /ws         │                       │
│         └───────┬───────┘                       │
│                 │                                │
│         ┌───────▼───────┐                       │
│         │ Kafka Broker   │                      │
│         │ (default)      │                      │
│         └───────────────┘                       │
└─────────────────────────────────────────────────┘
```

## Prerequisites

- Steps [1](01-infrastructure.md)–[3](03-kafka-broker.md) completed (AKS + KNative + Kafka Broker)
- [Camel-K integrations](06-camel-k-asb.md) deployed (for ASB ↔ Broker bridge)
- ACR login: `az acr login --name acrknativelab`
- Node.js 18+ (for frontend build)

## Build

From the **repo root**:

```bash
# Frontend (must build locally — cross-platform Docker OOMs on ARM Macs)
cd demo/frontend && npm install && npm run build && cd ../..

# All three images
make build-all
```

Or individually:

```bash
make build-backend
make build-frontend   # runs npm build + Docker
make build-jupyter
```

## Push

```bash
make acr-login
make push-all\n```

## Deploy

### Secret

Create the ASB connection string secret (if not already done via Terraform):

```bash
kubectl apply -f demo/k8s/asb-secret.yaml
```

> **Note:** `asb-secret.yaml` is a template. Update the `connectionString` value with your actual connection string. A future iteration will use Workload Identity instead.

### Application

```bash
make deploy-demo
```

This deploys:
- `demo-backend` — Deployment + ClusterIP Service (port 80 → 8000)
- `demo-frontend` — Deployment + LoadBalancer Service (port 80)
- `demo-jupyter` — Deployment + ClusterIP Service (port 80 → 8888)
- KNative Triggers (routes events from Broker to backend)

### One-command deploy

```bash
make all   # acr-login → build-all → push-all → deploy-all
```

## Verify

```bash
# Check pods are running
kubectl get pods -l app=demo-backend
kubectl get pods -l app=demo-frontend
kubectl get pods -l app=demo-jupyter

# Get the frontend external IP
kubectl get svc demo-frontend -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

Open `http://<EXTERNAL_IP>` in your browser.

## Architecture

### Backend endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/messages` | List received CloudEvents |
| DELETE | `/api/messages` | Clear received events |
| POST | `/api/send` | Publish a CloudEvent to the Broker |
| POST | `/events/` | CloudEvent receiver (used by KNative Triggers) |
| GET | `/ws` | WebSocket for live event stream |
| GET | `/api/asb/queues` | List ASB queues with message counts |
| GET | `/api/asb/peek/{queue}` | Peek messages in an ASB queue |
| POST | `/api/asb/send/{queue}` | Send a message to an ASB queue |
| DELETE | `/api/asb/purge/{queue}` | Purge queue + its dead-letter queue |
| GET | `/healthz` | Health check |

### Triggers

The demo uses two triggers defined in `demo/k8s/trigger.yaml`:

- **`demo-backend-trigger`** — routes `com.example.demo` events to the backend
- **`event-display-trigger`** — routes all events to event-display (debug sink)

### Nginx routing

The frontend nginx proxies:
- `/api/*` → `http://demo-backend/api/`
- `/ws` → `http://demo-backend/ws` (WebSocket upgrade)
- `/jupyter/*` → `http://demo-jupyter/jupyter/` (JupyterLab)

## Rebuild & Redeploy

After code changes:

```bash
make build-all push-all redeploy-demo
```

Or for a single component:

```bash
make build-backend && docker push $(ACR)/demo-backend:latest
kubectl rollout restart deployment/demo-backend
```

## Jupyter Notebook

The notebook (`demo/jupyter/notebooks/messaging-demo.ipynb`) walks through:

1. **Import & Configure** — initialize `MessageBus` with `KNativeEventingPublisher`
2. **Create a CloudEvent** — construct and inspect an event
3. **Publish** — send an event to the Kafka Broker
4. **Event Stream** — display widget for live event visualization
5. **Register a Handler** — `@bus.handler()` decorator + `stream.append(event)`
6. **Dispatch locally** — `bus.dispatch()` to invoke handlers without HTTP
7. **Summary** — Python API + KNative Trigger YAML reference

The `messaging` library is included in the Jupyter container via `PYTHONPATH`.
