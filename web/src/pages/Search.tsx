import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { api, previewUrl, TextSearchResult, thumbUrl } from "../api";

/** Full-screen view of one result with the matched words boxed on the image. */
function MatchViewer({ result, onClose }: { result: TextSearchResult; onClose: () => void }) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  return (
    <div className="lightbox">
      <div className="lb-top">
        <span className="muted" style={{ marginRight: "auto", padding: "0 8px" }}>
          {result.matches.length} match{result.matches.length === 1 ? "" : "es"}:{" "}
          {[...new Set(result.matches.map((m) => m.word))].slice(0, 6).join(", ")}
        </span>
        <button onClick={onClose}>✕ Close</button>
      </div>
      <div className="lb-main" onClick={(e) => e.target === e.currentTarget && onClose()}>
        {/* container shrink-wraps the image so % box positions line up exactly */}
        <div style={{ position: "relative", display: "inline-block" }}>
          <img
            src={previewUrl(result.asset.id)}
            alt=""
            style={{ maxWidth: "95vw", maxHeight: "calc(100vh - 120px)", display: "block" }}
          />
          {result.matches.map((m, i) => (
            <div
              key={i}
              title={m.word}
              style={{
                position: "absolute",
                left: `${m.x * 100}%`,
                top: `${m.y * 100}%`,
                width: `${m.w * 100}%`,
                height: `${m.h * 100}%`,
                border: "2px solid var(--accent)",
                borderRadius: 3,
                boxShadow: "0 0 0 2000px rgba(0,0,0,0.25)",
                background: "rgba(74,158,255,0.15)",
              }}
            />
          ))}
        </div>
      </div>
      <div className="lb-caption">
        {new Date(result.asset.taken_at).toLocaleString()} — matched text is outlined
      </div>
    </div>
  );
}

export default function Search() {
  const [input, setInput] = useState("");
  const [q, setQ] = useState("");
  const [open, setOpen] = useState<TextSearchResult | null>(null);

  // debounce typing
  useEffect(() => {
    const t = setTimeout(() => setQ(input.trim()), 350);
    return () => clearTimeout(t);
  }, [input]);

  const { data: results, isFetching } = useQuery({
    queryKey: ["textsearch", q],
    queryFn: () => api.searchText(q),
    enabled: q.length >= 2,
  });

  return (
    <div className="page">
      <h1>Search text in photos</h1>
      <input
        autoFocus
        placeholder="Type text that appears in a photo — signs, receipts, screenshots…"
        value={input}
        onChange={(e) => setInput(e.target.value)}
        style={{ width: "100%", maxWidth: 560, marginBottom: 16 }}
      />
      {q.length >= 2 && !isFetching && results && results.length === 0 && (
        <p className="muted">
          No matches for “{q}”. Text is indexed in the background after upload — very recent
          photos may not be searchable yet.
        </p>
      )}
      {isFetching && <p className="muted">Searching…</p>}
      {results && results.length > 0 && (
        <>
          <p className="muted" style={{ marginBottom: 10 }}>
            {results.length} photo{results.length === 1 ? "" : "s"} — click one to see where “{q}”
            appears.
          </p>
          <div className="grid">
            {results.map((r) => (
              <div key={r.asset.id} className="cell" onClick={() => setOpen(r)}>
                <img src={thumbUrl(r.asset.id)} loading="lazy" alt="" />
                <span className="badge">{r.matches.length}×</span>
              </div>
            ))}
          </div>
        </>
      )}
      {open && <MatchViewer result={open} onClose={() => setOpen(null)} />}
    </div>
  );
}
