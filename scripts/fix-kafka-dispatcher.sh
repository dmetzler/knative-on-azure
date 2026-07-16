#!/bin/bash
set -euo pipefail

KNATIVE_VERSION="${KNATIVE_VERSION:-1.22.1}"

echo "=== Re-applying eventing-kafka-broker manifest with fix ==="

# Download the manifest, fix the missing volume, and apply
curl -sL "https://github.com/knative-extensions/eventing-kafka-broker/releases/download/knative-v${KNATIVE_VERSION}/eventing-kafka-broker.yaml" \
  | python3 -c "
import sys, yaml

docs = list(yaml.safe_load_all(sys.stdin))
for doc in docs:
    if doc and doc.get('kind') == 'StatefulSet' and doc.get('metadata',{}).get('name') == 'kafka-broker-dispatcher':
        volumes = doc['spec']['template']['spec'].setdefault('volumes', [])
        vol_names = [v['name'] for v in volumes]
        if 'contract-resources' not in vol_names:
            volumes.append({
                'name': 'contract-resources',
                'configMap': {'name': 'kafka-broker-brokers-triggers'}
            })
    if doc:
        print('---')
        print(yaml.dump(doc, default_flow_style=False))
" | kubectl apply -f -

echo "=== Waiting for kafka-broker-dispatcher ==="
kubectl rollout status statefulset/kafka-broker-dispatcher -n knative-eventing --timeout=120s

echo "✅ kafka-broker-dispatcher running"
