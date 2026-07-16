#!/bin/bash
set -euo pipefail

# Fix: kafka-broker-dispatcher references a volume "contract-resources" that
# doesn't exist in the v1.22.1 release manifest. Patch it in.

echo "=== Patching kafka-broker-dispatcher StatefulSet ==="
kubectl patch statefulset kafka-broker-dispatcher -n knative-eventing --type='json' -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/volumes/-",
    "value": {
      "name": "contract-resources",
      "configMap": {
        "name": "kafka-broker-brokers-triggers"
      }
    }
  }
]'

echo "=== Waiting for rollout ==="
kubectl rollout status statefulset/kafka-broker-dispatcher -n knative-eventing --timeout=120s

echo "✅ kafka-broker-dispatcher patched and running"
