# ----- Azure Container Registry (for Camel-K builds) -----
resource "azurerm_container_registry" "main" {
  name                = var.acr_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "Basic"
  admin_enabled       = true

  tags = {
    environment = "lab"
    project     = "knative-eventing"
  }
}
