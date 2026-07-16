variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "westeurope"
}

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
  default     = "rg-knative-lab"
}

variable "cluster_name" {
  description = "AKS cluster name"
  type        = string
  default     = "aks-knative-lab"
}

variable "node_count" {
  description = "Number of AKS nodes"
  type        = number
  default     = 2
}

variable "node_vm_size" {
  description = "VM size for AKS nodes"
  type        = string
  default     = "Standard_D4s_v5"
}

variable "kubernetes_version" {
  description = "Kubernetes version for AKS"
  type        = string
  default     = "1.36.1"
}

variable "vnet_address_space" {
  description = "VNet address space"
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

variable "subnet_nodes_prefix" {
  description = "Subnet prefix for AKS nodes"
  type        = string
  default     = "10.0.1.0/24"
}

variable "subnet_pods_prefix" {
  description = "Subnet prefix for AKS pods (Azure CNI overlay)"
  type        = string
  default     = "10.0.4.0/22"
}

variable "eventhubs_namespace_name" {
  description = "Event Hubs namespace name"
  type        = string
  default     = "evhns-knative-lab"
}

variable "eventhub_name" {
  description = "Event Hub name"
  type        = string
  default     = "knative-events"
}

variable "servicebus_namespace_name" {
  description = "Azure Service Bus namespace name"
  type        = string
  default     = "sbns-knative-lab"
}
