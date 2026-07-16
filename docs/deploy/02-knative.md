# 2. KNative Installation

## Overview

We install:

1. **KNative Serving** (v1.22.1) — serverless workloads with scale-to-zero
2. **Kourier** — lightweight ingress for Serving
3. **KNative Eventing** (v1.22.1) — event routing with brokers and triggers
4. **Kafka components** — Kafka Broker, Source, and Channel for Event Hubs integration

## Install KNative Serving + Eventing

```bash
./scripts/install-knative.sh
```

This script:

1. Installs KNative Serving CRDs and core components
2. Installs **Kourier** as the networking/ingress layer
3. Configures Kourier as the default ingress class
4. Installs KNative Eventing CRDs and core components
5. Installs the Kafka controller, broker, and source components

!!! info "Installation Time"
    Takes ~2-3 minutes. The script waits for all deployments to be ready.

## Fix Kafka Components (v1.22.1 Bug)

KNative v1.22.1 has a bug where the `kafka-broker-dispatcher` StatefulSet references a volume (`contract-resources`) that doesn't exist in the manifest. Additionally, the `kafka-source-dispatcher` and `kafka-channel-dispatcher` need to be installed separately.

```bash
./scripts/reinstall-kafka-components.sh
```

This script:

1. Downloads the `eventing-kafka-broker.yaml` manifest
2. Patches the missing volume definition
3. Applies the patched manifest
4. Installs `eventing-kafka-source` and `eventing-kafka-channel` components
5. Waits for all StatefulSets to be ready

## Verify

```bash
# All pods should be Running
kubectl get pods -n knative-serving
kubectl get pods -n knative-eventing
```

Expected pods in `knative-serving`:

```
activator-xxx              Running
autoscaler-xxx             Running
controller-xxx             Running
net-kourier-controller-xxx Running
webhook-xxx                Running
```

Expected pods in `knative-eventing`:

```
eventing-controller-xxx        Running
eventing-webhook-xxx           Running
kafka-broker-dispatcher-0      Running
kafka-broker-receiver-xxx      Running
kafka-controller-xxx           Running
kafka-source-dispatcher-0      Running
kafka-channel-dispatcher-0     Running
```

## Configure Domain (Optional)

By default, KNative uses `svc.cluster.local` which makes services cluster-local only. To expose services externally through Kourier:

```bash
kubectl patch configmap config-domain -n knative-serving \
  --type merge -p '{"data":{"example.com":""}}'
```

After this, services will be accessible via the Kourier LoadBalancer IP with the appropriate `Host` header:

```bash
KOURIER_IP=$(kubectl get svc kourier -n kourier-system \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -H "Host: hello-knative.default.example.com" http://$KOURIER_IP
```
