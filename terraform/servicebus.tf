# ----- Azure Service Bus Namespace -----
resource "azurerm_servicebus_namespace" "main" {
  name                = var.servicebus_namespace_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "Standard"

  tags = {
    environment = "lab"
    project     = "knative-eventing"
  }
}

# ----- Queue: receives CloudEvents from external producers -----
resource "azurerm_servicebus_queue" "inbound" {
  name         = "knative-inbound"
  namespace_id = azurerm_servicebus_namespace.main.id

  max_delivery_count  = 10
  lock_duration       = "PT30S"
  default_message_ttl = "P1D"
}

# ----- Queue: receives CloudEvents routed out from the Broker -----
resource "azurerm_servicebus_queue" "outbound" {
  name         = "knative-outbound"
  namespace_id = azurerm_servicebus_namespace.main.id

  max_delivery_count  = 10
  lock_duration       = "PT30S"
  default_message_ttl = "P1D"
}

# ----- Queue: Dead Letter Queue for invalid messages -----
resource "azurerm_servicebus_queue" "dlq" {
  name         = "knative-dlq"
  namespace_id = azurerm_servicebus_namespace.main.id

  max_delivery_count  = 3
  lock_duration       = "PT30S"
  default_message_ttl = "P7D"
}

# ----- Topic: fan-out pattern (optional, for pub/sub) -----
resource "azurerm_servicebus_topic" "events" {
  name         = "knative-events"
  namespace_id = azurerm_servicebus_namespace.main.id

  default_message_ttl = "P1D"
}

resource "azurerm_servicebus_subscription" "all_events" {
  name               = "all-events"
  topic_id           = azurerm_servicebus_topic.events.id
  max_delivery_count = 10
  lock_duration      = "PT30S"
}

# ----- SAS Policy: full access for Camel-K (send + listen + manage) -----
resource "azurerm_servicebus_namespace_authorization_rule" "camel_k" {
  name         = "camel-k"
  namespace_id = azurerm_servicebus_namespace.main.id

  listen = true
  send   = true
  manage = true
}
