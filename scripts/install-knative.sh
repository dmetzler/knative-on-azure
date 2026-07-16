#!/bin/bash
set -euo pipefail

# KNative versions
KNATIVE_VERSION="${KNATIVE_VERSION:-1.16.0}"

echo "=== Installing KNative Serving v${KNATIVE_VERSION} ==="
kubectl apply -f "https://github.com/knative/serving/releases/download/knative-v${KNATIVE_VERSION}/serving-crds.yaml"
kubectl apply -f "https://github.com/knative/serving/releases/download/knative-v${KNATIVE_VERSION}/serving-core.yaml"

echo "=== Installing Kourier (networking layer) ==="
kubectl apply -f "https://github.com/knative/net-kourier/releases/download/knative-v${KNATIVE_VERSION}/kourier.yaml"

kubectl patch configmap/config-network \
  --namespace knative-serving \
  --type merge \
  --patch '{"data":{"ingress-class":"kourier.ingress.networking.knative.dev"}}'

echo "=== Installing KNative Eventing v${KNATIVE_VERSION} ==="
kubectl apply -f "https://github.com/knative/eventing/releases/download/knative-v${KNATIVE_VERSION}/eventing-crds.yaml"
kubectl apply -f "https://github.com/knative/eventing/releases/download/knative-v${KNATIVE_VERSION}/eventing-core.yaml"

echo "=== Installing KNative Kafka components ==="
# Kafka Controller + Channel + Source + Broker
kubectl apply -f "https://github.com/knative-extensions/eventing-kafka-broker/releases/download/knative-v${KNATIVE_VERSION}/eventing-kafka-controller.yaml"
kubectl apply -f "https://github.com/knative-extensions/eventing-kafka-broker/releases/download/knative-v${KNATIVE_VERSION}/eventing-kafka-broker.yaml"
kubectl apply -f "https://github.com/knative-extensions/eventing-kafka-broker/releases/download/knative-v${KNATIVE_VERSION}/eventing-kafka-source.yaml"

echo "=== Waiting for KNative Serving to be ready ==="
kubectl wait --for=condition=Available deployment --all -n knative-serving --timeout=300s

echo "=== Waiting for KNative Eventing to be ready ==="
kubectl wait --for=condition=Available deployment --all -n knative-eventing --timeout=300s

echo ""
echo "✅ KNative Serving + Eventing + Kafka components installed!"
echo ""
echo "Kourier external IP:"
kubectl get svc kourier -n kourier-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
echo ""
echo ""
echo "Next: run ./scripts/setup-kafka-source.sh to wire Event Hubs (Kafka) → KNative"
