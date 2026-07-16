#!/bin/bash
set -euo pipefail

# KNative versions
KNATIVE_VERSION="${KNATIVE_VERSION:-1.16.0}"

echo "=== Installing KNative Serving v${KNATIVE_VERSION} ==="
kubectl apply -f "https://github.com/knative/serving/releases/download/knative-v${KNATIVE_VERSION}/serving-crds.yaml"
kubectl apply -f "https://github.com/knative/serving/releases/download/knative-v${KNATIVE_VERSION}/serving-core.yaml"

echo "=== Installing Kourier (networking layer) ==="
kubectl apply -f "https://github.com/knative/net-kourier/releases/download/knative-v${KNATIVE_VERSION}/kourier.yaml"

# Configure Kourier as the default ingress
kubectl patch configmap/config-network \
  --namespace knative-serving \
  --type merge \
  --patch '{"data":{"ingress-class":"kourier.ingress.networking.knative.dev"}}'

echo "=== Installing KNative Eventing v${KNATIVE_VERSION} ==="
kubectl apply -f "https://github.com/knative/eventing/releases/download/knative-v${KNATIVE_VERSION}/eventing-crds.yaml"
kubectl apply -f "https://github.com/knative/eventing/releases/download/knative-v${KNATIVE_VERSION}/eventing-core.yaml"

# In-memory channel (for dev/testing, will be replaced by Event Hubs)
kubectl apply -f "https://github.com/knative/eventing/releases/download/knative-v${KNATIVE_VERSION}/in-memory-channel.yaml"

# MT Channel-based broker
kubectl apply -f "https://github.com/knative/eventing/releases/download/knative-v${KNATIVE_VERSION}/mt-channel-broker.yaml"

echo "=== Waiting for KNative Serving to be ready ==="
kubectl wait --for=condition=Available deployment --all -n knative-serving --timeout=300s

echo "=== Waiting for KNative Eventing to be ready ==="
kubectl wait --for=condition=Available deployment --all -n knative-eventing --timeout=300s

echo ""
echo "✅ KNative Serving + Eventing installed successfully!"
echo ""
echo "Kourier external IP:"
kubectl get svc kourier -n kourier-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
echo ""
