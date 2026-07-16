#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/../terraform"

QUEUE="${1:-knative-inbound}"

echo "=== Fetching Service Bus connection string ==="
cd "$TF_DIR"
CONN_STRING=$(terraform output -raw servicebus_connection_string)

echo "=== Sending test message + receiving it back to inspect ==="
python3 - "$CONN_STRING" "$QUEUE" <<'PYTHON'
import sys
import json
from datetime import datetime

from azure.servicebus import ServiceBusClient, ServiceBusMessage

conn = sys.argv[1]
queue = sys.argv[2]

# --- Send a CloudEvent-formatted message ---
cloud_event = {
    "specversion": "1.0",
    "type": "com.test.sample",
    "source": "/test/script",
    "id": f"test-{datetime.utcnow().strftime('%H%M%S')}",
    "time": datetime.utcnow().isoformat() + "Z",
    "datacontenttype": "application/json",
    "data": {"order_id": "12345", "status": "created"}
}

client = ServiceBusClient.from_connection_string(conn)

print(f"\n📤 Sending to queue '{queue}':")
print(json.dumps(cloud_event, indent=2))

with client.get_queue_sender(queue) as sender:
    msg = ServiceBusMessage(
        body=json.dumps(cloud_event),
        content_type="application/cloudevents+json"
    )
    # Also set application properties (how Camel sees them)
    msg.application_properties = {
        "ce-specversion": "1.0",
        "ce-type": cloud_event["type"],
        "ce-source": cloud_event["source"],
        "ce-id": cloud_event["id"],
    }
    sender.send_messages(msg)

print("\n✅ Sent!")

# --- Now peek the queue to see how it looks ---
print(f"\n📥 Peeking queue '{queue}' to inspect message format:\n")
with client.get_queue_receiver(queue, max_wait_time=5) as receiver:
    msgs = receiver.peek_messages(max_message_count=5)
    if not msgs:
        print("  (no messages to peek — already consumed by Camel?)")
    for i, m in enumerate(msgs):
        print(f"--- Message {i+1} ---")
        print(f"  Body: {str(m)}")
        print(f"  Content-Type: {m.content_type}")
        print(f"  Application Properties: {m.application_properties}")
        print(f"  Enqueued Time: {m.enqueued_time_utc}")
        print(f"  Sequence Number: {m.sequence_number}")
        print()

client.close()
PYTHON
