import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { api, thumbUrl } from "../api";

export default function Albums() {
  const { data: albums, isLoading } = useQuery({ queryKey: ["albums"], queryFn: api.albums });
  const [name, setName] = useState("");
  const qc = useQueryClient();
  const navigate = useNavigate();

  const create = async () => {
    if (!name.trim()) return;
    const album = await api.createAlbum(name.trim());
    setName("");
    qc.invalidateQueries({ queryKey: ["albums"] });
    navigate(`/albums/${album.id}`);
  };

  return (
    <div className="page">
      <h1>Albums</h1>
      <div className="row" style={{ marginBottom: 16 }}>
        <input
          placeholder="New album name"
          value={name}
          onChange={(e) => setName(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && create()}
        />
        <button className="primary" onClick={create} disabled={!name.trim()}>
          Create
        </button>
      </div>
      {isLoading && <p className="muted">Loading…</p>}
      {albums && albums.length === 0 && <p className="muted">No albums yet.</p>}
      <div className="album-grid">
        {albums?.map((al) => (
          <div key={al.id} className="album-card" onClick={() => navigate(`/albums/${al.id}`)}>
            <div className="cover">
              {al.cover_asset_id && <img src={thumbUrl(al.cover_asset_id)} loading="lazy" alt="" />}
            </div>
            <div className="meta">
              <div className="name">{al.name}</div>
              <div className="muted">
                {al.asset_count} item{al.asset_count === 1 ? "" : "s"}
              </div>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
