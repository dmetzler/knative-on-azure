import { useEffect, useRef, useState, useCallback } from "react";
import { MessageList } from "./components/MessageList";
import { MessageSender } from "./components/MessageSender";
import { AsbExplorer } from "./components/AsbExplorer";

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

type Tab = "demo" | "jupyter";

export default function App() {
  const [messages, setMessages] = useState<CloudEventRecord[]>([]);
  const [connected, setConnected] = useState(false);
  const [activeTab, setActiveTab] = useState<Tab>("demo");
  const wsRef = useRef<WebSocket | null>(null);

  useEffect(() => {
    fetch("/api/messages")
      .then((r) => r.json())
      .then((data: CloudEventRecord[]) => setMessages(data))
      .catch(() => {});
  }, []);

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

  const handleClear = useCallback(async () => {
    await fetch("/api/messages", { method: "DELETE" });
    setMessages([]);
  }, []);

  return (
    <div className="flex flex-col h-screen bg-background text-foreground">
      {/* Header */}
      <header className="flex items-center justify-between border-b border-border px-6 py-3 shrink-0">
        <div className="flex items-center gap-6">
          <h1 className="text-lg font-semibold">KNative Messaging Demo</h1>
          <nav className="flex gap-1">
            <button
              onClick={() => setActiveTab("demo")}
              className={`px-3 py-1.5 text-sm rounded-md transition-colors ${
                activeTab === "demo"
                  ? "bg-primary text-primary-foreground"
                  : "text-muted-foreground hover:text-foreground hover:bg-muted"
              }`}
            >
              Interactive Demo
            </button>
            <button
              onClick={() => setActiveTab("jupyter")}
              className={`px-3 py-1.5 text-sm rounded-md transition-colors ${
                activeTab === "jupyter"
                  ? "bg-primary text-primary-foreground"
                  : "text-muted-foreground hover:text-foreground hover:bg-muted"
              }`}
            >
              Jupyter Notebook
            </button>
          </nav>
        </div>
        <div className="flex items-center gap-2 text-sm text-muted-foreground">
          <span
            className={`inline-block h-2 w-2 rounded-full ${connected ? "bg-green-500" : "bg-red-500"}`}
          />
          {connected ? "Connected" : "Disconnected"}
        </div>
      </header>

      {/* Main content */}
      <div className="flex flex-1 overflow-hidden">
        {/* Left panel — tab content */}
        <div className="flex-1 flex overflow-hidden">
          {/* Demo tab */}
          <div className={`flex-1 flex overflow-hidden ${activeTab !== "demo" ? "hidden" : ""}`}>
            {/* Messages received */}
            <div className="flex-[2] overflow-hidden">
              <MessageList messages={messages} onClear={handleClear} />
            </div>
            {/* Message Sender */}
            <div className="w-80 border-l border-border shrink-0">
              <MessageSender onSend={handleSend} />
            </div>
          </div>

          {/* Jupyter tab */}
          <div className={`flex-1 overflow-hidden ${activeTab !== "jupyter" ? "hidden" : ""}`}>
            <iframe
              src="/jupyter/lab"
              className="w-full h-full border-0"
              title="Jupyter Notebook"
            />
          </div>
        </div>

        {/* Right: ASB Explorer — always visible */}
        <div className="w-80 border-l border-border shrink-0 overflow-hidden">
          <AsbExplorer />
        </div>
      </div>
    </div>
  );
}
