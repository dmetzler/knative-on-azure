# 1. Infrastructure (Terraform)

## Overview

Terraform deploys:

- **Resource Group** (`rg-knative-lab`)
- **Virtual Network** with AKS node subnet
- **AKS Cluster** (2 nodes, Standard_D4s_v5, Kubernetes 1.36.1, Azure CNI overlay)
- **Event Hubs Namespace** (Standard tier, Kafka-enabled) + Event Hub + consumer group

## Configuration

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
subscription_id = "your-azure-subscription-id"
location        = "westeurope"    # optional, default: westeurope
```

### Available Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `subscription_id` | *(required)* | Azure subscription ID |
| `location` | `westeurope` | Azure region |
| `resource_group_name` | `rg-knative-lab` | Resource group name |
| `cluster_name` | `aks-knative-lab` | AKS cluster name |
| `node_count` | `2` | Number of AKS nodes |
| `node_vm_size` | `Standard_D4s_v5` | VM size (4 vCPU, 16 GB) |
| `kubernetes_version` | `1.36.1` | Kubernetes version |
| `eventhubs_namespace_name` | `evhns-knative-lab` | Event Hubs namespace |
| `eventhub_name` | `knative-events` | Event Hub (Kafka topic) name |

## Deploy

```bash
terraform init
terraform apply
```

!!! info "Deployment Time"
    AKS cluster creation takes **~5 minutes**. Event Hubs is near-instant.

## Verify

```bash
# Check outputs
terraform output

# Connect to AKS
az aks get-credentials --resource-group rg-knative-lab --name aks-knative-lab

# Verify nodes
kubectl get nodes
```

Expected output:

```
NAME                             STATUS   ROLES    AGE   VERSION
aks-system-xxxxx-vmss000000      Ready    <none>   5m    v1.36.1
aks-system-xxxxx-vmss000001      Ready    <none>   5m    v1.36.1
```

## What Terraform Creates

### Network

- **VNet** `vnet-knative-lab` (`10.0.0.0/16`)
- **Subnet** `snet-aks-nodes` (`10.0.1.0/24`) — AKS nodes live here
- Pod IPs are managed by **CNI overlay** (virtual, not on the VNet)

### AKS

- System-assigned managed identity (no service principal)
- OIDC issuer + workload identity enabled (for future Azure AD integration)
- Calico network policy
- Kubernetes service CIDR: `172.16.0.0/16`

### Event Hubs

- **Namespace** (Standard tier) — Kafka endpoint auto-enabled
- **Event Hub** `knative-events` (2 partitions, 1-day retention)
- **Consumer Group** `knative-eventing`
- **SAS Policies**: `knative-listen` (consume) and `knative-send` (produce/test)

!!! note "Corporate Subscription Notes"
    - `resource_provider_registrations = "none"` avoids 409 conflicts on shared subscriptions
    - Only required providers are explicitly registered
    - No Role Assignments (not needed with CNI overlay, avoids 403 on corporate subs)
