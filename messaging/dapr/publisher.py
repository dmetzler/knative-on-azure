"""DAPR Pub/Sub publisher — posts CloudEvents via the DAPR sidecar HTTP API.

Uses ``rawPayload=true`` so the CloudEvent is delivered as-is to the underlying
broker (e.g. Azure Service Bus), producing the exact same wire format as
KNative Eventing's structured CloudEvent mode.
"""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from typing import Optional

import httpx
from fastapi import APIRouter

from ..models import CloudEvent, PublishOptions

logger = logging.getLogger(__name__)

_DEFAULT_DAPR_HTTP_PORT = 3500
_DEFAULT_PUBSUB_NAME = "messaging"


@dataclass
class DaprSubscription:
    """DAPR pub/sub subscription advertised via ``GET /dapr/subscribe``."""
    pubsub_name: str
    topic: str
    route: str = "/events"

    def to_dict(self) -> dict[str, str]:
        return {
            "pubsubname": self.pubsub_name,
            "topic": self.topic,
            "route": self.route,
        }


class DaprPublisher:
    """Publishes CloudEvents to a DAPR pub/sub component.

    The event is serialized as a structured CloudEvent JSON and sent with
    ``rawPayload=true`` so DAPR does not wrap it in its own envelope.
    This ensures the wire format is identical to KNative binary→structured
    CloudEvent serialization.

    Optionally manages DAPR subscriptions: pass ``subscriptions`` so the
    sidecar discovers them via ``GET /dapr/subscribe``.  The corresponding
    route is exposed on ``self.router``.

    Parameters
    ----------
    pubsub_name:
        Name of the DAPR pub/sub component (default ``messaging``).
    topic:
        Default topic to publish to. Can be overridden per-publish.
    subscriptions:
        DAPR subscriptions to advertise to the sidecar.
    dapr_http_port:
        DAPR sidecar HTTP port (default ``3500``).
    dapr_host:
        DAPR sidecar host (default ``localhost``).
    client:
        Optional pre-configured ``httpx.AsyncClient``.
    """

    def __init__(
        self,
        pubsub_name: str = _DEFAULT_PUBSUB_NAME,
        topic: str = "default",
        subscriptions: list[DaprSubscription] | None = None,
        dapr_http_port: int = _DEFAULT_DAPR_HTTP_PORT,
        dapr_host: str = "localhost",
        client: httpx.AsyncClient | None = None,
    ) -> None:
        self._pubsub_name = pubsub_name
        self._default_topic = topic
        self._subscriptions = subscriptions or []
        self._base_url = f"http://{dapr_host}:{dapr_http_port}"
        self._owns_client = client is None
        self._client = client or httpx.AsyncClient()
        self._router = APIRouter()
        self._setup_routes()

    # -- Router (transport-specific routes) ----------------------------------

    @property
    def router(self) -> APIRouter:
        """FastAPI router exposing DAPR-specific endpoints (``/dapr/subscribe``)."""
        return self._router

    def _setup_routes(self) -> None:
        subs = self._subscriptions

        @self._router.get("/dapr/subscribe")
        async def _dapr_subscribe() -> list[dict[str, str]]:
            return [s.to_dict() for s in subs]

    def _build_url(self, topic: str) -> str:
        return (
            f"{self._base_url}/v1.0/publish/{self._pubsub_name}/{topic}"
            f"?metadata.rawPayload=true"
        )

    @staticmethod
    def _serialize_event(event: CloudEvent) -> bytes:
        """Serialize using the canonical ``to_structured()`` method."""
        return json.dumps(event.to_structured()).encode()

    # -- MessagePublisher protocol -------------------------------------------

    async def publish(
        self,
        topic: str,
        event: CloudEvent,
        options: PublishOptions | None = None,
    ) -> None:
        """Publish a CloudEvent via the DAPR sidecar.

        Parameters
        ----------
        topic:
            Pub/sub topic name. Falls back to the default topic.
        event:
            The CloudEvent to publish.
        options:
            Publish options (timeout, extra headers).
        """
        opts = options or PublishOptions()
        publish_topic = topic or self._default_topic
        url = self._build_url(publish_topic)

        body = self._serialize_event(event)

        headers = {"Content-Type": "application/json"}
        headers.update(opts.headers)

        logger.info(
            "Publishing CE %s (type=%s) via DAPR → %s/%s",
            event.id, event.type, self._pubsub_name, publish_topic,
        )

        response = await self._client.post(
            url,
            content=body,
            headers=headers,
            timeout=opts.timeout,
        )
        response.raise_for_status()
        logger.debug("Publish OK — status %s", response.status_code)

    async def close(self) -> None:
        """Close the underlying HTTP client if we own it."""
        if self._owns_client:
            await self._client.aclose()
