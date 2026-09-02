import { useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { api, AssetThin } from "../api";
import PhotoGrid from "../components/PhotoGrid";
import Lightbox from "../components/Lightbox";
import { useToast } from "../components/Toast";

export default function AlbumDetail() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const qc = useQueryClient();
  const toast = useToast();
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [lightboxIndex, setLightboxIndex] = useState<number | null>(null);

  const { data: album, isLoading, error } = useQuery({
    queryKey: ["album", id],
    queryFn: () => api.album(id!),
    enabled: !!id,
  });

  if (isLoading) return <div className="page muted">Loading…</div>;
  if (error || !album) return <div className="page error">Album not found.</div>;

  const invalidate = () => {
    qc.invalidateQueries({ queryKey: ["album", id] });
    qc.invalidateQueries({ queryKey: ["albums"] });
  };

  const rename = async () => {
    const name = window.prompt("Album name", album.name);
    if (name && name.trim() && name !== album.name) {
      await api.renameAlbum(album.id, name.trim());
      invalidate();
    }
  };

  const removeAlbum = async () => {
    if (!window.confirm(`Delete album "${album.name}"? Photos stay in your library.`)) return;
    await api.deleteAlbum(album.id);
    qc.invalidateQueries({ queryKey: ["albums"] });
    navigate("/albums");
  };

  const removeSelected = async () => {
    await api.removeFromAlbum(album.id, Array.from(selected));
    toast(`Removed ${selected.size} from album`);
    setSelected(new Set());
    invalidate();
  };

  const toggleSelect = (asset: AssetThin) => {
    setSelected((old) => {
      const s = new Set(old);
      if (s.has(asset.id)) s.delete(asset.id);
      else s.add(asset.id);
      return s;
    });
  };

  const toggleFavorite = async (asset: AssetThin) => {
    await api.setFavorite(asset.id, !asset.is_favorite);
    invalidate();
  };

  return (
    <div className="page">
      <div className="row" style={{ justifyContent: "space-between", marginBottom: 16 }}>
        <h1 style={{ marginBottom: 0 }}>{album.name}</h1>
        <div className="row">
          <button onClick={rename}>✏️ Rename</button>
          <button className="danger" onClick={removeAlbum}>
            🗑 Delete album
          </button>
        </div>
      </div>

      {selected.size > 0 && (
        <div className="selectbar">
          <strong>{selected.size} selected</strong>
          <button onClick={removeSelected}>Remove from album</button>
          <span style={{ flex: 1 }} />
          <button onClick={() => setSelected(new Set())}>Clear</button>
        </div>
      )}

      {album.assets.length === 0 ? (
        <p className="muted">Empty album — select photos in the timeline and add them here.</p>
      ) : (
        <PhotoGrid
          assets={album.assets}
          selected={selected}
          onOpen={(a) => setLightboxIndex(album.assets.indexOf(a))}
          onToggleSelect={toggleSelect}
        />
      )}

      {lightboxIndex !== null && (
        <Lightbox
          assets={album.assets}
          index={lightboxIndex}
          onClose={() => setLightboxIndex(null)}
          onNavigate={setLightboxIndex}
          onToggleFavorite={toggleFavorite}
        />
      )}
    </div>
  );
}
