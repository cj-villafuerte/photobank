import { AssetThin, thumbUrl } from "../api";

function fmtDuration(sec: number | null): string {
  if (!sec) return "▶";
  const m = Math.floor(sec / 60);
  const s = Math.round(sec % 60);
  return `${m}:${String(s).padStart(2, "0")}`;
}

export function fmtBytes(bytes: number): string {
  if (bytes >= 1073741824) return `${(bytes / 1073741824).toFixed(1)} GB`;
  if (bytes >= 1048576) return `${(bytes / 1048576).toFixed(1)} MB`;
  if (bytes >= 1024) return `${(bytes / 1024).toFixed(0)} KB`;
  return `${bytes} B`;
}

interface Props {
  assets: AssetThin[];
  selected: Set<string>;
  onOpen: (asset: AssetThin) => void;
  onToggleSelect: (asset: AssetThin, shiftKey: boolean) => void;
  showSize?: boolean;
}

export default function PhotoGrid({ assets, selected, onOpen, onToggleSelect, showSize }: Props) {
  const selecting = selected.size > 0;
  return (
    <div className="grid">
      {assets.map((a) => {
        const isSel = selected.has(a.id);
        return (
          <div
            key={a.id}
            className={`cell${isSel ? " selected" : ""}`}
            onClick={(e) => {
              if (selecting || e.ctrlKey || e.metaKey) onToggleSelect(a, e.shiftKey);
              else onOpen(a);
            }}
            onContextMenu={(e) => {
              e.preventDefault();
              onToggleSelect(a, false);
            }}
            title={new Date(a.taken_at).toLocaleString()}
          >
            <img src={thumbUrl(a.id)} loading="lazy" alt="" draggable={false} />
            {a.asset_type === "video" && <span className="badge">{fmtDuration(a.duration_sec)}</span>}
            {a.has_live_video && <span className="badge live">◉ LIVE</span>}
            {showSize && <span className="badge size">{fmtBytes(a.file_size)}</span>}
            {a.is_favorite && <span className="fav">❤️</span>}
            {isSel && <span className="check">✓</span>}
          </div>
        );
      })}
    </div>
  );
}
