"""Demo backend — FastAPI app with WebSocket live stream and REST send endpoint.

Runs standalone for local dev: publishes events to an in-memory bus (no real
KNative required) and broadcasts them to connected WebSocket clients.
"""

from __future__ import annotations

import asyncio
import json
import logging
import uuid
from collections import deque
from datetime import datetime
from typing import Any

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

# Adjust import path — works both when `messaging` is installed and when running
# from the repo root with PYTHONPATH including the project dir.
import sys, pathlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))

from messaging.models import CloudEvent, Disposition, MessageContext
from messaging.knative.publisher import KNativeEventingPublisher

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

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
# State
# ---------------------------------------------------------------------------

MAX_BUFFER = 200
_message_buffer: deque[dict[str, Any]] = deque(maxlen=MAX_BUFFER)
_ws_clients: set[WebSocket] = set()

# In local-dev / mock mode we don't actually POST to a broker — we just loop
# the event back into the subscriber pipeline directly.
_mock_mode = True


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
# Pydantic request model
# ---------------------------------------------------------------------------


class SendRequest(BaseModel):
    type: str = "com.example.demo"
    source: str = "/demo/ui"
    data: Any = None
    subject: str | None = None


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------


@app.post("/api/send")
async def send_event(req: SendRequest) -> dict[str, str]:
    event = CloudEvent(
        type=req.type,
        source=req.source,
        data=req.data,
        subject=req.subject,
    )

    if _mock_mode:
        # Loop back directly — no real broker.
        await _handle_event(event)
    else:
        publisher = KNativeEventingPublisher()
        try:
            await publisher.publish(topic=req.subject or "demo", event=event)
        finally:
            await publisher.close()

    return {"status": "sent", "id": event.id}


@app.get("/api/messages")
async def get_messages() -> list[dict[str, Any]]:
    return list(_message_buffer)


@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket) -> None:
    await ws.accept()
    _ws_clients.add(ws)
    logger.info("WebSocket client connected (%d total)", len(_ws_clients))
    try:
        while True:
            # Keep connection alive; client can send pings or ignore.
            await ws.receive_text()
    except WebSocketDisconnect:
        pass
    finally:
        _ws_clients.discard(ws)
        logger.info("WebSocket client disconnected (%d total)", len(_ws_clients))


@app.get("/healthz")
async def health() -> dict[str, str]:
    return {"status": "ok"}


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000)
