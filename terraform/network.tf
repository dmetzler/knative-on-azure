# ----- Resource Group -----
resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
}

# ----- VNet & Subnets -----
resource "azurerm_virtual_network" "main" {
  name                = "vnet-knative-lab"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  address_space       = var.vnet_address_space
}

resource "azurerm_subnet" "nodes" {
  name                 = "snet-aks-nodes"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.subnet_nodes_prefix]
}


