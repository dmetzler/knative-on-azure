import { useCallback, useEffect, useState } from "react";
import { Card, CardContent } from "./ui/card";
import { Badge } from "./ui/badge";
import { Button } from "./ui/button";
import { ScrollArea } from "./ui/scroll-area";

interface QueueInfo {
  name: string;
  active_message_count: number;
  dead_letter_message_count: number;
  scheduled_message_count: number;
  total_message_count: number;
}

interface PeekedMessage {
  message_id: string;
  body: string;
  content_type: string | null;
  enqueued_time: string | null;
  sequence_number: number;
  subject: string | null;
}

export function AsbExplorer() {
  const [queues, setQueues] = useState<QueueInfo[]>([]);
  const [selectedQueue, setSelectedQueue] = useState<string | null>(null);
  const [messages, setMessages] = useState<PeekedMessage[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [sendBody, setSendBody] = useState('{"hello": "from UI"}');
  const [sending, setSending] = useState(false);

  const fetchQueues = useCallback(async () => {
    try {
      const res = await fetch("/api/asb/queues");
      if (!res.ok) {
        if (res.status === 503) {
          setError("ASB not configured");
          return;
        }
        throw new Error(`HTTP ${res.status}`);
      }
      setError(null);
      setQueues(await res.json());
    } catch (e: any) {
      setError(e.message || "Failed to fetch queues");
    }
  }, []);

  useEffect(() => {
    fetchQueues();
    const interval = setInterval(fetchQueues, 3000);
    return () => clearInterval(interval);
  }, [fetchQueues]);

  const peekQueue = useCallback(async (name: string) => {
    setSelectedQueue(name);
    setLoading(true);
    try {
      const res = await fetch(`/api/asb/peek/${encodeURIComponent(name)}`);
      setMessages(await res.json());
    } catch {
      setMessages([]);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    if (!selectedQueue) return;
    const interval = setInterval(() => peekQueue(selectedQueue), 3000);
    return () => clearInterval(interval);
  }, [selectedQueue, peekQueue]);

  const handleSend = async () => {
    if (!selectedQueue) return;
    setSending(true);
    try {
      await fetch(`/api/asb/send/${encodeURIComponent(selectedQueue)}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ body: sendBody }),
      });
      await peekQueue(selectedQueue);
    } finally {
      setSending(false);
    }
  };

  if (error) {
    return (
      <div className="flex items-center justify-center h-full p-4">
        <p className="text-sm text-muted-foreground">{error}</p>
      </div>
    );
  }

  return (
    <div className="flex flex-col h-full">
      <div className="px-4 py-3 border-b border-border shrink-0">
        <h2 className="text-sm font-semibold">Azure Service Bus</h2>
      </div>

      <ScrollArea className="flex-1 p-3">
        {/* Queue list */}
        <div className="space-y-2 mb-4">
          {queues.map((q) => (
            <Card
              key={q.name}
              className={`cursor-pointer transition-colors ${selectedQueue === q.name ? "border-primary" : ""}`}
              onClick={() => peekQueue(q.name)}
            >
              <CardContent className="p-3">
                <div className="flex items-center justify-between">
                  <span className="text-sm font-medium truncate">{q.name}</span>
                  <div className="flex gap-1">
                    <Badge variant="secondary">{q.active_message_count}</Badge>
                    {q.dead_letter_message_count > 0 && (
                      <Badge variant="destructive">{q.dead_letter_message_count} DLQ</Badge>
                    )}
                  </div>
                </div>
              </CardContent>
            </Card>
          ))}
          {queues.length === 0 && (
            <p className="text-xs text-muted-foreground text-center py-4">No queues found</p>
          )}
        </div>

        {/* Peeked messages */}
        {selectedQueue && (
          <>
            <div className="flex items-center justify-between mb-2">
              <h3 className="text-xs font-semibold text-muted-foreground uppercase">
                {selectedQueue} — Messages
              </h3>
              {loading && <span className="text-xs text-muted-foreground">loading…</span>}
            </div>

            {messages.length === 0 && !loading && (
              <p className="text-xs text-muted-foreground text-center py-2">No messages to peek</p>
            )}

            <div className="space-y-2 mb-4">
              {messages.map((msg) => (
                <Card key={`${msg.sequence_number}-${msg.message_id}`}>
                  <CardContent className="p-2">
                    <div className="flex justify-between text-xs text-muted-foreground mb-1">
                      <span>seq: {msg.sequence_number}</span>
                      {msg.enqueued_time && (
                        <span>{new Date(msg.enqueued_time).toLocaleTimeString()}</span>
                      )}
                    </div>
                    <pre className="text-xs bg-muted/50 rounded p-1.5 overflow-x-auto whitespace-pre-wrap break-all">
                      {msg.body}
                    </pre>
                  </CardContent>
                </Card>
              ))}
            </div>

            {/* Send to queue */}
            <div className="border-t border-border pt-3 space-y-2">
              <label className="text-xs text-muted-foreground block">Send to {selectedQueue}</label>
              <textarea
                value={sendBody}
                onChange={(e) => setSendBody(e.target.value)}
                rows={2}
                className="flex w-full rounded-md border border-input bg-background px-3 py-2 text-xs ring-offset-background placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 font-mono"
              />
              <Button size="sm" onClick={handleSend} disabled={sending} className="w-full">
                {sending ? "Sending…" : "Send to Queue"}
              </Button>
            </div>
          </>
        )}
      </ScrollArea>
    </div>
  );
}
