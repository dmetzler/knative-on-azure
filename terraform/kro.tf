# ----- KRO (Kubernetes Resource Orchestrator) -----
resource "helm_release" "kro" {
  name             = "kro"
  repository       = "oci://registry.k8s.io/kro/charts"
  chart            = "kro"
  namespace        = "kro-system"
  create_namespace = true

  depends_on = [azurerm_kubernetes_cluster.main]
}
