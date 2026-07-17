"""KNative Eventing subscriber — receives CloudEvents via a FastAPI HTTP endpoint."""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any

import uvicorn
from fastapi import FastAPI, Request, Response

from ..models import CloudEvent, Disposition, MessageContext, SubscriptionOptions
from ..protocols import MessageHandler

logger = logging.getLogger(__name__)

_DISPOSITION_STATUS = {
    Disposition.COMPLETE: 200,
    Disposition.RETRY: 429,
    Disposition.DEAD_LETTER: 400,
}


@dataclass
class _Registration:
    handler: MessageHandler
    options: SubscriptionOptions


class KNativeEventingSubscriber:
    """Receives CloudEvents over HTTP and dispatches them to registered handlers.

    Parameters
    ----------
    port:
        TCP port to listen on (default ``8080``).
    host:
        Bind address (default ``0.0.0.0``).
    """

    def __init__(self, port: int = 8080, host: str = "0.0.0.0") -> None:
        self._port = port
        self._host = host
        self._registrations: list[_Registration] = []
        self._app = FastAPI(title="KNative Eventing Subscriber")
        self._server: uvicorn.Server | None = None
        self._setup_routes()

    # -- public API ----------------------------------------------------------

    @property
    def app(self) -> FastAPI:
        """Return the underlying FastAPI application (useful for testing or composition)."""
        return self._app

    def subscribe(self, handler: MessageHandler, options: SubscriptionOptions | None = None) -> None:
        """Register a message handler with optional filtering."""
        self._registrations.append(_Registration(handler=handler, options=options or SubscriptionOptions()))
        logger.info("Registered handler %s", type(handler).__name__)

    async def start(self) -> None:
        """Start the HTTP server (non-blocking — runs in a background task)."""
        config = uvicorn.Config(app=self._app, host=self._host, port=self._port, log_level="info")
        self._server = uvicorn.Server(config)
        await self._server.serve()

    async def stop(self) -> None:
        """Gracefully stop the HTTP server."""
        if self._server:
            self._server.should_exit = True

    # -- internals -----------------------------------------------------------

    def _setup_routes(self) -> None:
        @self._app.post("/")
        async def _receive(request: Request) -> Response:
            headers = dict(request.headers)
            try:
                body = await request.json()
            except Exception:
                body = (await request.body()).decode(errors="replace")

            event = CloudEvent.from_headers(headers, body)
            context = MessageContext(
                message_id=event.id,
                delivery_count=1,
                enqueued_time=datetime.utcnow(),
                source=event.source,
            )

            logger.info("Received CE %s (type=%s, source=%s)", event.id, event.type, event.source)

            worst = Disposition.COMPLETE
            for reg in self._registrations:
                if not self._matches(event, reg.options):
                    continue
                try:
                    result = await reg.handler.handle(event, context)
                except Exception:
                    logger.exception("Handler %s raised", type(reg.handler).__name__)
                    result = Disposition.RETRY

                if result.value > worst.value if self._disposition_rank(result) > self._disposition_rank(worst) else False:
                    worst = result

            status = _DISPOSITION_STATUS.get(worst, 200)
            return Response(status_code=status)

        @self._app.get("/healthz")
        async def _health() -> dict[str, str]:
            return {"status": "ok"}

    @staticmethod
    def _matches(event: CloudEvent, options: SubscriptionOptions) -> bool:
        if options.source_filter and event.source != options.source_filter:
            return False
        if options.type_filter and event.type != options.type_filter:
            return False
        return True

    @staticmethod
    def _disposition_rank(d: Disposition) -> int:
        return {Disposition.COMPLETE: 0, Disposition.RETRY: 1, Disposition.DEAD_LETTER: 2}[d]
