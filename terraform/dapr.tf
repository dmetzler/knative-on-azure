resource "azurerm_kubernetes_cluster_extension" "dapr" {
  name           = "dapr"
  cluster_id     = azurerm_kubernetes_cluster.main.id
  extension_type = "Microsoft.Dapr"

  release_train = "stable"
}
