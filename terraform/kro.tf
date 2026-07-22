# KRO - installed via ArgoCD instead of Terraform
# The Terraform helm provider prefixes 'v' to OCI chart versions,
# which is incompatible with KRO's tag format (0.9.2 vs v0.9.2).
# See k8s/argocd-apps/kro.yaml for the ArgoCD-managed installation.
