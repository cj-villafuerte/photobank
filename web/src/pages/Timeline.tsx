import { useEffect, useRef, useState } from "react";
import { useInfiniteQuery, useQuery, useQueryClient } from "@tanstack/react-query";
import { api, AssetThin, SizeSort } from "../api";
import PhotoGrid from "../components/PhotoGrid";
import Lightbox from "../components/Lightbox";
import UploadButton from "../components/UploadButton";
import { useToast } from "../components/Toast";

function monthLabel(bucket: string): string {
  const [y, m] = bucket.split("-").map(Number);
  return new Date(y, m - 1, 1).toLocaleDateString(undefined, { year: "numeric", month: "long" });
}

interface LightboxState {
  assets: AssetThin[];
  index: number;
}

function MonthSection({
  bucket,
  count,
  favorites,
  selected,
  onOpen,
  onToggleSelect,
}: {
  bucket: string;
  count: number;
  favorites: boolean;
  selected: Set<string>;
  onOpen: (assets: AssetThin[], index: number) => void;
  onToggleSelect: (asset: AssetThin) => void;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const [visible, setVisible] = useState(false);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const obs = new IntersectionObserver(
      (entries) => entries.forEach((e) => e.isIntersecting && setVisible(true)),
      { rootMargin: "600px" }
    );
    obs.observe(el);
    return () => obs.disconnect();
  }, []);

  const { data: assets } = useQuery({
    queryKey: ["bucket", bucket, favorites],
    queryFn: () => api.bucket(bucket, favorites),
    enabled: visible,
    // thumbnails are generated in the background: keep asking until this month has them all
    refetchInterval: (q) => (q.state.data?.some((a) => a.thumb_status !== "done") ? 5_000 : false),
  });

  return (
    <div ref={ref}>
      <div className="month-header">
        {monthLabel(bucket)} <span className="muted">· {count}</span>
      </div>
      {assets ? (
        <PhotoGrid
          assets={assets}
          selected={selected}
          onOpen={(a) => onOpen(assets, assets.indexOf(a))}
          onToggleSelect={(a) => onToggleSelect(a)}
        />
      ) : (
        <div
          className="muted"
          style={{ minHeight: Math.ceil(count / 8) * 80, paddingTop: 8 }}
        >
          Loading…
        </div>
      )}
    </div>
  );
}

export default function Timeline({ favorites }: { favorites: boolean }) {
  const qc = useQueryClient();
  const toast = useToast();
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [lightbox, setLightbox] = useState<LightboxState | null>(null);
  const [albumPick, setAlbumPick] = useState("");
  const [sort, setSort] = useState<"date" | SizeSort>("date");

  const PAGE = 200;
  const sizeQuery = useInfiniteQuery({
    queryKey: ["sizelist", sort, favorites],
    queryFn: ({ pageParam }) => api.listAssets(sort as SizeSort, pageParam, PAGE, favorites),
    getNextPageParam: (last, pages) => (last.length === PAGE ? pages.length * PAGE : undefined),
    initialPageParam: 0,
    enabled: sort !== "date",
  });
  const sizeAssets = sizeQuery.data?.pages.flat() ?? [];

  // Phones upload while this page sits open (the desktop window especially): poll the
  // cheap month summary, and when it changes, refetch the months that are on screen.
  const { data: buckets, isLoading } = useQuery({
    queryKey: ["buckets", favorites],
    queryFn: () => api.buckets(favorites),
    refetchInterval: 15_000,
  });
  const bucketSignature = buckets?.map((b) => `${b.bucket}:${b.count}`).join(",") ?? "";
  const lastSignature = useRef(bucketSignature);
  useEffect(() => {
    if (bucketSignature && lastSignature.current && bucketSignature !== lastSignature.current) {
      qc.invalidateQueries({ queryKey: ["bucket"] });
      qc.invalidateQueries({ queryKey: ["sizelist"] });
    }
    lastSignature.current = bucketSignature;
  }, [bucketSignature, qc]);
  const { data: albums } = useQuery({ queryKey: ["albums"], queryFn: api.albums });

  // reset selection when switching between timeline and favorites
  useEffect(() => {
    setSelected(new Set());
    setLightbox(null);
  }, [favorites]);

  const invalidate = () => {
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

  const favoriteSelected = async (value: boolean) => {
    for (const id of selected) await api.setFavorite(id, value);
    setSelected(new Set());
    invalidate();
  };

  const trashSelected = async () => {
    for (const id of selected) await api.trashAsset(id);
    toast(`${selected.size} moved to trash`);
    setSelected(new Set());
    invalidate();
  };

  const hideSelected = async () => {
    await api.hide(Array.from(selected));
    toast(`${selected.size} hidden`);
    setSelected(new Set());
    invalidate();
  };

  const addSelectedToAlbum = async () => {
    if (!albumPick) return;
    await api.addToAlbum(albumPick, Array.from(selected));
    toast(`Added ${selected.size} to album`);
    setSelected(new Set());
    setAlbumPick("");
    qc.invalidateQueries({ queryKey: ["albums"] });
    qc.invalidateQueries({ queryKey: ["album"] });
  };

  const toggleFavoriteInLightbox = async (asset: AssetThin) => {
    const updated = await api.setFavorite(asset.id, !asset.is_favorite);
    setLightbox((lb) =>
      lb
        ? {
            ...lb,
            assets: lb.assets.map((a) =>
              a.id === asset.id ? { ...a, is_favorite: updated.is_favorite } : a
            ),
          }
        : null
    );
    invalidate();
  };

  const trashInLightbox = async (asset: AssetThin) => {
    await api.trashAsset(asset.id);
    toast("Moved to trash");
    setLightbox((lb) => {
      if (!lb) return null;
      const rest = lb.assets.filter((a) => a.id !== asset.id);
      if (rest.length === 0) return null;
      return { assets: rest, index: Math.min(lb.index, rest.length - 1) };
    });
    invalidate();
  };

  return (
    <div className="page">
      <div className="row" style={{ justifyContent: "space-between", marginBottom: 8 }}>
        <h1 style={{ marginBottom: 0 }}>{favorites ? "Favorites" : "Timeline"}</h1>
        <div className="row">
          <select value={sort} onChange={(e) => setSort(e.target.value as "date" | SizeSort)}>
            <option value="date">Newest first</option>
            <option value="size_desc">Largest first</option>
            <option value="size_asc">Smallest first</option>
          </select>
          <UploadButton />
        </div>
      </div>
      <p className="muted" style={{ marginBottom: 12, fontSize: "0.85rem" }}>
        Tip: Ctrl+click or right-click a photo to select multiple.
      </p>

      {selected.size > 0 && (
        <div className="selectbar">
          <strong>{selected.size} selected</strong>
          <button onClick={() => favoriteSelected(true)}>❤️ Favorite</button>
          <button onClick={() => favoriteSelected(false)}>💔 Unfavorite</button>
          <select value={albumPick} onChange={(e) => setAlbumPick(e.target.value)}>
            <option value="">Add to album…</option>
            {albums?.map((al) => (
              <option key={al.id} value={al.id}>
                {al.name}
              </option>
            ))}
          </select>
          {albumPick && <button onClick={addSelectedToAlbum}>Add</button>}
          <button onClick={hideSelected}>🙈 Hide</button>
          <button className="danger" onClick={trashSelected}>
            🗑 Trash
          </button>
          <span className="spacer" style={{ flex: 1 }} />
          <button onClick={() => setSelected(new Set())}>Clear</button>
        </div>
      )}

      {sort === "date" ? (
        <>
          {isLoading && <p className="muted">Loading…</p>}
          {buckets && buckets.length === 0 && (
            <p className="muted">
              {favorites ? "No favorites yet." : "Your library is empty — upload some photos!"}
            </p>
          )}
          {buckets?.map((b) => (
            <MonthSection
              key={b.bucket}
              bucket={b.bucket}
              count={b.count}
              favorites={favorites}
              selected={selected}
              onOpen={(assets, index) => setLightbox({ assets, index })}
              onToggleSelect={toggleSelect}
            />
          ))}
        </>
      ) : (
        <>
          {sizeQuery.isLoading && <p className="muted">Loading…</p>}
          <PhotoGrid
            assets={sizeAssets}
            selected={selected}
            showSize
            onOpen={(a) => setLightbox({ assets: sizeAssets, index: sizeAssets.indexOf(a) })}
            onToggleSelect={(a) => toggleSelect(a)}
          />
          {sizeQuery.hasNextPage && (
            <div className="row" style={{ justifyContent: "center", margin: 16 }}>
              <button
                onClick={() => sizeQuery.fetchNextPage()}
                disabled={sizeQuery.isFetchingNextPage}
              >
                {sizeQuery.isFetchingNextPage ? "Loading…" : "Load more"}
              </button>
            </div>
          )}
        </>
      )}

      {lightbox && (
        <Lightbox
          assets={lightbox.assets}
          index={lightbox.index}
          onClose={() => setLightbox(null)}
          onNavigate={(index) => setLightbox({ ...lightbox, index })}
          onToggleFavorite={toggleFavoriteInLightbox}
          onTrash={trashInLightbox}
        />
      )}
    </div>
  );
}
