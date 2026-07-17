"""Demo backend — FastAPI app with WebSocket live stream, REST send endpoint,
KNative eventing integration via MessageBus, and Azure Service Bus peek/send.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import uuid
from collections import deque
from datetime import datetime
from typing import Any

from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from messaging.models import CloudEvent, Disposition, MessageContext
from messaging.bus import MessageBus
from messaging.knative import KNativeTransport

logging.basicConfig(level=logging.INFO)
logging.getLogger("azure").setLevel(logging.WARNING)
logging.getLogger("uamqp").setLevel(logging.WARNING)
logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

MOCK_MODE = os.getenv("MOCK_MODE", "false").lower() == "true"
BROKER_URL = os.getenv("BROKER_URL", "http://kafka-broker-ingress.knative-eventing.svc.cluster.local/default/default")
ASB_CONNECTION_STRING = os.getenv("AZURE_SERVICEBUS_CONNECTION_STRING", "")

# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------

app = FastAPI(title="Messaging Demo Backend")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ---------------------------------------------------------------------------
# MessageBus
# ---------------------------------------------------------------------------

bus = MessageBus()

if not MOCK_MODE:
    bus.configure(KNativeTransport(broker_url=BROKER_URL))


@bus.handler()
async def on_event(event: CloudEvent, ctx: MessageContext) -> Disposition:
    """Catch-all handler: receives ALL events from KNative Trigger."""
    await _handle_event(event)
    return Disposition.COMPLETE


# Mount bus router for receiving events from KNative Trigger
app.include_router(bus.router, prefix="/events")

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

MAX_BUFFER = 200
_message_buffer: deque[dict[str, Any]] = deque(maxlen=MAX_BUFFER)
_ws_clients: set[WebSocket] = set()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _event_to_dict(event: CloudEvent) -> dict[str, Any]:
    return {
        "id": event.id,
        "type": event.type,
        "source": event.source,
        "specversion": event.specversion,
        "time": event.time,
        "datacontenttype": event.datacontenttype,
        "subject": event.subject,
        "data": event.data,
        "extensions": event.extensions,
    }


async def _broadcast(payload: dict[str, Any]) -> None:
    dead: list[WebSocket] = []
    msg = json.dumps(payload)
    for ws in _ws_clients:
        try:
            await ws.send_text(msg)
        except Exception:
            dead.append(ws)
    for ws in dead:
        _ws_clients.discard(ws)


async def _handle_event(event: CloudEvent) -> None:
    """Process an event: buffer it and broadcast to WebSocket clients."""
    record = _event_to_dict(event)
    record["received_at"] = datetime.utcnow().isoformat() + "Z"
    _message_buffer.append(record)
    await _broadcast({"type": "event", "payload": record})
    logger.info("Handled CE %s (type=%s)", event.id, event.type)


# ---------------------------------------------------------------------------
# Pydantic request models
# ---------------------------------------------------------------------------


class SendRequest(BaseModel):
    type: str = "com.example.demo"
    source: str = "/demo/ui"
    data: Any = None
    subject: str | None = None


class AsbSendRequest(BaseModel):
    body: str
    content_type: str = "application/json"


# ---------------------------------------------------------------------------
# Routes — Core messaging
# ---------------------------------------------------------------------------


@app.post("/api/send")
async def send_event(req: SendRequest) -> dict[str, str]:
    event = CloudEvent(
        type=req.type,
        source=req.source,
        data=req.data,
        subject=req.subject,
    )

    if MOCK_MODE:
        await _handle_event(event)
    else:
        try:
            await bus.publish(event)
        except Exception as e:
            logger.warning("Publish to broker failed (%s), looping back locally", e)
        await _handle_event(event)

    return {"status": "sent", "id": event.id}


@app.get("/api/messages")
async def get_messages() -> list[dict[str, Any]]:
    return list(_message_buffer)


@app.delete("/api/messages")
async def clear_messages() -> dict[str, str]:
    """Clear all received events."""
    _message_buffer.clear()
    return {"status": "cleared"}


@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket) -> None:
    await ws.accept()
    _ws_clients.add(ws)
    logger.info("WebSocket client connected (%d total)", len(_ws_clients))
    try:
        while True:
            await ws.receive_text()
    except WebSocketDisconnect:
        pass
    finally:
        _ws_clients.discard(ws)
        logger.info("WebSocket client disconnected (%d total)", len(_ws_clients))


# ---------------------------------------------------------------------------
# Routes — Azure Service Bus
# ---------------------------------------------------------------------------


def _get_asb_client():
    """Lazy import and create ASB client."""
    if not ASB_CONNECTION_STRING:
        raise HTTPException(status_code=503, detail="Azure Service Bus not configured")
    from azure.servicebus.aio import ServiceBusClient
    return ServiceBusClient.from_connection_string(ASB_CONNECTION_STRING)


def _get_asb_admin_client():
    """Lazy import and create ASB admin client (sync)."""
    if not ASB_CONNECTION_STRING:
        raise HTTPException(status_code=503, detail="Azure Service Bus not configured")
    from azure.servicebus.management import ServiceBusAdministrationClient
    return ServiceBusAdministrationClient.from_connection_string(ASB_CONNECTION_STRING)


def _list_queues_sync() -> list[dict[str, Any]]:
    """Sync helper to list queues (runs in thread)."""
    from azure.servicebus.management import ServiceBusAdministrationClient
    admin = ServiceBusAdministrationClient.from_connection_string(ASB_CONNECTION_STRING)
    queues = []
    with admin:
        for props in admin.list_queues():
            runtime = admin.get_queue_runtime_properties(props.name)
            queues.append({
                "name": props.name,
                "active_message_count": runtime.active_message_count,
                "dead_letter_message_count": runtime.dead_letter_message_count,
                "scheduled_message_count": runtime.scheduled_message_count,
                "total_message_count": runtime.total_message_count,
            })
    return queues


@app.get("/api/asb/queues")
async def list_asb_queues() -> list[dict[str, Any]]:
    """List all queues with message counts."""
    if not ASB_CONNECTION_STRING:
        raise HTTPException(status_code=503, detail="Azure Service Bus not configured")
    return await asyncio.to_thread(_list_queues_sync)


@app.get("/api/asb/peek/{queue_name}")
async def peek_asb_queue(queue_name: str, max_count: int = 10) -> list[dict[str, Any]]:
    """Peek messages from a queue (non-destructive)."""
    client = _get_asb_client()
    messages = []
    async with client:
        receiver = client.get_queue_receiver(queue_name)
        async with receiver:
            peeked = await receiver.peek_messages(max_message_count=max_count)
            for msg in peeked:
                messages.append({
                    "message_id": msg.message_id,
                    "body": str(msg),
                    "content_type": msg.content_type,
                    "enqueued_time": msg.enqueued_time_utc.isoformat() if msg.enqueued_time_utc else None,
                    "sequence_number": msg.sequence_number,
                    "subject": msg.subject,
                })
    return messages


@app.post("/api/asb/send/{queue_name}")
async def send_to_asb_queue(queue_name: str, req: AsbSendRequest) -> dict[str, str]:
    """Send a CloudEvent (structured mode) to an Azure Service Bus queue."""
    import uuid as _uuid
    from azure.servicebus import ServiceBusMessage

    # Camel-K route checks body contains 'specversion' (structured CE mode)
    event_id = str(_uuid.uuid4())
    ce_body = json.dumps({
        "specversion": "1.0",
        "type": "com.demo.asb",
        "source": "/demo/asb-ui",
        "id": event_id,
        "time": datetime.utcnow().isoformat() + "Z",
        "datacontenttype": "application/json",
        "data": json.loads(req.body) if req.content_type == "application/json" else req.body,
    })
    ce_message = ServiceBusMessage(
        body=ce_body,
        content_type="application/cloudevents+json",
    )
    client = _get_asb_client()
    async with client:
        sender = client.get_queue_sender(queue_name)
        async with sender:
            await sender.send_messages(ce_message)
    return {"status": "sent", "queue": queue_name, "id": event_id}


@app.delete("/api/asb/purge/{queue_name}")
async def purge_asb_queue(queue_name: str) -> dict[str, int]:
    """Receive and discard all messages from a queue (including DLQ)."""
    client = _get_asb_client()
    from azure.servicebus import ServiceBusSubQueue
    count = 0
    dlq_count = 0
    async with client:
        # Purge main queue
        receiver = client.get_queue_receiver(queue_name, max_wait_time=5)
        async with receiver:
            async for msg in receiver:
                await receiver.complete_message(msg)
                count += 1
        # Purge dead-letter queue
        dlq_receiver = client.get_queue_receiver(
            queue_name, sub_queue=ServiceBusSubQueue.DEAD_LETTER, max_wait_time=5
        )
        async with dlq_receiver:
            async for msg in dlq_receiver:
                await dlq_receiver.complete_message(msg)
                dlq_count += 1
    return {"purged": count, "dlq_purged": dlq_count, "queue": queue_name}


# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------


@app.get("/healthz")
async def health() -> dict[str, str]:
    return {"status": "ok"}


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000)
