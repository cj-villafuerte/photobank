import { FormEvent, useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { api, ApiError } from "../api";
import { useUser } from "../App";
import { fmtBytes } from "../components/PhotoGrid";
import { useToast } from "../components/Toast";

/** Admin-only: mirror the media library to a folder of the user's choosing. */
export function RedundancyBackup() {
  const toast = useToast();
  const qc = useQueryClient();
  const { data } = useQuery({
    queryKey: ["backup"],
    queryFn: api.backup,
    refetchInterval: (q) => (q.state.data?.status.running ? 1500 : 15000),
  });
  const [dir, setDir] = useState("");
  const [auto, setAuto] = useState(false);
  const [thumbs, setThumbs] = useState(false);
  const [saving, setSaving] = useState(false);
  const canBrowse = typeof window !== "undefined" && !!window.pywebview?.api?.pick_folder;

  useEffect(() => {
    if (data) {
      setDir(data.config.dir ?? "");
      setAuto(data.config.auto);
      setThumbs(data.config.include_thumbs);
    }
  }, [data]);

  const browse = async () => {
    const picked = await window.pywebview!.api!.pick_folder!();
    if (picked) setDir(picked);
  };

  const save = async () => {
    setSaving(true);
    try {
      await api.backupSettings(dir.trim() || null, auto, thumbs);
      toast("Backup settings saved");
      qc.invalidateQueries({ queryKey: ["backup"] });
    } catch (e) {
      toast(e instanceof ApiError ? e.message : "Could not save", true);
    } finally {
      setSaving(false);
    }
  };

  const runNow = async () => {
    try {
      await api.backupRun();
      toast("Backup started");
      qc.invalidateQueries({ queryKey: ["backup"] });
    } catch (e) {
      toast(e instanceof ApiError ? e.message : "Could not start backup", true);
    }
  };

  const status = data?.status;
  const progress = data?.progress;
  const result = status?.last_result;

  return (
    <>
      <h2 className="settings-heading">Redundancy backup</h2>
      <div className="settings-card" style={{ display: "flex", flexDirection: "column", gap: 10 }}>
        <p className="muted" style={{ fontSize: "0.85rem" }}>
          Mirrors your originals (and a database snapshot) to a folder you choose — an external
          drive, NAS, or second disk. Only new or changed files are copied; nothing is ever deleted
          at the destination.
        </p>
        <div className="row">
          <input
            style={{ flex: 1, minWidth: 260 }}
            placeholder={canBrowse ? "Choose a folder…" : "D:\\PhotobankBackup"}
            value={dir}
            onChange={(e) => setDir(e.target.value)}
          />
          {canBrowse && <button onClick={browse}>Browse…</button>}
        </div>
        <label className="row" style={{ gap: 8 }}>
          <input type="checkbox" checked={auto} onChange={(e) => setAuto(e.target.checked)} />
          Back up automatically every day
        </label>
        <label className="row" style={{ gap: 8 }}>
          <input type="checkbox" checked={thumbs} onChange={(e) => setThumbs(e.target.checked)} />
          Include thumbnails (regenerable; skip to save space)
        </label>
        <div className="row">
          <button className="primary" onClick={save} disabled={saving}>
            Save
          </button>
          <button onClick={runNow} disabled={!data?.config.dir || status?.running}>
            {status?.running ? "Backing up…" : "Back up now"}
          </button>
        </div>
        {status?.running && progress && (
          <div className="muted" style={{ fontSize: "0.85rem" }}>
            {progress.phase} · {progress.scanned ?? 0} scanned · {progress.copied ?? 0} copied (
            {fmtBytes(progress.bytes ?? 0)}){progress.errors ? ` · ${progress.errors} errors` : ""}
          </div>
        )}
        {!status?.running && status?.last_run && (
          <div className="muted" style={{ fontSize: "0.85rem" }}>
            Last run {new Date(status.last_run).toLocaleString()}:{" "}
            {result?.error
              ? `failed — ${result.error}`
              : `${result?.copied ?? 0} files copied (${fmtBytes(result?.bytes ?? 0)}), ${
                  result?.scanned ?? 0
                } checked${result?.errors ? `, ${result.errors} errors` : ""}. ${result?.database ?? ""}`}
          </div>
        )}
      </div>

      <h2 className="settings-heading">Move to another computer</h2>
      <div className="settings-card" style={{ display: "flex", flexDirection: "column", gap: 10 }}>
        <p className="muted" style={{ fontSize: "0.85rem" }}>
          Every backup run writes <code>photobank-export.json</code> — accounts, all photo
          metadata, albums, favorites, hidden state, and the text index — in a portable format.
          On a new computer: copy the backup folder's <code>library</code> into the new photo
          storage, install Photobank, then import that file here. You can also export on demand.
        </p>
        <div className="row">
          <a href="/api/backup/export" download>
            <button>⬇ Export library data (JSON)</button>
          </a>
        </div>
        <ImportBox />
      </div>
    </>
  );
}

function ImportBox() {
  const toast = useToast();
  const qc = useQueryClient();
  const [file, setFile] = useState<File | null>(null);
  const [replace, setReplace] = useState(false);
  const [busy, setBusy] = useState(false);

  const run = async () => {
    if (!file) return;
    const warning = replace
      ? "REPLACE wipes every user, photo record, album and setting on this server and restores the file's contents exactly. Continue?"
      : "MERGE adds records from the file that don't exist here yet (existing ones are kept). Continue?";
    if (!window.confirm(warning)) return;
    setBusy(true);
    try {
      const r = await api.backupImport(file, replace);
      const parts = Object.entries(r.imported).map(([t, n]) => `${t}: ${n}`);
      toast(`Imported — ${parts.join(", ")}`);
      qc.invalidateQueries();
      setFile(null);
    } catch (e) {
      toast(e instanceof ApiError ? e.message : "Import failed", true);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="row" style={{ alignItems: "center" }}>
      <input
        type="file"
        accept="application/json,.json"
        onChange={(e) => setFile(e.target.files?.[0] ?? null)}
      />
      <label className="row" style={{ gap: 6 }}>
        <input type="checkbox" checked={replace} onChange={(e) => setReplace(e.target.checked)} />
        Replace everything (otherwise merge)
      </label>
      <button className={replace ? "danger" : undefined} onClick={run} disabled={!file || busy}>
        {busy ? "Importing…" : "⬆ Import"}
      </button>
    </div>
  );
}

export default function Settings() {
  const user = useUser();
  const toast = useToast();
  const [current, setCurrent] = useState("");
  const [next, setNext] = useState("");
  const [confirm, setConfirm] = useState("");
  const [busy, setBusy] = useState(false);

  const changePassword = async (e: FormEvent) => {
    e.preventDefault();
    if (next !== confirm) {
      toast("New passwords do not match", true);
      return;
    }
    setBusy(true);
    try {
      await api.changePassword(current, next);
      setCurrent("");
      setNext("");
      setConfirm("");
      toast("Password changed");
    } catch (err) {
      toast(err instanceof ApiError ? err.message : "Could not change password", true);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="page" style={{ maxWidth: 640 }}>
      <h1>Settings</h1>

      <h2 className="settings-heading">Profile</h2>
      <div className="settings-card">
        <div className="settings-row">
          <span className="muted">Name</span>
          <span>{user.display_name}</span>
        </div>
        <div className="settings-row">
          <span className="muted">Email</span>
          <span>{user.email}</span>
        </div>
        <div className="settings-row">
          <span className="muted">Role</span>
          <span>{user.is_admin ? "Admin" : "User"}</span>
        </div>
        <div className="settings-row">
          <span className="muted">Member since</span>
          <span>{new Date(user.created_at).toLocaleDateString()}</span>
        </div>
      </div>

      <h2 className="settings-heading">Change password</h2>
      <form className="settings-card" onSubmit={changePassword} style={{ gap: 10, display: "flex", flexDirection: "column" }}>
        <input
          type="password"
          placeholder="Current password"
          value={current}
          onChange={(e) => setCurrent(e.target.value)}
          required
        />
        <input
          type="password"
          placeholder="New password (min 8 characters)"
          value={next}
          minLength={8}
          onChange={(e) => setNext(e.target.value)}
          required
        />
        <input
          type="password"
          placeholder="Repeat new password"
          value={confirm}
          onChange={(e) => setConfirm(e.target.value)}
          required
        />
        <button className="primary" type="submit" disabled={busy}>
          {busy ? "…" : "Change password"}
        </button>
      </form>

      {user.is_admin && <RedundancyBackup />}

      <h2 className="settings-heading">Storage</h2>
      <Link to="/duplicates">
        <button style={{ width: "100%" }}>🧹 Find duplicate photos</button>
      </Link>

      <div style={{ height: 48 }} />
      <hr style={{ border: "none", borderTop: "1px solid var(--border)" }} />
      <div style={{ height: 16 }} />
      <Link to="/settings/hidden">
        <button style={{ width: "100%" }}>🙈 Hidden photos</button>
      </Link>
      <p className="muted" style={{ fontSize: "0.85rem", marginTop: 8 }}>
        Hidden items don't appear in the timeline, albums, or search — only here.
      </p>
    </div>
  );
}
