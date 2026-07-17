import { ScrollArea } from "./ui/scroll-area";
import { Card, CardContent } from "./ui/card";
import { Badge } from "./ui/badge";
import type { CloudEventRecord } from "../App";
import { useEffect, useRef } from "react";

interface Props {
  messages: CloudEventRecord[];
}

export function MessageList({ messages }: Props) {
  const bottomRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages.length]);

  if (messages.length === 0) {
    return (
      <div className="flex items-center justify-center h-full text-muted-foreground text-sm">
        No messages yet — send one below or from a notebook.
      </div>
    );
  }

  return (
    <ScrollArea className="h-full p-4 space-y-3">
      {messages.map((msg) => (
        <Card key={msg.id} className="mb-3">
          <CardContent className="p-4">
            <div className="flex items-start justify-between gap-2 mb-2">
              <div className="flex items-center gap-2 flex-wrap">
                <Badge variant="secondary">{msg.type}</Badge>
                {msg.subject && <Badge variant="outline">{msg.subject}</Badge>}
              </div>
              <span className="text-xs text-muted-foreground whitespace-nowrap">
                {new Date(msg.received_at).toLocaleTimeString()}
              </span>
            </div>
            <div className="text-xs text-muted-foreground mb-1">
              <span className="font-medium">source:</span> {msg.source} &middot;{" "}
              <span className="font-medium">id:</span> {msg.id.slice(0, 8)}…
            </div>
            <pre className="text-sm bg-muted/50 rounded p-2 overflow-x-auto mt-2">
              {typeof msg.data === "string" ? msg.data : JSON.stringify(msg.data, null, 2)}
            </pre>
          </CardContent>
        </Card>
      ))}
      <div ref={bottomRef} />
    </ScrollArea>
  );
}
