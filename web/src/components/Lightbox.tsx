import { useCallback, useEffect, useState } from "react";
import { api, ApiError, AssetThin, downloadUrl, liveVideoUrl, originalUrl, previewUrl } from "../api";
import { isDesktop } from "../App";
import { useToast } from "./Toast";

interface Props {
  assets: AssetThin[];
  index: number;
  onClose: () => void;
  onNavigate: (index: number) => void;
  onToggleFavorite?: (asset: AssetThin) => void;
  onTrash?: (asset: AssetThin) => void;
}

export default function Lightbox({
  assets,
  index,
  onClose,
  onNavigate,
  onToggleFavorite,
  onTrash,
}: Props) {
  const asset = assets[index];
  const [liveActive, setLiveActive] = useState(false);
  const toast = useToast();

  const reveal = async () => {
    try {
      await api.reveal(asset.id);
      toast("Opened in File Explorer on the server PC");
    } catch (e) {
      toast(e instanceof ApiError ? e.message : "Could not open Explorer", true);
    }
  };

  useEffect(() => setLiveActive(false), [index]);

  const prev = useCallback(() => {
    if (index > 0) onNavigate(index - 1);
  }, [index, onNavigate]);
  const next = useCallback(() => {
    if (index < assets.length - 1) onNavigate(index + 1);
  }, [index, assets.length, onNavigate]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
      else if (e.key === "ArrowLeft") prev();
      else if (e.key === "ArrowRight") next();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose, prev, next]);

  if (!asset) return null;

  return (
    <div className="lightbox">
      {/* the inverted panel's toolbar: mono labels, no fills, the accent only for
          the favorite mark and the destructive action (THEME.md) */}
      <div className="lb-top">
        <span className="lb-title">
          {new Date(asset.taken_at).toLocaleString()} · {index + 1} / {assets.length}
        </span>
        {asset.has_live_video && (
          <button className={liveActive ? "on" : undefined} onClick={() => setLiveActive(!liveActive)}>
            {liveActive ? "Still" : "Live"}
          </button>
        )}
        {onToggleFavorite && (
          <button className={asset.is_favorite ? "on" : undefined} onClick={() => onToggleFavorite(asset)}>
            {asset.is_favorite && <span className="fav-dot" />}
            {asset.is_favorite ? "Favorited" : "Favorite"}
          </button>
        )}
        <a href={downloadUrl(asset.id)} download>
          <button>Download</button>
        </a>
        {isDesktop() && (
          <button onClick={reveal} title="Show the original file in File Explorer">
            Show file
          </button>
        )}
        {onTrash && (
          <button className="danger" onClick={() => onTrash(asset)}>
            Trash
          </button>
        )}
        <button onClick={onClose} aria-label="Close">
          Close
        </button>
      </div>
      <div className="lb-main" onClick={(e) => e.target === e.currentTarget && onClose()}>
        {index > 0 && (
          <button className="lb-nav prev" onClick={prev}>
            ‹
          </button>
        )}
        {asset.asset_type === "video" ? (
          <video key={asset.id} src={originalUrl(asset.id)} controls autoPlay />
        ) : liveActive ? (
          <video
            key={`${asset.id}-live`}
            src={liveVideoUrl(asset.id)}
            autoPlay
            playsInline
            onEnded={() => setLiveActive(false)}
            onError={() => setLiveActive(false)}
          />
        ) : (
          <img key={asset.id} src={previewUrl(asset.id)} alt="" />
        )}
        {index < assets.length - 1 && (
          <button className="lb-nav next" onClick={next}>
            ›
          </button>
        )}
      </div>
    </div>
  );
}
