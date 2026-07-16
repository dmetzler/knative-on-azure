# KNative on Azure

A complete Infrastructure-as-Code lab deploying **KNative Serving & Eventing** on **Azure Kubernetes Service (AKS)**, with the KNative Kafka Broker backed by **Azure Event Hubs** in Kafka compatibility mode.

## What You'll Get

| Component | Details |
|-----------|---------|
| **AKS Cluster** | Kubernetes 1.36.1, 2× Standard_D4s_v5, Azure CNI overlay |
| **KNative Serving** | Scale-to-zero serverless workloads with Kourier ingress |
| **KNative Eventing** | CloudEvents routing with Kafka Broker |
| **Azure Event Hubs** | Kafka-compatible event backbone (Standard tier) |
| **Demo apps** | hello-knative (Serving) + event-display (Eventing sink) |

## Why Event Hubs + Kafka Mode?

Azure Event Hubs natively exposes a **Kafka-compatible endpoint** on Standard/Premium tiers. This means:

- **No adapter needed** — KNative's mature Kafka Broker speaks directly to Event Hubs
- **Portable** — swap to a real Kafka cluster (Confluent, Strimzi) without changing manifests
- **Battle-tested** — the KNative Kafka Broker is used in production by Red Hat OpenShift Serverless

## Quick Start

```bash
# 1. Deploy infrastructure
cd terraform
cp terraform.tfvars.example terraform.tfvars  # add your subscription_id
terraform init && terraform apply

# 2. Connect to AKS
az aks get-credentials --resource-group rg-knative-lab --name aks-knative-lab

# 3. Install KNative
./scripts/install-knative.sh
./scripts/reinstall-kafka-components.sh  # fix v1.22.1 manifest bugs

# 4. Wire Event Hubs as Kafka Broker
./scripts/setup-kafka-broker.sh

# 5. Deploy demo apps
kubectl apply -f k8s/demo/

# 6. Test!
kubectl run curl --image=curlimages/curl --rm -it --restart=Never -- \
  -X POST http://kafka-broker-ingress.knative-eventing.svc.cluster.local/default/default \
  -H 'Ce-Id: test-1' -H 'Ce-Specversion: 1.0' \
  -H 'Ce-Type: dev.knative.test' -H 'Ce-Source: /test' \
  -H 'Content-Type: application/json' \
  -d '{"msg": "Hello from Event Hubs!"}'
```

See the [Deployment Guide](deploy/01-infrastructure.md) for detailed step-by-step instructions.
