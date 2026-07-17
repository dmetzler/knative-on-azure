#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/../terraform"

QUEUE="${1:-knative-inbound}"
BODY="${2:-{\"msg\":\"test from ASB\"}}"

echo "=== Sending message to ASB queue '${QUEUE}' ==="
cd "$TF_DIR"
CONN_STRING=$(terraform output -raw servicebus_connection_string)

python3 -c "
from azure.servicebus import ServiceBusClient, ServiceBusMessage
import sys

conn = '''${CONN_STRING}'''
queue = '${QUEUE}'
body = '''${BODY}'''

client = ServiceBusClient.from_connection_string(conn)
with client.get_queue_sender(queue) as sender:
    sender.send_messages(ServiceBusMessage(body, content_type='application/json'))
print(f'✅ Sent to {queue}: {body}')
"
