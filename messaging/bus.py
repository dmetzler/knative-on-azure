"""MessageBus — central DI-style abstraction decoupling handlers from transport.

Supports receiving CloudEvents in any format:
- Binary content mode (KNative Eventing — CE attrs in ``ce-*`` HTTP headers)
- Structured content mode (``application/cloudevents+json`` — full CE in body)
- DAPR-wrapped (envelope with ``data`` containing the original payload)

The bus auto-detects the format on each incoming request.  Handlers registered
via ``@bus.handler()`` always receive a normalised ``CloudEvent`` regardless of
how it was delivered.
"""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from datetime import datetime, timezone
from enum import Enum
from typing import Any, Callable, Awaitable

from fastapi import APIRouter, Request, Response

from .models import CloudEvent, Disposition, MessageContext, PublishOptions
from .protocols import MessagePublisher

logger = logging.getLogger(__name__)

_DISPOSITION_STATUS = {
    Disposition.COMPLETE: 200,
    Disposition.RETRY: 429,
    Disposition.DEAD_LETTER: 400,
}

_DISPOSITION_RANK = {
    Disposition.COMPLETE: 0,
    Disposition.RETRY: 1,
    Disposition.DEAD_LETTER: 2,
}

# DAPR response status mapping
_DISPOSITION_DAPR = {
    Disposition.COMPLETE: "SUCCESS",
    Disposition.RETRY: "RETRY",
    Disposition.DEAD_LETTER: "DROP",
}

HandlerFunc = Callable[[CloudEvent, MessageContext], Awaitable[Disposition]]


class _IngestMode(Enum):
    """Detected ingest format for an incoming request."""
    BINARY = "binary"           # KNative binary content mode (ce-* headers)
    STRUCTURED = "structured"   # application/cloudevents+json
    DAPR = "dapr"               # DAPR envelope (topic/pubsubname/data)


@dataclass
class _HandlerRegistration:
    func: HandlerFunc
    type_filter: str | None = None
    source_filter: str | None = None


class MessageBus:
    """Transport-agnostic message bus.

    Decouples business logic (handlers) from the underlying transport.
    Handlers are registered via the ``@bus.handler()`` decorator.
    Transport is configured at bootstrap via ``bus.configure(transport)``.

    The bus is **transport-agnostic** — it knows nothing about KNative or DAPR
    specifics.  Transport-specific routes (e.g. DAPR's ``/dapr/subscribe``)
    live on the transport's own ``router`` and are mounted automatically when
    ``bus.configure()`` is called.

    Usage::

        from messaging import MessageBus, CloudEvent, Disposition, MessageContext

        bus = MessageBus()

        @bus.handler("order.created")
        async def handle_order(event: CloudEvent, ctx: MessageContext) -> Disposition:
            ...
            return Disposition.COMPLETE

        # In FastAPI app setup:
        app.include_router(bus.router)

        # --- KNative transport ---
        from messaging.knative import KNativeTransport
        bus.configure(KNativeTransport(broker_url="http://..."))

        # --- DAPR transport ---
        from messaging.dapr import DaprTransport, DaprSubscription
        bus.configure(DaprTransport(
            pubsub_name="messaging",
            topic="knative-outbound",
            subscriptions=[DaprSubscription("messaging", "knative-inbound")],
        ))
    """

    def __init__(self) -> None:
        self._handlers: list[_HandlerRegistration] = []
        self._transport: MessagePublisher | None = None
        self._router = APIRouter()
        self._setup_routes()

    # -- Configuration -------------------------------------------------------

    def configure(self, transport: MessagePublisher) -> None:
        """Set the transport implementation (e.g. KNativeTransport, DaprTransport).

        This is the DI composition root — call once at app startup.
        If the transport exposes a ``router`` attribute (FastAPI APIRouter),
        it is included in the bus router automatically.
        """
        self._transport = transport

        # Mount transport-specific routes if available
        transport_router = getattr(transport, "router", None)
        if isinstance(transport_router, APIRouter):
            self._router.include_router(transport_router)
            logger.info("Mounted transport router from %s", type(transport).__name__)

        logger.info("MessageBus configured with transport: %s", type(transport).__name__)

    # -- Handler registration ------------------------------------------------

    def handler(
        self,
        event_type: str | None = None,
        *,
        source: str | None = None,
    ) -> Callable[[HandlerFunc], HandlerFunc]:
        """Decorator to register a handler function.

        Parameters
        ----------
        event_type:
            CloudEvent type to filter on (exact match). None = all types.
        source:
            CloudEvent source to filter on (exact match). None = all sources.

        Example::

            @bus.handler("order.created")
            async def on_order(event, ctx):
                return Disposition.COMPLETE
        """

        def decorator(func: HandlerFunc) -> HandlerFunc:
            self._handlers.append(
                _HandlerRegistration(func=func, type_filter=event_type, source_filter=source)
            )
            logger.info("Registered handler %s for type=%s source=%s", func.__name__, event_type, source)
            return func

        return decorator

    # -- Publishing ----------------------------------------------------------

    async def publish(
        self,
        event: CloudEvent,
        *,
        topic: str | None = None,
        options: PublishOptions | None = None,
    ) -> None:
        """Publish a CloudEvent through the configured transport.

        Parameters
        ----------
        event:
            The CloudEvent to publish.
        topic:
            Optional topic/subject hint (transport-dependent routing).
        options:
            Publish options (timeout, extra headers).

        Raises
        ------
        RuntimeError:
            If no transport has been configured.
        """
        if self._transport is None:
            raise RuntimeError(
                "MessageBus has no transport configured. Call bus.configure(transport) at startup."
            )
        await self._transport.publish(topic, event, options)

    # -- Router (for mounting in FastAPI) ------------------------------------

    @property
    def router(self) -> APIRouter:
        """FastAPI router exposing the CloudEvent ingress endpoint.

        Transport-specific routes (e.g. ``/dapr/subscribe``) are included
        automatically when ``bus.configure()`` is called with a transport
        that has a ``router`` attribute.

        Mount in your app::

            app.include_router(bus.router)
            app.include_router(bus.router, prefix="/events")
        """
        return self._router

    # -- Local dispatch (testing / notebooks) ---------------------------------

    async def dispatch(self, event: CloudEvent) -> Disposition:
        """Dispatch a CloudEvent to local handlers (without HTTP).

        Useful for testing and interactive notebooks. Returns the worst
        disposition from all matching handlers.

        Example::

            result = await bus.dispatch(event)
            assert result == Disposition.COMPLETE
        """
        context = MessageContext(
            message_id=event.id,
            delivery_count=1,
            enqueued_time=datetime.now(timezone.utc),
            source=event.source,
        )
        return await self._dispatch_to_handlers_async(event, context)

    # -- Lifecycle -----------------------------------------------------------

    async def close(self) -> None:
        """Close the underlying transport."""
        if self._transport:
            await self._transport.close()

    # -- Internals -----------------------------------------------------------

    @staticmethod
    def _detect_mode(headers: dict[str, str], body: Any) -> _IngestMode:
        """Detect the CloudEvent ingest format from headers and body."""
        # Binary content mode — KNative sends ce-* headers
        if any(k.lower().startswith("ce-") for k in headers):
            return _IngestMode.BINARY

        # Structured content mode — content-type says so
        ct = headers.get("content-type", "")
        if "cloudevents+json" in ct:
            return _IngestMode.STRUCTURED

        # Structured CE in body (specversion at top level)
        if isinstance(body, dict) and "specversion" in body:
            return _IngestMode.STRUCTURED

        # DAPR envelope (has topic/pubsubname keys)
        if isinstance(body, dict) and ("topic" in body or "pubsubname" in body):
            return _IngestMode.DAPR

        # Fallback
        return _IngestMode.BINARY

    @staticmethod
    def _parse_event(headers: dict[str, str], body: Any, mode: _IngestMode) -> CloudEvent:
        """Parse a CloudEvent from any supported format."""
        if mode == _IngestMode.BINARY:
            return CloudEvent.from_headers(headers, body)

        if mode == _IngestMode.STRUCTURED:
            if isinstance(body, dict):
                return CloudEvent.from_structured(body)
            if isinstance(body, str):
                return CloudEvent.from_structured(json.loads(body))
            return CloudEvent.from_headers(headers, body)

        # DAPR envelope
        if isinstance(body, dict):
            data = body.get("data", body)
            if isinstance(data, dict) and "specversion" in data:
                return CloudEvent.from_structured(data)
            return CloudEvent(
                type=body.get("type", "com.dapr.event.sent"),
                source=body.get(
                    "source",
                    f"/dapr/{body.get('pubsubname', 'unknown')}/{body.get('topic', 'unknown')}",
                ),
                data=data,
            )

        return CloudEvent.from_headers(headers, body)

    async def _dispatch_to_handlers_async(self, event: CloudEvent, context: MessageContext) -> Disposition:
        """Run all matching handlers (async) and return the worst disposition."""
        worst = Disposition.COMPLETE
        matched = False
        for reg in self._handlers:
            if not self._matches(event, reg):
                continue
            matched = True
            try:
                result = await reg.func(event, context)
            except Exception:
                logger.exception("Handler %s raised", reg.func.__name__)
                result = Disposition.RETRY
            if _DISPOSITION_RANK[result] > _DISPOSITION_RANK[worst]:
                worst = result
        if not matched:
            logger.warning("No handler matched CE type=%s source=%s", event.type, event.source)
        return worst

    def _build_response(self, mode: _IngestMode, disposition: Disposition) -> Response:
        """Build the appropriate HTTP response for the transport."""
        if mode == _IngestMode.DAPR:
            return Response(
                content=json.dumps({"status": _DISPOSITION_DAPR[disposition]}),
                status_code=200,
                media_type="application/json",
            )
        return Response(status_code=_DISPOSITION_STATUS[disposition])

    def _setup_routes(self) -> None:
        @self._router.post("/")
        async def _receive(request: Request) -> Response:
            headers = dict(request.headers)
            try:
                body = await request.json()
            except Exception:
                body = (await request.body()).decode(errors="replace")

            mode = self._detect_mode(headers, body)
            event = self._parse_event(headers, body, mode)
            context = MessageContext(
                message_id=event.id,
                delivery_count=1,
                enqueued_time=datetime.now(timezone.utc),
                source=event.source,
            )

            logger.info(
                "Received CE %s (type=%s, source=%s, mode=%s)",
                event.id, event.type, event.source, mode.value,
            )

            worst = await self._dispatch_to_handlers_async(event, context)
            return self._build_response(mode, worst)

        @self._router.get("/healthz")
        async def _health() -> dict[str, str]:
            return {"status": "ok"}

    @staticmethod
    def _matches(event: CloudEvent, reg: _HandlerRegistration) -> bool:
        if reg.type_filter and event.type != reg.type_filter:
            return False
        if reg.source_filter and event.source != reg.source_filter:
            return False
        return True
