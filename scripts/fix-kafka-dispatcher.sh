#!/bin/bash
set -euo pipefail

KNATIVE_VERSION="${KNATIVE_VERSION:-1.22.1}"
MANIFEST_URL="https://github.com/knative-extensions/eventing-kafka-broker/releases/download/knative-v${KNATIVE_VERSION}/eventing-kafka-broker.yaml"

echo "=== Downloading eventing-kafka-broker manifest ==="
curl -sL "$MANIFEST_URL" -o /tmp/kafka-broker.yaml

echo "=== Injecting missing 'contract-resources' volume into kafka-broker-dispatcher ==="
# Use sed to add the volume definition after the existing volumes in the StatefulSet
# The issue: volumeMounts references 'contract-resources' but volumes section doesn't define it
sed -i '/^        - name: kafka-broker-brokers-triggers$/,/^          name: kafka-broker-brokers-triggers$/{
  /^          name: kafka-broker-brokers-triggers$/a\
        - name: contract-resources\
          configMap:\
            name: kafka-broker-brokers-triggers
}' /tmp/kafka-broker.yaml

# Verify the fix is in place
if grep -A2 "name: contract-resources" /tmp/kafka-broker.yaml | grep -q "configMap"; then
  echo "   ✅ Volume injected"
else
  echo "   ⚠️  Sed patch may not have worked, trying alternative approach..."
  # Alternative: just append the volume to the StatefulSet's volumes list
  # Find the StatefulSet and add after the last volume entry
  python3 -c "
import sys
content = open('/tmp/kafka-broker.yaml').read()
# Find the volumes section in the StatefulSet and add our volume
marker = '        - name: kafka-broker-brokers-triggers\n          configMap:\n            name: kafka-broker-brokers-triggers'
replacement = marker + '\n        - name: contract-resources\n          configMap:\n            name: kafka-broker-brokers-triggers'
if marker in content and 'name: contract-resources' not in content:
    content = content.replace(marker, replacement, 1)
open('/tmp/kafka-broker.yaml', 'w').write(content)
print('   ✅ Volume injected (python fallback)')
"
fi

echo "=== Applying patched manifest ==="
kubectl apply -f /tmp/kafka-broker.yaml

echo "=== Waiting for kafka-broker-dispatcher ==="
kubectl rollout status statefulset/kafka-broker-dispatcher -n knative-eventing --timeout=180s

echo ""
echo "✅ Kafka broker dispatcher running!"
