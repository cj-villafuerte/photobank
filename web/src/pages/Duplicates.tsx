import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { api, DuplicateGroup, thumbUrl } from "../api";
import { fmtBytes } from "../components/PhotoGrid";
import { useToast } from "../components/Toast";

function GroupCard({ group, onDone }: { group: DuplicateGroup; onDone: () => void }) {
  const toast = useToast();
  // everything except the largest file starts selected for removal
  const [selected, setSelected] = useState<Set<string>>(
    () => new Set(group.assets.slice(1).map((a) => a.id))
  );
  const [busy, setBusy] = useState(false);

  const toggle = (id: string) => {
    setSelected((old) => {
      const s = new Set(old);
      if (s.has(id)) s.delete(id);
      else s.add(id);
      return s;
    });
  };

  const trashSelected = async () => {
    if (selected.size === group.assets.length) {
      toast("Keep at least one copy", true);
      return;
    }
    setBusy(true);
    try {
      for (const id of selected) await api.trashAsset(id);
      toast(`${selected.size} moved to trash`);
      onDone();
    } finally {
      setBusy(false);
    }
  };

  const savable = group.assets
    .filter((a) => selected.has(a.id))
    .reduce((sum, a) => sum + a.file_size, 0);

  return (
    <div className="settings-card" style={{ marginBottom: 16 }}>
      <div className="row" style={{ marginBottom: 10, justifyContent: "space-between" }}>
        <span className="muted">
          {group.assets.length} similar images · up to {fmtBytes(group.wasted_bytes)} reclaimable
        </span>
        <button className="danger" disabled={busy || selected.size === 0} onClick={trashSelected}>
          🗑 Trash {selected.size} selected ({fmtBytes(savable)})
        </button>
      </div>
      <div className="row" style={{ alignItems: "flex-start" }}>
        {group.assets.map((a, i) => {
          const isSel = selected.has(a.id);
          return (
            <div
              key={a.id}
              onClick={() => toggle(a.id)}
              style={{ cursor: "pointer", textAlign: "center", width: 148 }}
            >
              <div
                className={`cell${isSel ? " selected" : ""}`}
                style={{ width: 148, height: 148 }}
              >
                <img src={thumbUrl(a.id)} loading="lazy" alt="" draggable={false} />
                {isSel && <span className="check">✓</span>}
              </div>
              <div style={{ fontSize: "0.78rem", marginTop: 4 }}>
                {fmtBytes(a.file_size)}
                {a.width && a.height ? ` · ${a.width}×${a.height}` : ""}
              </div>
              <div className="muted" style={{ fontSize: "0.72rem" }}>
                {new Date(a.taken_at).toLocaleDateString()}
                {i === 0 && !isSel ? " · keeping" : ""}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

export default function Duplicates() {
  const qc = useQueryClient();
  const { data: groups, isLoading, refetch } = useQuery({
    queryKey: ["duplicates"],
    queryFn: api.duplicates,
  });

  const onDone = () => {
    refetch();
    qc.invalidateQueries({ queryKey: ["buckets"] });
    qc.invalidateQueries({ queryKey: ["bucket"] });
    qc.invalidateQueries({ queryKey: ["sizelist"] });
    qc.invalidateQueries({ queryKey: ["trash"] });
  };

  const totalWasted = groups?.reduce((s, g) => s + g.wasted_bytes, 0) ?? 0;

  return (
    <div className="page" style={{ maxWidth: 1000 }}>
      <h1>Duplicates</h1>
      <p className="muted" style={{ marginBottom: 16 }}>
        Visually similar images found by perceptual fingerprint — resized copies, re-saves, and
        edited versions land here even when the files differ. Selected copies (everything except
        the largest) go to Trash; nothing is deleted permanently until you empty the trash.
      </p>
      {isLoading && <p className="muted">Scanning fingerprints…</p>}
      {groups && groups.length === 0 && (
        <p className="muted">No duplicate-looking images found. 🎉</p>
      )}
      {groups && groups.length > 0 && (
        <p style={{ marginBottom: 16 }}>
          <strong>{groups.length}</strong> groups ·{" "}
          <strong>{fmtBytes(totalWasted)}</strong> reclaimable in total
        </p>
      )}
      {groups?.map((g) => (
        <GroupCard key={g.assets[0].id} group={g} onDone={onDone} />
      ))}
    </div>
  );
}
