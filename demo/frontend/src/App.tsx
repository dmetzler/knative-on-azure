import { useEffect, useRef, useState, useCallback } from "react";
import { MessageList } from "./components/MessageList";
import { MessageSender } from "./components/MessageSender";

export interface CloudEventRecord {
  id: string;
  type: string;
  source: string;
  specversion: string;
  time: string;
  datacontenttype: string;
  subject: string | null;
  data: unknown;
  extensions: Record<string, string>;
  received_at: string;
}

export default function App() {
  const [messages, setMessages] = useState<CloudEventRecord[]>([]);
  const [connected, setConnected] = useState(false);
  const wsRef = useRef<WebSocket | null>(null);

  // Fetch existing messages on mount
  useEffect(() => {
    fetch("/api/messages")
      .then((r) => r.json())
      .then((data: CloudEventRecord[]) => setMessages(data))
      .catch(() => {});
  }, []);

  // WebSocket connection
  useEffect(() => {
    const proto = window.location.protocol === "https:" ? "wss" : "ws";
    const ws = new WebSocket(`${proto}://${window.location.host}/ws`);
    wsRef.current = ws;

    ws.onopen = () => setConnected(true);
    ws.onclose = () => setConnected(false);
    ws.onmessage = (ev) => {
      try {
        const msg = JSON.parse(ev.data);
        if (msg.type === "event") {
          setMessages((prev) => [...prev, msg.payload as CloudEventRecord]);
        }
      } catch {
        // ignore
      }
    };

    return () => ws.close();
  }, []);

  const handleSend = useCallback(
    async (type: string, source: string, data: string, subject: string) => {
      let parsed: unknown;
      try {
        parsed = JSON.parse(data);
      } catch {
        parsed = data;
      }

      await fetch("/api/send", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ type, source, data: parsed, subject: subject || null }),
      });
    },
    []
  );

  return (
    <div className="flex flex-col h-screen">
      {/* Header */}
      <header className="flex items-center justify-between border-b px-6 py-3">
        <h1 className="text-lg font-semibold">KNative Messaging Demo</h1>
        <div className="flex items-center gap-2 text-sm text-muted-foreground">
          <span
            className={`inline-block h-2 w-2 rounded-full ${connected ? "bg-green-500" : "bg-red-500"}`}
          />
          {connected ? "Connected" : "Disconnected"}
        </div>
      </header>

      {/* Split layout */}
      <div className="flex flex-1 overflow-hidden">
        {/* Left pane — JupyterLite */}
        <div className="w-1/2 border-r">
          <iframe
            src="/jupyterlite/"
            title="JupyterLite"
            className="w-full h-full border-0"
            sandbox="allow-scripts allow-same-origin allow-popups"
          />
        </div>

        {/* Right pane — ServiceBus-style UI */}
        <div className="flex flex-col w-1/2">
          <div className="flex-1 overflow-hidden">
            <MessageList messages={messages} />
          </div>
          <div className="border-t">
            <MessageSender onSend={handleSend} />
          </div>
        </div>
      </div>
    </div>
  );
}
