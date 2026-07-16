# ----- Workload Identity for KNative Kafka Broker -----
# This creates a Managed Identity that the Kafka Broker pods can use
# to authenticate to Event Hubs via OAUTHBEARER instead of SAS keys.

# User-Assigned Managed Identity for the Kafka Broker
resource "azurerm_user_assigned_identity" "kafka_broker" {
  name                = "id-knative-kafka-broker"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  tags = {
    environment = "lab"
    project     = "knative-eventing"
  }
}

# Federated Identity Credential: binds K8s ServiceAccount → Azure Managed Identity
# The Kafka Broker data plane pods run as SA "knative-kafka-broker-data-plane"
# in namespace "knative-eventing"
resource "azurerm_federated_identity_credential" "kafka_broker" {
  name                = "knative-kafka-broker"
  resource_group_name = azurerm_resource_group.main.name
  parent_id           = azurerm_user_assigned_identity.kafka_broker.id

  audience = ["api://AzureADTokenExchange"]
  issuer   = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject  = "system:serviceaccount:knative-eventing:knative-kafka-broker-data-plane"
}

# Also federate the controller SA (it needs admin access for topic creation)
resource "azurerm_federated_identity_credential" "kafka_controller" {
  name                = "knative-kafka-controller"
  resource_group_name = azurerm_resource_group.main.name
  parent_id           = azurerm_user_assigned_identity.kafka_broker.id

  audience = ["api://AzureADTokenExchange"]
  issuer   = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject  = "system:serviceaccount:knative-eventing:kafka-controller"
}

# Role Assignment: Azure Event Hubs Data Owner on the namespace
resource "azurerm_role_assignment" "kafka_broker_eventhubs" {
  scope                = azurerm_eventhub_namespace.main.id
  role_definition_name = "Azure Event Hubs Data Owner"
  principal_id         = azurerm_user_assigned_identity.kafka_broker.principal_id
}

# Federated credential for the token-refresh CronJob ServiceAccount
resource "azurerm_federated_identity_credential" "kafka_token_refresh" {
  name                = "knative-kafka-token-refresh"
  resource_group_name = azurerm_resource_group.main.name
  parent_id           = azurerm_user_assigned_identity.kafka_broker.id

  audience = ["api://AzureADTokenExchange"]
  issuer   = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject  = "system:serviceaccount:knative-eventing:kafka-token-refresh"
}
