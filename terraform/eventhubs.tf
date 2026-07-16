# ----- Event Hubs Namespace (Standard tier required for Kafka) -----
resource "azurerm_eventhub_namespace" "main" {
  name                = var.eventhubs_namespace_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "Standard"
  capacity            = 1

  # Kafka is automatically enabled on Standard/Premium tier
  # Endpoint: <namespace>.servicebus.windows.net:9093

  tags = {
    environment = "lab"
    project     = "knative-eventing"
  }
}

# ----- Event Hub (= Kafka topic) -----
resource "azurerm_eventhub" "knative" {
  name              = var.eventhub_name
  namespace_id      = azurerm_eventhub_namespace.main.id
  partition_count   = 2
  message_retention = 1
}

# ----- Consumer Group for KNative (= Kafka consumer group) -----
resource "azurerm_eventhub_consumer_group" "knative" {
  name                = "knative-eventing"
  namespace_name      = azurerm_eventhub_namespace.main.name
  eventhub_name       = azurerm_eventhub.knative.name
  resource_group_name = azurerm_resource_group.main.name
}

# ----- SAS Policy: Listen (Kafka consumer) -----
resource "azurerm_eventhub_authorization_rule" "knative_listen" {
  name                = "knative-listen"
  namespace_name      = azurerm_eventhub_namespace.main.name
  eventhub_name       = azurerm_eventhub.knative.name
  resource_group_name = azurerm_resource_group.main.name

  listen = true
  send   = false
  manage = false
}

# ----- SAS Policy: Send (Kafka producer / test) -----
resource "azurerm_eventhub_authorization_rule" "knative_send" {
  name                = "knative-send"
  namespace_name      = azurerm_eventhub_namespace.main.name
  eventhub_name       = azurerm_eventhub.knative.name
  resource_group_name = azurerm_resource_group.main.name

  listen = false
  send   = true
  manage = false
}
