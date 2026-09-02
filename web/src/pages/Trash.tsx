import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { api, AssetThin } from "../api";
import PhotoGrid from "../components/PhotoGrid";
import { useToast } from "../components/Toast";

export default function Trash() {
  const qc = useQueryClient();
  const toast = useToast();
  const [selected, setSelected] = useState<Set<string>>(new Set());

  const { data: assets, isLoading } = useQuery({ queryKey: ["trash"], queryFn: api.trash });

  const invalidate = () => {
    qc.invalidateQueries({ queryKey: ["trash"] });
    qc.invalidateQueries({ queryKey: ["buckets"] });
    qc.invalidateQueries({ queryKey: ["bucket"] });
  };

  const toggleSelect = (asset: AssetThin) => {
    setSelected((old) => {
      const s = new Set(old);
      if (s.has(asset.id)) s.delete(asset.id);
      else s.add(asset.id);
      return s;
    });
  };

  const restoreSelected = async () => {
    await api.restore(Array.from(selected));
    toast(`Restored ${selected.size}`);
    setSelected(new Set());
    invalidate();
  };

  const deleteSelected = async () => {
    if (!window.confirm(`Permanently delete ${selected.size} item(s)? This cannot be undone.`))
      return;
    for (const id of selected) await api.permanentDelete(id);
    toast(`Permanently deleted ${selected.size}`);
    setSelected(new Set());
    invalidate();
  };

  const empty = async () => {
    if (!window.confirm("Permanently delete EVERYTHING in trash? This cannot be undone.")) return;
    await api.emptyTrash();
    toast("Trash emptied");
    invalidate();
  };

  return (
    <div className="page">
      <div className="row" style={{ justifyContent: "space-between", marginBottom: 16 }}>
        <h1 style={{ marginBottom: 0 }}>Trash</h1>
        {assets && assets.length > 0 && (
          <button className="danger" onClick={empty}>
            Empty trash
          </button>
        )}
      </div>

      {selected.size > 0 && (
        <div className="selectbar">
          <strong>{selected.size} selected</strong>
          <button onClick={restoreSelected}>↩ Restore</button>
          <button className="danger" onClick={deleteSelected}>
            Delete forever
          </button>
          <span style={{ flex: 1 }} />
          <button onClick={() => setSelected(new Set())}>Clear</button>
        </div>
      )}

      {isLoading && <p className="muted">Loading…</p>}
      {assets && assets.length === 0 && <p className="muted">Trash is empty.</p>}
      {assets && assets.length > 0 && (
        <PhotoGrid
          assets={assets}
          selected={selected}
          onOpen={(a) => toggleSelect(a)}
          onToggleSelect={toggleSelect}
        />
      )}
    </div>
  );
}
