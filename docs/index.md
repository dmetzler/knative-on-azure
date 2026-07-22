# KNative on Azure — Platform Engineering POC

A proof-of-concept demonstrating how to build a **developer platform on AKS** where security is automatic, not optional.

## The Pitch

A developer writes **one YAML file** describing their service. The platform generates all the security and networking configuration — NetworkPolicies, Istio AuthorizationPolicies, mTLS, service accounts — automatically.

**The secure path is the easy path.**

## What's Inside

| Component | Purpose |
|-----------|---------|
| **AKS Cluster** | Kubernetes 1.36.1, Azure CNI overlay, 2× Standard_D4s_v5 |
| **KNative Serving** | Scale-to-zero serverless workloads with Kourier ingress |
| **KNative Eventing** | CloudEvents routing with Kafka Broker |
| **Azure Event Hubs** | Kafka-compatible event backbone |
| **Istio** (AKS addon) | mTLS service mesh, L7 AuthorizationPolicies |
| **KRO** | Platform abstraction — generates resources from `AcmeService` CRD |
| **ArgoCD** | GitOps — every change goes through Git |
| **DAPR** | Distributed application runtime (sidecar for state, pubsub) |

## Key Concepts

- [Architecture](architecture.md) — Infrastructure layout and event flow
- [Security Model](security.md) — Two-layer defense: NetworkPolicy + Istio
- [AcmeService](acmeservice.md) — Platform CRD powered by KRO
- [GitOps](gitops.md) — ArgoCD app-of-apps pattern

## Quick Start

```bash
# 1. Deploy infrastructure
cd terraform && terraform apply

# 2. Connect to AKS
az aks get-credentials --resource-group rg-knative-lab --name aks-knative-lab

# 3. Install KNative
./scripts/install-knative.sh

# 4. Bootstrap ArgoCD (once)
kubectl apply -f k8s/root-app.yaml

# 5. Enable Istio + mTLS
for ns in default knative-serving knative-eventing kourier-system; do
  kubectl label namespace $ns istio.io/rev=asm-1-29
done
kubectl apply -f k8s/istio/peer-authentication-knative.yaml
```

See the [Deployment Guide](deploy/01-infrastructure.md) for detailed step-by-step instructions.
