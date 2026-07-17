import { useState } from "react";
import { Button } from "./ui/button";
import { Input } from "./ui/input";

interface Props {
  onSend: (type: string, source: string, data: string, subject: string) => Promise<void>;
}

export function MessageSender({ onSend }: Props) {
  const [type, setType] = useState("com.example.demo");
  const [source, setSource] = useState("/demo/ui");
  const [subject, setSubject] = useState("");
  const [data, setData] = useState('{"message": "Hello from the UI!"}');
  const [sending, setSending] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setSending(true);
    try {
      await onSend(type, source, data, subject);
    } finally {
      setSending(false);
    }
  };

  return (
    <form onSubmit={handleSubmit} className="p-4 space-y-3">
      <div className="grid grid-cols-2 gap-3">
        <div>
          <label className="text-xs text-muted-foreground mb-1 block">Type</label>
          <Input value={type} onChange={(e) => setType(e.target.value)} placeholder="com.example.demo" />
        </div>
        <div>
          <label className="text-xs text-muted-foreground mb-1 block">Source</label>
          <Input value={source} onChange={(e) => setSource(e.target.value)} placeholder="/demo/ui" />
        </div>
      </div>
      <div>
        <label className="text-xs text-muted-foreground mb-1 block">Subject (optional)</label>
        <Input value={subject} onChange={(e) => setSubject(e.target.value)} placeholder="my-topic" />
      </div>
      <div>
        <label className="text-xs text-muted-foreground mb-1 block">Data (JSON)</label>
        <textarea
          value={data}
          onChange={(e) => setData(e.target.value)}
          rows={3}
          className="flex w-full rounded-md border border-input bg-background px-3 py-2 text-sm ring-offset-background placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 font-mono"
        />
      </div>
      <Button type="submit" disabled={sending} className="w-full">
        {sending ? "Sending…" : "Send Event"}
      </Button>
    </form>
  );
}
