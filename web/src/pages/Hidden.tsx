import { useState } from "react";
import { Link } from "react-router-dom";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { api, AssetThin } from "../api";
import PhotoGrid from "../components/PhotoGrid";
import Lightbox from "../components/Lightbox";
import { useToast } from "../components/Toast";

export default function Hidden() {
  const qc = useQueryClient();
  const toast = useToast();
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [lightboxIndex, setLightboxIndex] = useState<number | null>(null);

  const { data: assets, isLoading } = useQuery({ queryKey: ["hidden"], queryFn: api.hidden });

  const invalidate = () => {
    qc.invalidateQueries({ queryKey: ["hidden"] });
    qc.invalidateQueries({ queryKey: ["buckets"] });
    qc.invalidateQueries({ queryKey: ["bucket"] });
    qc.invalidateQueries({ queryKey: ["sizelist"] });
  };

  const toggleSelect = (asset: AssetThin) => {
    setSelected((old) => {
      const s = new Set(old);
      if (s.has(asset.id)) s.delete(asset.id);
      else s.add(asset.id);
      return s;
    });
  };

  const unhideSelected = async () => {
    await api.unhide(Array.from(selected));
    toast(`${selected.size} restored to the timeline`);
    setSelected(new Set());
    invalidate();
  };

  const trashSelected = async () => {
    for (const id of selected) await api.trashAsset(id);
    toast(`${selected.size} moved to trash`);
    setSelected(new Set());
    invalidate();
  };

  return (
    <div className="page">
      <div className="row" style={{ marginBottom: 16 }}>
        <Link to="/settings">
          <button>← Settings</button>
        </Link>
        <h1 style={{ marginBottom: 0 }}>Hidden photos</h1>
      </div>

      {selected.size > 0 && (
        <div className="selectbar">
          <strong>{selected.size} selected</strong>
          <button onClick={unhideSelected}>👁 Unhide</button>
          <button className="danger" onClick={trashSelected}>
            🗑 Trash
          </button>
          <span style={{ flex: 1 }} />
          <button onClick={() => setSelected(new Set())}>Clear</button>
        </div>
      )}

      {isLoading && <p className="muted">Loading…</p>}
      {assets && assets.length === 0 && <p className="muted">Nothing is hidden.</p>}
      {assets && assets.length > 0 && (
        <PhotoGrid
          assets={assets}
          selected={selected}
          onOpen={(a) => setLightboxIndex(assets.indexOf(a))}
          onToggleSelect={toggleSelect}
        />
      )}

      {lightboxIndex !== null && assets && (
        <Lightbox
          assets={assets}
          index={lightboxIndex}
          onClose={() => setLightboxIndex(null)}
          onNavigate={setLightboxIndex}
        />
      )}
    </div>
  );
}
