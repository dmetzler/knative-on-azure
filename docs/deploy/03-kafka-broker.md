# 3. Kafka Broker + Event Hubs

## How It Works

Azure Event Hubs Standard tier exposes a **Kafka-compatible endpoint** at:

```
<namespace>.servicebus.windows.net:9093
```

KNative's Kafka Broker connects to this endpoint using SASL_SSL authentication. From KNative's perspective, Event Hubs is just a regular Kafka cluster.

```
CloudEvent (HTTP POST)
    │
    ▼
Kafka Broker Ingress ──── SASL_SSL ────▶ Azure Event Hubs
    (in-cluster)            :9093        (Kafka protocol)
                                              │
Kafka Broker Dispatcher ◀── SASL_SSL ────────┘
    │
    ▼
Trigger → Your App
```

## Setup

```bash
./scripts/setup-kafka-broker.sh
```

This script:

1. **Reads Terraform outputs** to get the Event Hubs bootstrap server and connection string
2. **Creates a Kubernetes Secret** (`kafka-auth-secret`) with SASL_SSL credentials
3. **Configures the `kafka-broker-config` ConfigMap** with bootstrap server and secret reference
4. **Restarts the Kafka controller** to pick up the new config
5. **Creates a Kafka-class Broker** in the `default` namespace
6. **Deploys event-display** service and trigger

## Authentication Details

Azure Event Hubs uses a specific SASL_SSL configuration:

| Parameter | Value |
|-----------|-------|
| Protocol | `SASL_SSL` |
| SASL Mechanism | `PLAIN` |
| Username | `$ConnectionString` (this is a **literal string**, not a variable) |
| Password | The full SAS connection string from Event Hubs |

The Secret format follows the [official KNative Kafka Broker docs](https://knative.dev/docs/eventing/brokers/broker-types/kafka-broker/#authentication-using-sasl-and-encryption-using-ssl):

```bash
kubectl create secret generic kafka-auth-secret \
  --namespace knative-eventing \
  --from-literal=protocol=SASL_SSL \
  --from-literal=sasl.mechanism=PLAIN \
  --from-literal='user=$ConnectionString' \
  --from-literal=password="<SAS connection string>"
```

The ConfigMap references this secret via `auth.secret.ref.name`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kafka-broker-config
  namespace: knative-eventing
data:
  default.topic.partitions: "2"
  default.topic.replication.factor: "1"
  bootstrap.servers: "<namespace>.servicebus.windows.net:9093"
  auth.secret.ref.name: kafka-auth-secret
```

## Verify

```bash
# Broker should be Ready
kubectl get broker default -n default
```

Expected:

```
NAME      URL                                                                        READY
default   http://kafka-broker-ingress.knative-eventing.svc.cluster.local/default/default   True
```

## Test the Event Flow

Send a CloudEvent to the broker:

```bash
kubectl run curl --image=curlimages/curl --rm -it --restart=Never -- \
  -X POST http://kafka-broker-ingress.knative-eventing.svc.cluster.local/default/default \
  -H 'Content-Type: application/json' \
  -H 'Ce-Id: test-1' \
  -H 'Ce-Specversion: 1.0' \
  -H 'Ce-Type: dev.knative.test' \
  -H 'Ce-Source: /test' \
  -d '{"msg": "Hello from Event Hubs!"}'
```

Expected response: **`HTTP/1.1 202 Accepted`**

Check the event arrived at event-display:

```bash
kubectl logs -l serving.knative.dev/service=event-display -c user-container
```

Expected output:

```
☁️  cloudevents.Event
Context Attributes,
  specversion: 1.0
  type: dev.knative.test
  source: /test
  id: test-1
  datacontenttype: application/json
Extensions,
  knativekafkaoffset: 0
  knativekafkapartition: 0
Data,
  {"msg": "Hello from Event Hubs!"}
```

!!! success "Confirmation"
    The `knativekafkaoffset` and `knativekafkapartition` extensions confirm the event traveled through Azure Event Hubs via the Kafka protocol.
