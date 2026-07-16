#!/bin/bash
set -euo pipefail

KNATIVE_VERSION="${KNATIVE_VERSION:-1.22.1}"
BASE="https://github.com/knative-extensions/eventing-kafka-broker/releases/download/knative-v${KNATIVE_VERSION}"

echo "=== Cleaning up broken Kafka components ==="
kubectl delete statefulset kafka-broker-dispatcher -n knative-eventing --ignore-not-found
kubectl delete broker default -n default --ignore-not-found

echo "=== Downloading and patching eventing-kafka-broker manifest ==="
curl -sL "${BASE}/eventing-kafka-broker.yaml" -o /tmp/kafka-broker.yaml

# Fix the missing 'contract-resources' volume in kafka-broker-dispatcher StatefulSet (v1.22.1 bug)
python3 -c "
content = open('/tmp/kafka-broker.yaml').read()
marker = '        - name: kafka-broker-brokers-triggers\n          configMap:\n            name: kafka-broker-brokers-triggers'
patch = marker + '\n        - name: contract-resources\n          configMap:\n            name: kafka-broker-brokers-triggers'
if 'name: contract-resources' not in content:
    content = content.replace(marker, patch, 1)
    print('   ✅ Patched kafka-broker-dispatcher volume')
else:
    print('   ℹ️  Volume already present')
open('/tmp/kafka-broker.yaml', 'w').write(content)
"
kubectl apply -f /tmp/kafka-broker.yaml

echo "=== Waiting for kafka-broker-dispatcher ==="
echo -n "   Waiting for kafka-broker-dispatcher... "
if kubectl get statefulset kafka-broker-dispatcher -n knative-eventing &>/dev/null; then
  kubectl rollout status statefulset/kafka-broker-dispatcher -n knative-eventing --timeout=120s 2>/dev/null && echo "✅" || echo "⚠️ timeout"
else
  echo "not found"
fi

echo ""
echo "=== Current pods ==="
kubectl get pods -n knative-eventing

echo ""
echo "✅ Kafka Broker components reinstalled. Run ./scripts/setup-kafka-broker.sh next."
