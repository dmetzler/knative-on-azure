# Teardown

## Remove Everything

### 1. Delete KNative resources

```bash
kubectl delete broker default -n default
kubectl delete ksvc hello-knative event-display -n default
kubectl delete trigger event-display-trigger -n default
```

### 2. Destroy Azure infrastructure

```bash
cd terraform
terraform destroy
```

This removes:

- AKS cluster (and all workloads)
- Event Hubs namespace and hub
- Virtual Network
- Resource Group

!!! warning "Data Loss"
    `terraform destroy` is irreversible. All events in Event Hubs and workloads in AKS will be permanently deleted.

## Partial Cleanup

### Remove just KNative (keep AKS + Event Hubs)

```bash
# Remove Kafka components
kubectl delete -f "https://github.com/knative-extensions/eventing-kafka-broker/releases/download/knative-v1.22.1/eventing-kafka-broker.yaml"
kubectl delete -f "https://github.com/knative-extensions/eventing-kafka-broker/releases/download/knative-v1.22.1/eventing-kafka-source.yaml"

# Remove KNative Eventing
kubectl delete -f "https://github.com/knative/eventing/releases/download/knative-v1.22.1/eventing-core.yaml"
kubectl delete -f "https://github.com/knative/eventing/releases/download/knative-v1.22.1/eventing-crds.yaml"

# Remove Kourier
kubectl delete -f "https://github.com/knative/net-kourier/releases/download/knative-v1.22.1/kourier.yaml"

# Remove KNative Serving
kubectl delete -f "https://github.com/knative/serving/releases/download/knative-v1.22.1/serving-core.yaml"
kubectl delete -f "https://github.com/knative/serving/releases/download/knative-v1.22.1/serving-crds.yaml"
```

### Remove just Event Hubs (keep AKS + KNative)

```bash
cd terraform
terraform destroy -target=azurerm_eventhub_consumer_group.knative \
  -target=azurerm_eventhub_authorization_rule.knative_listen \
  -target=azurerm_eventhub_authorization_rule.knative_send \
  -target=azurerm_eventhub.knative \
  -target=azurerm_eventhub_namespace.main
```

## Cost Awareness

| Resource | Approximate Monthly Cost |
|----------|-------------------------|
| AKS (2× D4s_v5) | ~€250 |
| Event Hubs (Standard, 1 TU) | ~€10 |
| Public IP (Kourier LB) | ~€3 |
| **Total** | **~€263/month** |

!!! tip "Save Money"
    When not in use, scale AKS to 0 nodes:

    ```bash
    az aks nodepool scale --resource-group rg-knative-lab \
      --cluster-name aks-knative-lab --name system --node-count 0
    ```

    Or just `terraform destroy` and redeploy when needed — it takes ~10 minutes.
