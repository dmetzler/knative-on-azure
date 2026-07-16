#!/bin/bash
set -euo pipefail

KNATIVE_VERSION="${KNATIVE_VERSION:-1.22.1}"
BASE="https://github.com/knative-extensions/eventing-kafka-broker/releases/download/knative-v${KNATIVE_VERSION}"

echo "=== Cleaning up broken Kafka components ==="
kubectl delete statefulset kafka-broker-dispatcher -n knative-eventing --ignore-not-found
kubectl delete broker default -n default --ignore-not-found

echo "=== Downloading and patching eventing-kafka-broker manifest ==="
curl -sL "${BASE}/eventing-kafka-broker.yaml" -o /tmp/kafka-broker.yaml

# Fix the missing 'contract-resources' volume in kafka-broker-dispatcher StatefulSet
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

echo "=== Downloading and patching eventing-kafka-source manifest ==="
curl -sL "${BASE}/eventing-kafka-source.yaml" -o /tmp/kafka-source.yaml

# Same bug likely exists in kafka-source-dispatcher
python3 -c "
content = open('/tmp/kafka-source.yaml').read()
# Fix contract-resources volume if missing in source dispatcher too
marker = '        - name: kafka-source-sources\n          configMap:\n            name: kafka-source-sources'
patch = marker + '\n        - name: contract-resources\n          configMap:\n            name: kafka-source-sources'
if 'name: contract-resources' not in content and marker in content:
    content = content.replace(marker, patch, 1)
    print('   ✅ Patched kafka-source-dispatcher volume')
else:
    print('   ℹ️  No patch needed or marker not found')
open('/tmp/kafka-source.yaml', 'w').write(content)
"
kubectl apply -f /tmp/kafka-source.yaml

echo "=== Downloading eventing-kafka-channel manifest ==="
curl -sL "${BASE}/eventing-kafka-channel.yaml" -o /tmp/kafka-channel.yaml
kubectl apply -f /tmp/kafka-channel.yaml 2>&1 || echo "   ⚠️  kafka-channel apply had errors (may need similar patch)"

echo "=== Waiting for StatefulSets ==="
for ss in kafka-broker-dispatcher kafka-source-dispatcher kafka-channel-dispatcher; do
  echo -n "   Waiting for $ss... "
  if kubectl get statefulset "$ss" -n knative-eventing &>/dev/null; then
    kubectl rollout status statefulset/"$ss" -n knative-eventing --timeout=120s 2>/dev/null && echo "✅" || echo "⚠️ timeout"
  else
    echo "not found (skipping)"
  fi
done

echo ""
echo "=== Current pods ==="
kubectl get pods -n knative-eventing

echo ""
echo "✅ Kafka components reinstalled. Run ./scripts/setup-kafka-broker.sh next."
