"""Event display widget for Jupyter notebooks.

A simple ipywidgets-based component that renders CloudEvents inline.
Used in handlers to visualize incoming events.

Usage:
    from event_stream import EventStream
    stream = EventStream()
    stream.display()

    # In a handler:
    @bus.handler("com.example.demo")
    async def on_event(event, ctx):
        stream.append(event)
        return Disposition.COMPLETE
"""

import json
from IPython.display import display, HTML
import ipywidgets as widgets


class EventStream:
    """Visual event stream component for Jupyter notebooks."""

    def __init__(self, title: str = "📡 Event Stream"):
        self._events: list = []
        self._output = widgets.Output(layout=widgets.Layout(
            max_height="400px",
            overflow_y="auto",
            border="1px solid #333",
            padding="8px",
        ))
        self._counter = widgets.HTML(value=self._count_badge(0))
        self._container = widgets.VBox([
            widgets.HBox([widgets.HTML(f"<b>{title}</b>"), self._counter]),
            self._output
        ])

    def display(self):
        """Show the widget in the notebook."""
        display(self._container)

    def append(self, event):
        """Add a CloudEvent to the stream display."""
        self._events.append(event)
        self._counter.value = self._count_badge(len(self._events))
        with self._output:
            time = getattr(event, "time", "")
            etype = getattr(event, "type", "?")
            source = getattr(event, "source", "?")
            data = getattr(event, "data", {})
            if not isinstance(data, str):
                data = json.dumps(data, indent=2)
            html = f"""
            <div style="margin-bottom:8px; padding:6px; background:var(--jp-layout-color2, #f0f0f0); border:1px solid var(--jp-border-color1, #ddd); border-radius:4px; font-family:monospace; font-size:12px;">
                <span style="color:#22c55e;">●</span>
                <span style="color:var(--jp-content-font-color2, #666);">{time}</span>
                <span style="color:var(--jp-brand-color1, #2563eb); font-weight:bold;">{etype}</span>
                <span style="color:var(--jp-content-font-color2, #666);">from {source}</span>
                <pre style="color:var(--jp-content-font-color1, #333); margin:4px 0 0 16px; white-space:pre-wrap;">{data}</pre>
            </div>
            """
            display(HTML(html))

    def clear(self):
        """Clear all displayed events."""
        self._events.clear()
        self._output.clear_output()
        self._counter.value = self._count_badge(0)

    @staticmethod
    def _count_badge(count: int) -> str:
        return f'<span style="margin-left:8px; color:#94a3b8; font-size:12px;">{count} events</span>'
