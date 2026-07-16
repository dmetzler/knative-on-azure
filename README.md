# KNative on Azure — Event Hubs Kafka Broker POC

> **Proof of Concept:** Run a KNative Eventing [Kafka Broker](https://knative.dev/docs/eventing/brokers/broker-types/kafka-broker/) on AKS, backed by [Azure Event Hubs](https://learn.microsoft.com/en-us/azure/event-hubs/azure-event-hubs-kafka-overview) in Kafka compatibility mode.

## Goal

Demonstrate that Azure Event Hubs can serve as a **drop-in Kafka backend** for KNative Eventing's Kafka Broker — no Kafka cluster to manage, no adapters needed. CloudEvents flow through the standard KNative Broker/Trigger model, with Event Hubs handling persistence and delivery under the hood.

## Architecture

```
Azure Subscription
└── Resource Group (rg-knative-lab)
    ├── VNet (10.0.0.0/16)
    │   └── Subnet: AKS nodes (10.0.1.0/24)
    ├── AKS Cluster (2× Standard_D4s_v5, K8s 1.36)
    │   ├── KNative Serving (Kourier ingress)
    │   ├── KNative Eventing (Kafka Broker)
    │   └── Demo apps (hello-knative, event-display)
    └── Event Hubs Namespace (Standard tier, Kafka-enabled)
        └── Event Hub ←── Kafka Broker (SASL_SSL :9093)
```

**Event flow:**
```
CloudEvent (HTTP POST) → Kafka Broker Ingress → Azure Event Hubs → Kafka Broker Dispatcher → Trigger → Your App
```

## Quick Start

```bash
# 1. Deploy infrastructure (AKS + Event Hubs)
cd terraform
cp terraform.tfvars.example terraform.tfvars  # add your subscription_id
terraform init && terraform apply

# 2. Connect to AKS
az aks get-credentials --resource-group rg-knative-lab --name aks-knative-lab

# 3. Install KNative Serving + Eventing + Kafka Broker
./scripts/install-knative.sh
./scripts/reinstall-kafka-components.sh  # fix v1.22.1 manifest bug

# 4. Wire Event Hubs as Kafka Broker backend
./scripts/setup-kafka-broker.sh

# 5. Deploy demo apps
kubectl apply -f k8s/demo/hello-knative.yaml

# 6. Test the event flow
kubectl run curl --image=curlimages/curl --rm -it --restart=Never -- \
  -X POST http://kafka-broker-ingress.knative-eventing.svc.cluster.local/default/default \
  -H 'Content-Type: application/json' \
  -H 'Ce-Id: test-1' -H 'Ce-Specversion: 1.0' \
  -H 'Ce-Type: dev.knative.test' -H 'Ce-Source: /test' \
  -d '{"msg": "Hello from Event Hubs!"}'

# Check the event arrived
kubectl logs -l serving.knative.dev/service=event-display -c user-container
```

## Prerequisites

- Azure CLI (`az`) authenticated
- Terraform >= 1.5
- kubectl >= 1.30
- Python 3 (for manifest patching)

## Structure

```
terraform/          # IaC — AKS, VNet, Event Hubs
k8s/demo/           # Demo KNative services + Kafka Broker manifest
scripts/            # Setup and install scripts
docs/               # Full documentation (mkdocs)
```

## Documentation

Full step-by-step guide, architecture details, and troubleshooting: see [`docs/`](docs/).

Build locally with [MkDocs Material](https://squidfork.github.io/mkdocs-material/):

```bash
pip install mkdocs-material
mkdocs serve
```

## Key Learnings

- **Event Hubs Kafka mode works** with KNative's Kafka Broker out of the box
- Auth: SASL_SSL + PLAIN, username = `$ConnectionString` (literal), password = SAS connection string
- KNative v1.22.1 has a bug: `kafka-broker-dispatcher` StatefulSet references a missing volume — patched by `reinstall-kafka-components.sh`
- The Kafka Broker ingress service is `kafka-broker-ingress` (not `broker-ingress` from the MT-Channel broker)
- Event Hubs Standard tier `default.topic.replication.factor` must be `1` (managed service)

## License

MIT
