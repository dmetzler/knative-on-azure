# ----- KRO (Kubernetes Resource Orchestrator) -----
resource "helm_release" "kro" {
  name             = "kro"
  chart            = "oci://registry.k8s.io/kro/charts/kro"
  version          = "0.9.2"
  namespace        = "kro-system"
  create_namespace = true

  depends_on = [azurerm_kubernetes_cluster.main]
}
