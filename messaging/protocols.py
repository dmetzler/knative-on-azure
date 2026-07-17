"""Protocol definitions for messaging abstractions."""

from __future__ import annotations

from typing import Protocol, runtime_checkable

from .models import CloudEvent, Disposition, MessageContext, PublishOptions, SubscriptionOptions


@runtime_checkable
class MessageHandler(Protocol):
    """Handles an incoming CloudEvent and returns a processing disposition."""

    async def handle(self, event: CloudEvent, context: MessageContext) -> Disposition: ...


@runtime_checkable
class MessagePublisher(Protocol):
    """Publishes CloudEvents to a topic/broker."""

    async def publish(self, topic: str, event: CloudEvent, options: PublishOptions | None = None) -> None: ...

    async def close(self) -> None: ...


@runtime_checkable
class MessageSubscriber(Protocol):
    """Subscribes handlers to receive CloudEvents."""

    def subscribe(self, handler: MessageHandler, options: SubscriptionOptions | None = None) -> None: ...

    async def start(self) -> None: ...

    async def stop(self) -> None: ...
