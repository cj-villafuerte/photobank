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
}

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

export class ApiError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(path, {
    credentials: "include",
    headers: init?.body instanceof FormData ? undefined : { "Content-Type": "application/json" },
    ...init,
  });
  if (!res.ok) {
    let detail = res.statusText;
    try {
      const body = await res.json();
      if (body.detail) detail = typeof body.detail === "string" ? body.detail : JSON.stringify(body.detail);
    } catch {
      /* not json */
    }
    throw new ApiError(res.status, detail);
  }
  if (res.status === 204) return undefined as T;
  return res.json();
}

export const api = {
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

  // timeline
  buckets: (favorites = false) =>
    request<TimelineBucket[]>(`/api/timeline/buckets?favorites=${favorites}`),
  bucket: (bucket: string, favorites = false) =>
    request<AssetThin[]>(`/api/timeline/bucket/${bucket}?favorites=${favorites}`),

  // assets
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

  // admin
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
