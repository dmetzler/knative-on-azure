# Camel-K: Azure Service Bus ↔ Broker Bridge

## Overview

[Apache Camel-K](https://camel.apache.org/camel-k/) bridges Azure Service Bus (ASB) and the KNative Kafka Broker using Camel integrations that run as pods on AKS.

```
External System                    KNative Cluster
     │                                   │
     │  ┌─────────────────┐              │
     ├──► ASB queue        │  Camel-K     │
     │  │ 'knative-inbound'├────────────► Kafka Broker (default)
     │  └─────────────────┘              │       │
     │                                   │       │ Trigger (type filter)
     │  ┌──────────────────┐             │       ▼
     │  │ ASB queue         │  Camel-K    │  Broker → ASB Integration
     ◄──┤ 'knative-outbound'◄────────────┤  (type = asb.outbound.*)
     │  └──────────────────┘             │
```

**Two flows:**

| Direction | Source | Destination | Event Type |
|-----------|--------|-------------|------------|
| Inbound  | ASB queue `knative-inbound` | Kafka Broker `default` | `com.azure.servicebus.inbound` |
| Outbound | Kafka Broker `default` | ASB queue `knative-outbound` | `asb.outbound.*` |

## Setup

### 1. Deploy Service Bus (Terraform)

```bash
cd terraform
terraform apply  # creates ASB namespace + queues + topic
```

Creates:
- **Namespace** `sbns-knative-lab` (Standard tier)
- **Queues** `knative-inbound`, `knative-outbound`
- **Topic** `knative-events` + subscription `all-events` (for fan-out)
- **SAS policy** `camel-k` (send + listen + manage)

### 2. Install Camel-K Operator

```bash
./scripts/install-camel-k.sh
```

Installs the Camel-K operator v2.10.0 via Kustomize (no OLM needed).

### 3. Deploy Integrations

```bash
./scripts/setup-camel-integrations.sh
```

This:
1. Creates a Secret with the ASB connection string
2. Deploys the `asb-to-broker` integration (reads queue → posts CloudEvent)
3. Deploys the `broker-to-asb` integration (receives filtered events → sends to queue)

## Test

### Inbound: ASB → Broker → event-display

Send a message to the inbound queue:

```bash
az servicebus message send \
  --resource-group rg-knative-lab \
  --namespace-name sbns-knative-lab \
  --queue-name knative-inbound \
  --body '{"order_id": "12345", "status": "created"}'
```

Check event-display receives it as a CloudEvent:

```bash
kubectl logs -l serving.knative.dev/service=event-display -c user-container --tail=10
```

Expected:
```
☁️  cloudevents.Event
Context Attributes,
  specversion: 1.0
  type: com.azure.servicebus.inbound
  source: /azure/servicebus/knative-inbound
  id: <exchange-id>
Data,
  {"order_id": "12345", "status": "created"}
```

### Outbound: Broker → ASB

Send a CloudEvent with type `asb.outbound` to the broker:

```bash
kubectl run curl --image=curlimages/curl --rm -it --restart=Never -- \
  -X POST http://kafka-broker-ingress.knative-eventing.svc.cluster.local/default/default \
  -H 'Content-Type: application/json' \
  -H 'Ce-Id: out-1' -H 'Ce-Specversion: 1.0' \
  -H 'Ce-Type: asb.outbound' -H 'Ce-Source: /test' \
  -d '{"notification": "processed"}'
```

Check the message arrived in ASB:

```bash
az servicebus message peek \
  --resource-group rg-knative-lab \
  --namespace-name sbns-knative-lab \
  --queue-name knative-outbound
```

## Customizing Event Routing

### Change which events go outbound

Edit `k8s/integrations/broker-to-asb.yaml` — the `knative:event/<type>` URI defines which CloudEvent types are routed:

```yaml
from:
  uri: "knative:event/asb.outbound"  # matches type prefix
```

### Add more routes

Create additional `Integration` manifests for different event types or different ASB queues/topics. Each Camel-K Integration runs as its own pod with independent scaling.

### Use Topics instead of Queues

For fan-out (one event → multiple subscribers), switch to the ASB topic:

```yaml
to:
  uri: "azure-servicebus:knative-events"
  parameters:
    serviceBusType: topic
    connectionString: "{{azure.servicebus.connectionString}}"
```

## Architecture Notes

- Camel-K compiles integrations into Quarkus-native pods — fast startup, low memory
- The operator handles building container images (needs a registry for prod; ephemeral for lab)
- Integrations are declared as K8s custom resources (`Integration` CRD) — fully GitOps-friendly
- Scales independently from the Broker — you can have multiple integrations for different ASB entities
