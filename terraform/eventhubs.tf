# ----- Event Hubs Namespace -----
resource "azurerm_eventhub_namespace" "main" {
  name                = var.eventhubs_namespace_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "Standard"
  capacity            = 1

  tags = {
    environment = "lab"
    project     = "knative-eventing"
  }
}

# ----- Event Hub -----
resource "azurerm_eventhub" "knative" {
  name              = var.eventhub_name
  namespace_id      = azurerm_eventhub_namespace.main.id
  partition_count   = 2
  message_retention = 1
}

# ----- Consumer Group for KNative -----
resource "azurerm_eventhub_consumer_group" "knative" {
  name                = "knative-eventing"
  namespace_name      = azurerm_eventhub_namespace.main.name
  eventhub_name       = azurerm_eventhub.knative.name
  resource_group_name = azurerm_resource_group.main.name
}

# ----- Shared Access Policy for KNative to consume -----
resource "azurerm_eventhub_authorization_rule" "knative_listen" {
  name                = "knative-listen"
  namespace_name      = azurerm_eventhub_namespace.main.name
  eventhub_name       = azurerm_eventhub.knative.name
  resource_group_name = azurerm_resource_group.main.name

  listen = true
  send   = false
  manage = false
}

# ----- Policy for sending test events -----
resource "azurerm_eventhub_authorization_rule" "knative_send" {
  name                = "knative-send"
  namespace_name      = azurerm_eventhub_namespace.main.name
  eventhub_name       = azurerm_eventhub.knative.name
  resource_group_name = azurerm_resource_group.main.name

  listen = false
  send   = true
  manage = false
}
