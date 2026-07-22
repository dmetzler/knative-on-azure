"""DAPR Pub/Sub transport — publisher with subscription discovery."""

from __future__ import annotations

from .publisher import DaprPublisher, DaprSubscription

# Transport alias for DI configuration (same pattern as KNativeTransport)
DaprTransport = DaprPublisher

__all__ = [
    "DaprPublisher",
    "DaprSubscription",
    "DaprTransport",
]
