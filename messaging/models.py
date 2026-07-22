"""Core data models for the messaging library."""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from typing import Any, Optional


class Disposition(Enum):
    """Outcome of message processing."""

    COMPLETE = "complete"
    RETRY = "retry"
    DEAD_LETTER = "dead_letter"


@dataclass
class CloudEvent:
    """CloudEvents v1.0 specification data model.

    See https://github.com/cloudevents/spec/blob/v1.0.2/cloudevents/spec.md
    """

    type: str
    source: str
    data: Any = None
    id: str = field(default_factory=lambda: str(uuid.uuid4()))
    specversion: str = "1.0"
    time: str = field(default_factory=lambda: datetime.utcnow().isoformat() + "Z")
    datacontenttype: str = "application/json"
    subject: Optional[str] = None
    extensions: dict[str, str] = field(default_factory=dict)

    def to_headers(self) -> dict[str, str]:
        """Serialize required + optional CE attributes as HTTP headers (binary content mode)."""
        headers: dict[str, str] = {
            "ce-id": self.id,
            "ce-type": self.type,
            "ce-source": self.source,
            "ce-specversion": self.specversion,
            "ce-time": self.time,
            "Content-Type": self.datacontenttype,
        }
        if self.subject:
            headers["ce-subject"] = self.subject
        for k, v in self.extensions.items():
            headers[f"ce-{k}"] = v
        return headers

    def to_structured(self) -> dict[str, Any]:
        """Serialize as structured CloudEvent JSON (application/cloudevents+json).

        Produces a deterministic dict suitable for ``json.dumps``.  Both
        KNative and DAPR transports use this to guarantee identical wire
        format.
        """
        ce: dict[str, Any] = {
            "specversion": self.specversion,
            "type": self.type,
            "source": self.source,
            "id": self.id,
            "time": self.time,
            "datacontenttype": self.datacontenttype,
        }
        if self.subject is not None:
            ce["subject"] = self.subject
        for k, v in self.extensions.items():
            ce[k] = v
        if self.data is not None:
            ce["data"] = self.data
        return ce

    @classmethod
    def from_structured(cls, payload: dict[str, Any]) -> CloudEvent:
        """Parse a structured CloudEvent JSON dict."""
        extensions: dict[str, str] = {}
        known = {"specversion", "type", "source", "id", "time",
                 "datacontenttype", "subject", "data"}
        for k, v in payload.items():
            if k not in known:
                extensions[k] = v
        return cls(
            specversion=payload.get("specversion", "1.0"),
            type=payload.get("type", ""),
            source=payload.get("source", ""),
            id=payload.get("id", str(uuid.uuid4())),
            time=payload.get("time", datetime.utcnow().isoformat() + "Z"),
            datacontenttype=payload.get("datacontenttype", "application/json"),
            subject=payload.get("subject"),
            data=payload.get("data"),
            extensions=extensions,
        )

    @classmethod
    def from_headers(cls, headers: dict[str, str], body: Any) -> CloudEvent:
        """Parse a CloudEvent from HTTP headers (binary content mode) and body."""
        extensions: dict[str, str] = {}
        for key, value in headers.items():
            lower = key.lower()
            if lower.startswith("ce-") and lower not in (
                "ce-id",
                "ce-type",
                "ce-source",
                "ce-specversion",
                "ce-time",
                "ce-subject",
            ):
                extensions[lower.removeprefix("ce-")] = value

        return cls(
            id=headers.get("ce-id", str(uuid.uuid4())),
            type=headers.get("ce-type", ""),
            source=headers.get("ce-source", ""),
            specversion=headers.get("ce-specversion", "1.0"),
            time=headers.get("ce-time", datetime.utcnow().isoformat() + "Z"),
            datacontenttype=headers.get("content-type", "application/json"),
            subject=headers.get("ce-subject"),
            data=body,
            extensions=extensions,
        )


@dataclass
class MessageContext:
    """Metadata about message delivery."""

    message_id: str
    delivery_count: int = 1
    enqueued_time: Optional[datetime] = None
    source: Optional[str] = None


@dataclass
class PublishOptions:
    """Options for publishing a CloudEvent."""

    timeout: float = 30.0
    headers: dict[str, str] = field(default_factory=dict)


@dataclass
class SubscriptionOptions:
    """Filtering and concurrency options for a subscription."""

    source_filter: Optional[str] = None
    type_filter: Optional[str] = None
    max_concurrency: int = 10
