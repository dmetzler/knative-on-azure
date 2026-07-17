"""KNative Eventing transport — wraps publisher for use with MessageBus."""

from __future__ import annotations

from .publisher import KNativeEventingPublisher
from .subscriber import KNativeEventingSubscriber

# Transport alias for DI configuration
KNativeTransport = KNativeEventingPublisher

__all__ = [
    "KNativeEventingPublisher",
    "KNativeEventingSubscriber",
    "KNativeTransport",
]
