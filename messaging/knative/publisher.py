"""KNative Eventing publisher — posts CloudEvents via HTTP (binary content mode)."""

from __future__ import annotations

import json
import logging
from typing import Optional

import httpx

from ..models import CloudEvent, PublishOptions

logger = logging.getLogger(__name__)

_DEFAULT_BROKER = "http://broker-ingress.knative-eventing.svc.cluster.local/default/default"


class KNativeEventingPublisher:
    """Publishes CloudEvents to a KNative broker/channel over HTTP.

    Uses binary content mode: CE attributes are sent as ``ce-*`` HTTP headers and
    the event data is the request body.

    Parameters
    ----------
    broker_url:
        Base URL of the KNative broker ingress.  When *None* the default
        in-cluster broker address is used.
    client:
        Optional pre-configured ``httpx.AsyncClient``.  If not provided one
        will be created (and closed on :meth:`close`).
    """

    def __init__(
        self,
        broker_url: str | None = None,
        client: httpx.AsyncClient | None = None,
    ) -> None:
        self._broker_url = broker_url or _DEFAULT_BROKER
        self._owns_client = client is None
        self._client = client or httpx.AsyncClient()

    # -- MessagePublisher protocol -------------------------------------------

    async def publish(
        self,
        topic: str,
        event: CloudEvent,
        options: PublishOptions | None = None,
    ) -> None:
        """Publish a CloudEvent to the broker.

        *topic* is currently informational (KNative routing uses Triggers);
        it is set as the ``ce-subject`` header when the event has no explicit
        subject.
        """
        opts = options or PublishOptions()

        if event.subject is None:
            event.subject = topic

        headers = event.to_headers()
        headers.update(opts.headers)

        body: bytes
        if event.data is None:
            body = b""
        elif isinstance(event.data, (str, bytes)):
            body = event.data.encode() if isinstance(event.data, str) else event.data
        else:
            body = json.dumps(event.data).encode()

        logger.info("Publishing CE %s (type=%s) → %s", event.id, event.type, self._broker_url)

        response = await self._client.post(
            self._broker_url,
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
