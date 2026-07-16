# KNative on Azure (AKS)

Infrastructure-as-Code lab: AKS cluster with KNative Serving/Eventing, backed by Azure Event Hubs.

## Architecture

```
Azure Subscription
└── Resource Group (rg-knative-lab)
    ├── VNet (10.0.0.0/16)
    │   ├── Subnet: AKS nodes (10.0.1.0/24)
    │   └── Subnet: AKS pods (10.0.2.0/22)
    ├── AKS Cluster (2x Standard_D4s_v5)
    │   ├── KNative Serving (Kourier ingress)
    │   ├── KNative Eventing
    │   └── Demo app (hello-knative)
    └── Event Hubs Namespace
        └── Event Hub → KNative EventSource
```

## Prerequisites

- Azure CLI (`az`) authenticated
- Terraform >= 1.5
- kubectl
- helm 3

## Quick Start

```bash
# 1. Deploy infrastructure
cd terraform
cp terraform.tfvars.example terraform.tfvars  # edit with your values
terraform init
terraform apply

# 2. Get AKS credentials
az aks get-credentials --resource-group rg-knative-lab --name aks-knative-lab

# 3. Install KNative + demo app
./scripts/install-knative.sh
kubectl apply -f k8s/demo/

# 4. (Optional) Setup Event Hubs as Eventing source
./scripts/setup-eventhubs-source.sh
```

## Structure

```
terraform/          # IaC - AKS, VNet, Event Hubs
k8s/knative/        # KNative operator manifests
k8s/demo/           # Demo KNative service
scripts/            # Setup/install scripts
```
