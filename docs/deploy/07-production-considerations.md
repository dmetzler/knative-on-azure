# Camel-K in Production

## The Build Problem

By default, Camel-K builds container images **inside the cluster** using a builder pod (Kaniko/Spectrum). This is convenient for development but problematic in production:

- **Compliance:** images are not scanned, signed, or audited before running
- **Security:** the cluster needs `AcrPush` (or equivalent registry write access)
- **Reliability:** build pods compete for resources and can fail under pressure
- **Reproducibility:** no guarantee that two builds from the same source produce the same image

## Pre-Built IntegrationKits

The production pattern is to **build outside the cluster** and reference pre-built images.

### CI Pipeline (build + push)

```yaml
# GitHub Actions example
- name: Build Camel-K integration image
  run: |
    cd camel-quarkus
    mvn package -DskipTests \
      -Dquarkus.container-image.build=true \
      -Dquarkus.container-image.push=true \
      -Dquarkus.container-image.registry=acrknativelab.azurecr.io \
      -Dquarkus.container-image.group=camel \
      -Dquarkus.container-image.name=asb-bridge \
      -Dquarkus.container-image.tag=${{ github.sha }}
```

For native builds (faster startup, lower memory):
```bash
mvn package -Pnative -DskipTests \
  -Dquarkus.native.container-build=true \
  -Dquarkus.container-image.build=true \
  -Dquarkus.container-image.push=true \
  -Dquarkus.container-image.registry=acrknativelab.azurecr.io \
  -Dquarkus.container-image.group=camel \
  -Dquarkus.container-image.name=asb-bridge \
  -Dquarkus.container-image.tag=${{ github.sha }}
```

### Cluster-Side (deploy only)

Reference the pre-built image directly — **no build happens in the cluster**:

```yaml
apiVersion: camel.apache.org/v1
kind: Integration
metadata:
  name: asb-to-broker
spec:
  integrationKit:
    name: asb-kit-v1
  flows:
    - from:
        uri: "azure-servicebus:knative-inbound"
        # ...
```

With a matching IntegrationKit:

```yaml
apiVersion: camel.apache.org/v1
kind: IntegrationKit
metadata:
  name: asb-kit-v1
spec:
  image: acrknativelab.azurecr.io/camel/asb-bridge:abc123
```

### Alternative: `kamel run --image`

Skip the IntegrationKit CRD entirely:

```bash
kamel run integration.yaml --image acrknativelab.azurecr.io/camel/asb-bridge:abc123
```

## Registry Configuration

If you still need in-cluster builds (e.g., dev/staging), configure the IntegrationPlatform to use your private registry:

```yaml
apiVersion: camel.apache.org/v1
kind: IntegrationPlatform
metadata:
  name: camel-k
spec:
  build:
    registry:
      address: acrknativelab.azurecr.io
      organization: camel
    maxRunningBuilds: 1
    strategy: routine
    timeout: 10m
```

The cluster identity needs `AcrPush` on the registry. On AKS with managed identity:

```bash
ACR_ID=$(az acr show --name acrknativelab --query id -o tsv)
KUBELET_ID=$(az aks show -g rg-knative-lab -n aks-knative-lab \
  --query identityProfile.kubeletidentity.objectId -o tsv)

az role assignment create --role AcrPush --assignee $KUBELET_ID --scope $ACR_ID
```

> **Production recommendation:** do NOT grant `AcrPush` to the cluster. Build in CI, push from CI, cluster only pulls.

## Security Checklist

| Concern | Dev/Lab | Production |
|---------|---------|------------|
| Image build | In-cluster (Kaniko) | CI pipeline |
| Registry access | AcrPull + AcrPush | AcrPull only |
| Image scanning | Optional | Mandatory (Defender/Trivy) |
| Image signing | None | Cosign / Notation |
| Supply chain | Maven Central direct | Mirrored + audited deps |
| Secrets | K8s Secret (plain) | Workload Identity + Key Vault |
| IntegrationKit | Auto-generated | Pinned to scanned image digest |

## Comparison with Standard Deployments

Camel-K with pre-built images behaves almost identically to a standard Kubernetes Deployment:

```
Standard K8s:    CI → build image → push → Deployment (image: ...)
Camel-K prebuilt: CI → build image → push → IntegrationKit (image: ...) → Integration
```

The extra layer (IntegrationKit + Integration CRDs) gives you:
- **Camel-K operator management** — health checks, restarts, trait configuration
- **Declarative route definition** — routes live in the Integration CR, not baked into the image
- **Trait system** — configure JVM options, resource limits, scaling, prometheus, etc. via CRD annotations

The trade-off: an extra operator to maintain and an extra abstraction layer. For simple integrations, a standard Deployment with a Quarkus Camel app achieves the same result with less machinery.

## When to Use What

| Approach | Best For |
|----------|----------|
| Camel-K + in-cluster build | Rapid prototyping, dev environments |
| Camel-K + pre-built kit | Production with compliance requirements |
| Standard Deployment + Camel Quarkus | Teams that prefer full control, fewer moving parts |
| Dapr pub/sub | When you need more than eventing (state, actors, service invocation) |
