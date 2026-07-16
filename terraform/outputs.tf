output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "aks_cluster_name" {
  value = azurerm_kubernetes_cluster.main.name
}

output "aks_kube_config_command" {
  value = "az aks get-credentials --resource-group ${azurerm_resource_group.main.name} --name ${azurerm_kubernetes_cluster.main.name}"
}

output "eventhubs_namespace" {
  value = azurerm_eventhub_namespace.main.name
}

output "eventhub_name" {
  value = azurerm_eventhub.knative.name
}

output "eventhub_listen_connection_string" {
  value     = azurerm_eventhub_authorization_rule.knative_listen.primary_connection_string
  sensitive = true
}

output "eventhub_send_connection_string" {
  value     = azurerm_eventhub_authorization_rule.knative_send.primary_connection_string
  sensitive = true
}
