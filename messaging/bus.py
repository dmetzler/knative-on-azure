"""MessageBus — central DI-style abstraction decoupling handlers from transport."""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from datetime import datetime, timezone
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

HandlerFunc = Callable[[CloudEvent, MessageContext], Awaitable[Disposition]]


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

    Usage::

        from messaging import MessageBus, CloudEvent, Disposition, MessageContext

        bus = MessageBus()

        @bus.handler("order.created")
        async def handle_order(event: CloudEvent, ctx: MessageContext) -> Disposition:
            ...
            return Disposition.COMPLETE

        # In FastAPI app setup:
        app.include_router(bus.router)

        # At bootstrap — configure transport:
        from messaging.knative import KNativeTransport
        bus.configure(KNativeTransport(broker_url="http://..."))
    """

    def __init__(self) -> None:
        self._handlers: list[_HandlerRegistration] = []
        self._transport: MessagePublisher | None = None
        self._router = APIRouter()
        self._setup_routes()

    # -- Configuration -------------------------------------------------------

    def configure(self, transport: MessagePublisher) -> None:
        """Set the transport implementation (e.g. KNativeTransport).

        This is the DI composition root — call once at app startup.
        """
        self._transport = transport
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
        await self._transport.publish(topic or event.type, event, options)

    # -- Router (for mounting in FastAPI) ------------------------------------

    @property
    def router(self) -> APIRouter:
        """FastAPI router exposing the CloudEvent ingress endpoint.

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

    # -- Lifecycle -----------------------------------------------------------

    async def close(self) -> None:
        """Close the underlying transport."""
        if self._transport:
            await self._transport.close()

    # -- Internals -----------------------------------------------------------

    def _setup_routes(self) -> None:
        @self._router.post("/")
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
                enqueued_time=datetime.now(timezone.utc),
                source=event.source,
            )

            logger.info("Received CE %s (type=%s, source=%s)", event.id, event.type, event.source)

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

            return Response(status_code=_DISPOSITION_STATUS[worst])

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
