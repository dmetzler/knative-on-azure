# k8s/ — Kubernetes manifests managed by ArgoCD

## Structure

```
k8s/
├── root-app.yaml          # Bootstrap: apply manually once to start ArgoCD
├── argocd-apps/           # App-of-apps: each file = one ArgoCD Application
│   ├── knative-config.yaml
│   └── demo-apps.yaml
├── knative/               # KNative broker config, triggers
│   ├── kafka-broker-config.yaml
│   └── broker.yaml
└── apps/                  # Demo applications, services
```

## Bootstrap

After `terraform apply` installs ArgoCD:

```bash
kubectl apply -f k8s/root-app.yaml
```

ArgoCD then takes over — all changes via Git commits.

## What stays in Terraform vs ArgoCD

| Layer | Tool |
|-------|------|
| AKS, networking, Event Hubs, Service Bus, ACR | Terraform |
| DAPR extension, Istio addon | Terraform |
| Managed Identities, role assignments | Terraform |
| KNative config, brokers, triggers | ArgoCD |
| KRO (future) | ArgoCD |
| Applications | ArgoCD |

## Secrets

`kafka-auth-secret` contains SAS credentials — managed outside ArgoCD (created manually or via External Secrets Operator).
