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

# Kafka bootstrap server
output "kafka_bootstrap_server" {
  value = "${azurerm_eventhub_namespace.main.name}.servicebus.windows.net:9093"
}

# SASL connection string (for Kafka SASL_SSL auth)
output "kafka_sasl_connection_string" {
  value     = azurerm_eventhub_namespace.main.default_primary_connection_string
  sensitive = true
}

output "eventhub_listen_connection_string" {
  value     = azurerm_eventhub_authorization_rule.knative_listen.primary_connection_string
  sensitive = true
}

output "eventhub_send_connection_string" {
  value     = azurerm_eventhub_authorization_rule.knative_send.primary_connection_string
  sensitive = true
}

# ----- Service Bus outputs -----
output "servicebus_namespace" {
  value = azurerm_servicebus_namespace.main.name
}

output "servicebus_connection_string" {
  value     = azurerm_servicebus_namespace_authorization_rule.camel_k.primary_connection_string
  sensitive = true
}

# ----- ACR outputs -----
output "acr_login_server" {
  value = azurerm_container_registry.main.login_server
}

output "acr_admin_username" {
  value     = azurerm_container_registry.main.admin_username
  sensitive = true
}

output "acr_admin_password" {
  value     = azurerm_container_registry.main.admin_password
  sensitive = true
}

# ----- Workload Identity outputs -----
output "kafka_broker_identity_client_id" {
  description = "Client ID of the Managed Identity for Kafka Broker Workload Identity"
  value       = azurerm_user_assigned_identity.kafka_broker.client_id
}

output "kafka_broker_identity_principal_id" {
  description = "Principal ID (for role assignment by an admin)"
  value       = azurerm_user_assigned_identity.kafka_broker.principal_id
}

output "eventhubs_namespace_id" {
  description = "Event Hubs namespace resource ID (for role assignment scope)"
  value       = azurerm_eventhub_namespace.main.id
}

output "aks_oidc_issuer_url" {
  description = "OIDC issuer URL of the AKS cluster"
  value       = azurerm_kubernetes_cluster.main.oidc_issuer_url
}
