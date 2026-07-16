#!/bin/bash
set -euo pipefail

KNATIVE_VERSION="${KNATIVE_VERSION:-1.22.1}"
MANIFEST_URL="https://github.com/knative-extensions/eventing-kafka-broker/releases/download/knative-v${KNATIVE_VERSION}/eventing-kafka-broker.yaml"

echo "=== Downloading eventing-kafka-broker manifest ==="
curl -sL "$MANIFEST_URL" -o /tmp/kafka-broker.yaml

echo "=== Injecting missing 'contract-resources' volume ==="
python3 -c "
content = open('/tmp/kafka-broker.yaml').read()

# The StatefulSet has a volumeMount 'contract-resources' but no matching volume.
# Add it after the existing 'kafka-broker-brokers-triggers' volume definition.
marker = '        - name: kafka-broker-brokers-triggers\n          configMap:\n            name: kafka-broker-brokers-triggers'
patch = marker + '\n        - name: contract-resources\n          configMap:\n            name: kafka-broker-brokers-triggers'

if 'name: contract-resources' not in content:
    content = content.replace(marker, patch, 1)
    print('   ✅ Volume injected')
else:
    print('   ℹ️  Volume already present')

open('/tmp/kafka-broker.yaml', 'w').write(content)
"

echo "=== Applying patched manifest ==="
kubectl apply -f /tmp/kafka-broker.yaml

echo "=== Waiting for kafka-broker-dispatcher ==="
kubectl rollout status statefulset/kafka-broker-dispatcher -n knative-eventing --timeout=180s

echo ""
echo "✅ Kafka broker dispatcher running!"
