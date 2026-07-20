# KNative on Azure — Event-Driven Messaging with Kafka Broker & Azure Service Bus

> **Lab / Demo:** Run KNative Eventing on AKS with a Kafka Broker backed by Azure Event Hubs, bridged to Azure Service Bus via Camel-K. Includes a full interactive demo app with a Python messaging library.

## Goal

Demonstrate a production-ready event-driven architecture on Azure:
- **Azure Event Hubs** as a drop-in Kafka backend for KNative's Kafka Broker
- **Azure Service Bus** bridged via Camel-K integrations (bidirectional)
- **Python messaging library** — transport-agnostic CloudEvents bus with handlers
- **Interactive demo** — React frontend + FastAPI backend + JupyterLab notebook

## Architecture

```
Azure Subscription
└── Resource Group (rg-knative-lab)
    ├── VNet (10.0.0.0/16)
    │   └── Subnet: AKS nodes (10.0.1.0/24)
    ├── AKS Cluster (2× Standard_D4s_v5, K8s 1.36)
    │   ├── KNative Eventing (Kafka Broker)
    │   ├── Camel-K Integrations (ASB ↔ Broker bridge)
    │   └── Demo App (backend + frontend + jupyter)
    ├── Event Hubs Namespace (Kafka-enabled)
    │   └── Event Hub ← Kafka Broker backend
    └── Service Bus Namespace (sbns-knative-lab)
        ├── knative-inbound   (external → broker)
        ├── knative-outbound  (broker → external)
        └── knative-dlq       (dead letters)
```

**Event flows:**
```
# Internal: CloudEvents via Kafka Broker
App → POST /api/send → Kafka Broker → Trigger → Backend /events/

# Inbound: External → ASB → Broker
External System → ASB queue → Camel-K → Kafka Broker → Trigger → Your App

# Outbound: Broker → ASB → External
Your App → Kafka Broker → Camel-K → ASB queue → External System
```

## Quick Start

```bash
# 1. Deploy infrastructure
cd terraform
cp terraform.tfvars.example terraform.tfvars
terraform init && terraform apply

# 2. Connect to AKS
az aks get-credentials --resource-group rg-knative-lab --name aks-knative-lab

# 3. Install KNative + Kafka Broker
./scripts/install-knative.sh
./scripts/setup-kafka-broker.sh

# 4. Install Camel-K + ASB bridge
./scripts/install-camel-k.sh
./scripts/setup-camel-integrations.sh

# 5. Build & deploy the demo app
make all   # acr-login → build → push → deploy
```

Get the frontend IP and open it:
```bash
kubectl get svc demo-frontend -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

## Prerequisites

- Azure CLI (`az`) authenticated with Owner or Contributor role
- Terraform >= 1.5
- kubectl >= 1.30
- Node.js 18+ (frontend build)
- Docker (with `--platform linux/amd64` support)
- Python 3.12+

## Structure

```
terraform/              # IaC — AKS, VNet, Event Hubs, Service Bus, ACR
scripts/                # Setup and install scripts
k8s/
  integrations/         # Camel-K Integration manifests (ASB ↔ Broker)
  demo/                 # KNative Serving demos (hello-knative, event-display)
demo/
  backend/              # FastAPI backend (CloudEvent handler, ASB explorer)
  frontend/             # React frontend (Vite + shadcn/ui)
  jupyter/              # JupyterLab with messaging demo notebook
  k8s/                  # K8s manifests for demo app
messaging/              # Python messaging library (transport-agnostic)
docs/                   # Full deployment guide (mkdocs)
```

## Documentation

Full step-by-step deployment guide: [`docs/`](docs/)

| Step | Doc |
|------|-----|
| Infrastructure (AKS, VNet, Event Hubs, ASB) | [01-infrastructure.md](docs/deploy/01-infrastructure.md) |
| KNative Serving & Eventing | [02-knative.md](docs/deploy/02-knative.md) |
| Kafka Broker setup | [03-kafka-broker.md](docs/deploy/03-kafka-broker.md) |
| Demo application | [04-demo-app.md](docs/deploy/04-demo-app.md) |
| Camel-K ASB bridge | [06-camel-k-asb.md](docs/deploy/06-camel-k-asb.md) |

## Key Learnings

- **Event Hubs Kafka mode works** with KNative's Kafka Broker — no Kafka cluster to manage
- **Camel-K** provides a lightweight, GitOps-friendly bridge between ASB and KNative
- Auth: Event Hubs uses SASL_SSL + PLAIN, username = `$ConnectionString` (literal)
- The Kafka Broker ingress service is `kafka-broker-ingress` (not `broker-ingress`)
- Event Hubs Standard tier requires `default.topic.replication.factor=1`
- ASB messages must be sent as structured CloudEvents (JSON body with `specversion`) for Camel-K routing

## License

MIT
