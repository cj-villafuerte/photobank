export interface User {
  id: string;
  email: string;
  display_name: string;
  is_admin: boolean;
  is_active: boolean;
  created_at: string;
}

export interface AssetThin {
  id: string;
  asset_type: "image" | "video";
  width: number | null;
  height: number | null;
  duration_sec: number | null;
  taken_at: string;
  is_favorite: boolean;
  thumb_status: string;
  has_live_video: boolean;
  file_size: number;
}

export type SizeSort = "size_desc" | "size_asc";

export interface AssetFull extends AssetThin {
  original_filename: string;
  file_size: number;
  mime_type: string;
  taken_at_source: string;
  gps_lat: number | null;
  gps_lon: number | null;
  camera_make: string | null;
  camera_model: string | null;
  trashed_at: string | null;
  created_at: string;
}

export interface TimelineBucket {
  bucket: string;
  count: number;
}

export interface Album {
  id: string;
  name: string;
  cover_asset_id: string | null;
  created_at: string;
  asset_count: number;
}

export interface AlbumDetail extends Album {
  assets: AssetThin[];
}

export interface UploadResult {
  duplicate: boolean;
  asset: AssetFull | null;
  asset_id: string | null;
}

export interface DuplicateGroup {
  assets: AssetThin[];
  wasted_bytes: number;
}

export interface TextMatch {
  word: string;
  x: number;
  y: number;
  w: number;
  h: number;
}

export interface TextSearchResult {
  asset: AssetThin;
  matches: TextMatch[];
}

export interface DailyStat {
  date: string;
  count: number;
  bytes: number;
}

export interface Stats {
  total_count: number;
  total_bytes: number;
  image_count: number;
  video_count: number;
  daily: DailyStat[];
}

export interface BackupState {
  config: { dir: string | null; auto: boolean; include_thumbs: boolean };
  status: {
    running: boolean;
    last_run: string | null;
    last_result: {
      ok?: boolean;
      scanned?: number;
      copied?: number;
      bytes?: number;
      errors?: number;
      database?: string;
      error?: string;
    } | null;
  };
  progress: { phase?: string; scanned?: number; copied?: number; bytes?: number; errors?: number };
}

/** Served by /api/health when the server runs as the public demo. */
export interface DemoInfo {
  email: string;
  password: string;
  upload_ttl_seconds: number;
  max_uploads: number;
  max_upload_mb: number;
}

export interface Health {
  status: string;
  demo: DemoInfo | null;
}

export class ApiError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const headers: Record<string, string> =
    init?.body instanceof FormData ? {} : { "Content-Type": "application/json" };
  Object.assign(headers, (init?.headers as Record<string, string> | undefined) ?? {});
  const res = await fetch(path, { credentials: "include", ...init, headers });
  if (!res.ok) {
    let detail = res.statusText;
    try {
      const body = await res.json();
      if (body.detail) detail = typeof body.detail === "string" ? body.detail : JSON.stringify(body.detail);
    } catch {
      /* not json */
    }
    // lets a global listener surface policy refusals (e.g. the demo server's 403s)
    window.dispatchEvent(
      new CustomEvent("pb:api-error", { detail: { status: res.status, message: detail, path } })
    );
    throw new ApiError(res.status, detail);
  }
  if (res.status === 204) return undefined as T;
  return res.json();
}

export const api = {
  health: () => request<Health>("/api/health"),

  // auth
  me: () => request<User>("/api/auth/me"),
  login: (email: string, password: string) =>
    request<User>("/api/auth/login", { method: "POST", body: JSON.stringify({ email, password }) }),
  register: (email: string, password: string, display_name: string) =>
    request<User>("/api/auth/register", {
      method: "POST",
      body: JSON.stringify({ email, password, display_name }),
    }),
  logout: () => request<void>("/api/auth/logout", { method: "POST" }),
  /** Desktop window only: sign in as the passwordless local administrator. */
  localLogin: (token: string) =>
    request<User>("/api/auth/local", { method: "POST", headers: { "X-Local-Admin": token, "Content-Type": "application/json" } }),
  flags: () => request<Record<string, string>>("/api/admin/flags"),
  setFlag: (key: string, value: string) =>
    request<void>("/api/admin/flags", { method: "PUT", body: JSON.stringify({ key, value }) }),

  // timeline
  buckets: (favorites = false) =>
    request<TimelineBucket[]>(`/api/timeline/buckets?favorites=${favorites}`),
  bucket: (bucket: string, favorites = false) =>
    request<AssetThin[]>(`/api/timeline/bucket/${bucket}?favorites=${favorites}`),

  // assets
  listAssets: (sort: SizeSort, offset: number, limit: number, favorites = false) =>
    request<AssetThin[]>(
      `/api/assets/list?sort=${sort}&offset=${offset}&limit=${limit}&favorites=${favorites}`
    ),
  reveal: (id: string) => request<void>(`/api/assets/${id}/reveal`, { method: "POST" }),
  hide: (asset_ids: string[]) =>
    request<void>("/api/assets/hide", { method: "POST", body: JSON.stringify({ asset_ids }) }),
  unhide: (asset_ids: string[]) =>
    request<void>("/api/assets/unhide", { method: "POST", body: JSON.stringify({ asset_ids }) }),
  hidden: () => request<AssetThin[]>("/api/hidden"),
  duplicates: () => request<DuplicateGroup[]>("/api/duplicates"),
  searchText: (q: string) =>
    request<TextSearchResult[]>(`/api/search/text?q=${encodeURIComponent(q)}`),
  stats: (days: number) => request<Stats>(`/api/stats?days=${days}`),
  changePassword: (current_password: string, new_password: string) =>
    request<void>("/api/auth/change-password", {
      method: "POST",
      body: JSON.stringify({ current_password, new_password }),
    }),
  upload: (file: File): Promise<UploadResult> => {
    const form = new FormData();
    form.append("file", file);
    form.append("last_modified_ms", String(file.lastModified));
    return request<UploadResult>("/api/assets", { method: "POST", body: form });
  },
  asset: (id: string) => request<AssetFull>(`/api/assets/${id}`),
  setFavorite: (id: string, is_favorite: boolean) =>
    request<AssetFull>(`/api/assets/${id}`, {
      method: "PATCH",
      body: JSON.stringify({ is_favorite }),
    }),
  trashAsset: (id: string) => request<void>(`/api/assets/${id}`, { method: "DELETE" }),
  permanentDelete: (id: string) => request<void>(`/api/assets/${id}/permanent`, { method: "DELETE" }),

  // trash
  trash: () => request<AssetThin[]>("/api/trash"),
  restore: (asset_ids: string[]) =>
    request<void>("/api/trash/restore", { method: "POST", body: JSON.stringify({ asset_ids }) }),
  emptyTrash: () => request<void>("/api/trash/empty", { method: "POST" }),

  // albums
  albums: () => request<Album[]>("/api/albums"),
  createAlbum: (name: string) =>
    request<Album>("/api/albums", { method: "POST", body: JSON.stringify({ name }) }),
  album: (id: string) => request<AlbumDetail>(`/api/albums/${id}`),
  renameAlbum: (id: string, name: string) =>
    request<Album>(`/api/albums/${id}`, { method: "PATCH", body: JSON.stringify({ name }) }),
  deleteAlbum: (id: string) => request<void>(`/api/albums/${id}`, { method: "DELETE" }),
  addToAlbum: (id: string, asset_ids: string[]) =>
    request<void>(`/api/albums/${id}/assets`, { method: "PUT", body: JSON.stringify({ asset_ids }) }),
  removeFromAlbum: (id: string, asset_ids: string[]) =>
    request<void>(`/api/albums/${id}/assets`, {
      method: "DELETE",
      body: JSON.stringify({ asset_ids }),
    }),

  // redundancy backup (admin)
  backup: () => request<BackupState>("/api/backup"),
  backupSettings: (dir: string | null, auto: boolean, include_thumbs: boolean) =>
    request<BackupState>("/api/backup/settings", {
      method: "PUT",
      body: JSON.stringify({ dir, auto, include_thumbs }),
    }),
  backupRun: () => request<{ started: boolean }>("/api/backup/run", { method: "POST" }),
  backupImport: (file: File, replace: boolean) => {
    const form = new FormData();
    form.append("file", file);
    return request<{ imported: Record<string, number>; replace: boolean }>(
      `/api/backup/import?replace=${replace}`,
      { method: "POST", body: form }
    );
  },

  // admin
  serverInfo: () =>
    request<{
      hostname: string;
      platform: string;
      lan_url: string;
      storage_root: string;
      database: string;
      mdns: { state: string; error?: string; instance?: string };
      assets: number;
      bytes: number;
      thumbs_pending: number;
      ocr_pending: number;
      users: number;
    }>("/api/admin/server"),
  users: () => request<User[]>("/api/admin/users"),
  createUser: (email: string, password: string, display_name: string, is_admin: boolean) =>
    request<User>("/api/admin/users", {
      method: "POST",
      body: JSON.stringify({ email, password, display_name, is_admin }),
    }),
  patchUser: (id: string, patch: { is_active?: boolean; is_admin?: boolean; password?: string }) =>
    request<User>(`/api/admin/users/${id}`, { method: "PATCH", body: JSON.stringify(patch) }),
};

export const thumbUrl = (id: string) => `/api/assets/${id}/thumbnail`;
export const previewUrl = (id: string) => `/api/assets/${id}/preview`;
export const originalUrl = (id: string) => `/api/assets/${id}/original`;
export const downloadUrl = (id: string) => `/api/assets/${id}/original?download=1`;
export const liveVideoUrl = (id: string) => `/api/assets/${id}/live-video`;
