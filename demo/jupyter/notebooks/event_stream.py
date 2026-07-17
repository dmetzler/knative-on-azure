"""Live event stream widget for Jupyter notebooks.

Connects to the demo backend WebSocket and displays incoming CloudEvents
in real-time within the notebook output.

Usage:
    from event_stream import EventStream
    stream = EventStream()
    stream.start()
    # Events appear below as they arrive
    # stream.stop() to disconnect
"""

import asyncio
import json
from IPython.display import display, HTML
import ipywidgets as widgets


class EventStream:
    """Live CloudEvent stream widget for Jupyter notebooks."""

    def __init__(self, ws_url: str = "ws://demo-backend/ws"):
        self.ws_url = ws_url
        self._events: list[dict] = []
        self._output = widgets.Output(layout=widgets.Layout(
            max_height="400px",
            overflow_y="auto",
            border="1px solid #333",
            padding="8px",
        ))
        self._status = widgets.HTML(value=self._badge("disconnected"))
        self._container = widgets.VBox([
            widgets.HBox([widgets.HTML("<b>📡 Live Event Stream</b>"), self._status]),
            self._output
        ])
        self._task: asyncio.Task | None = None

    def start(self):
        """Start listening for events."""
        display(self._container)
        self._task = asyncio.ensure_future(self._listen())

    def stop(self):
        """Stop listening."""
        if self._task:
            self._task.cancel()
            self._task = None
        self._status.value = self._badge("disconnected")

    async def _listen(self):
        import websockets
        self._status.value = self._badge("connecting")
        try:
            async with websockets.connect(self.ws_url) as ws:
                self._status.value = self._badge("connected")
                async for raw in ws:
                    try:
                        msg = json.loads(raw)
                        if msg.get("type") == "event":
                            self._on_event(msg["payload"])
                    except json.JSONDecodeError:
                        pass
        except Exception as e:
            self._status.value = self._badge(f"error: {e}")

    def _on_event(self, event: dict):
        self._events.append(event)
        with self._output:
            time = event.get("time", "")
            etype = event.get("type", "?")
            source = event.get("source", "?")
            data = json.dumps(event.get("data", {}), indent=2)
            html = f"""
            <div style="margin-bottom:8px; padding:6px; background:#1a1a2e; border-radius:4px; font-family:monospace; font-size:12px;">
                <span style="color:#4ade80;">●</span>
                <span style="color:#94a3b8;">{time}</span>
                <span style="color:#60a5fa; font-weight:bold;">{etype}</span>
                <span style="color:#94a3b8;">from {source}</span>
                <pre style="color:#e2e8f0; margin:4px 0 0 16px; white-space:pre-wrap;">{data}</pre>
            </div>
            """
            display(HTML(html))

    @staticmethod
    def _badge(status: str) -> str:
        colors = {
            "connected": "#4ade80",
            "connecting": "#facc15",
            "disconnected": "#ef4444",
        }
        color = colors.get(status, "#ef4444")
        return f'<span style="margin-left:8px; color:{color}; font-size:12px;">⬤ {status}</span>'
