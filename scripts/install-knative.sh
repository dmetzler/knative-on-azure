#!/bin/bash
set -euo pipefail

# KNative versions
KNATIVE_VERSION="${KNATIVE_VERSION:-1.22.1}"

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

echo "=== Installing KNative Kafka Broker components ==="
kubectl apply -f "https://github.com/knative-extensions/eventing-kafka-broker/releases/download/knative-v${KNATIVE_VERSION}/eventing-kafka-controller.yaml"
kubectl apply -f "https://github.com/knative-extensions/eventing-kafka-broker/releases/download/knative-v${KNATIVE_VERSION}/eventing-kafka-broker.yaml"

echo "=== Waiting for KNative Serving to be ready ==="
kubectl wait --for=condition=Available deployment --all -n knative-serving --timeout=300s

echo "=== Waiting for KNative Eventing to be ready ==="
kubectl wait --for=condition=Available deployment --all -n knative-eventing --timeout=300s

echo ""
echo "✅ KNative Serving + Eventing + Kafka Broker components installed!"
echo ""
echo "Kourier external IP:"
kubectl get svc kourier -n kourier-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
echo ""
echo ""
echo "Next steps:"
echo "  1. ./scripts/reinstall-kafka-components.sh  (fix v1.22.1 volume bug)"
echo "  2. ./scripts/setup-kafka-broker.sh           (wire Event Hubs)"
