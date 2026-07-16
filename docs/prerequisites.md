# Prerequisites

## Tools

| Tool | Version | Purpose |
|------|---------|---------|
| [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) | >= 2.60 | Azure resource management |
| [Terraform](https://developer.hashicorp.com/terraform/downloads) | >= 1.5 | Infrastructure as Code |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | >= 1.30 | Kubernetes CLI |
| [Python 3](https://www.python.org/) | >= 3.8 | Script patching (for KNative manifest fixes) |

## Azure

- An Azure subscription with permissions to create:
    - Resource Groups
    - Virtual Networks
    - AKS clusters
    - Event Hubs namespaces

!!! warning "Corporate Subscriptions"
    On corporate subscriptions, you may **not** have permission to:

    - Register Resource Providers (handled by `resource_provider_registrations = "none"` in Terraform)
    - Create Role Assignments (we don't need them with CNI overlay mode)

    The Terraform config accounts for both of these limitations.

## Azure Authentication

```bash
# Login to Azure
az login

# Verify your subscription
az account show

# Get your subscription ID (you'll need it for terraform.tfvars)
az account show --query id -o tsv
```

## Resource Providers

The following Azure Resource Providers are required and will be auto-registered by Terraform:

- `Microsoft.ContainerService` (AKS)
- `Microsoft.Network` (VNet)
- `Microsoft.EventHub` (Event Hubs)
- `Microsoft.Compute` (VMs)
- `Microsoft.Storage` (Storage)
- `Microsoft.ManagedIdentity` (Managed Identity)
- `Microsoft.Authorization` (RBAC)
- `Microsoft.OperationalInsights` (Monitoring)

If auto-registration fails (409 conflicts on corporate subscriptions), register manually:

```bash
az provider register --namespace Microsoft.ContainerService
az provider register --namespace Microsoft.Network
az provider register --namespace Microsoft.EventHub
```
