terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
  }

  # Local backend for now. Migrate to azurerm blob later if needed.
  # backend "azurerm" {
  #   resource_group_name  = "rg-terraform-state"
  #   storage_account_name = "stknativetfstate"
  #   container_name       = "tfstate"
  #   key                  = "knative-lab.tfstate"
  # }
}

provider "azurerm" {
  features {}
  subscription_id                = var.subscription_id
  resource_provider_registrations = "none"

  # Only register what we actually need
  resource_providers_to_register = [
    "Microsoft.ContainerService",
    "Microsoft.Network",
    "Microsoft.EventHub",
    "Microsoft.Compute",
    "Microsoft.Storage",
    "Microsoft.ManagedIdentity",
    "Microsoft.Authorization",
    "Microsoft.OperationalInsights",
    "Microsoft.KubernetesConfiguration",
  ]
}

provider "helm" {
  kubernetes {
    host                   = azurerm_kubernetes_cluster.main.kube_config[0].host
    client_certificate     = base64decode(azurerm_kubernetes_cluster.main.kube_config[0].client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.main.kube_config[0].client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.main.kube_config[0].cluster_ca_certificate)
  }
}
