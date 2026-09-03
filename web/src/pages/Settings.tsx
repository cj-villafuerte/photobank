import { FormEvent, useState } from "react";
import { Link } from "react-router-dom";
import { api, ApiError } from "../api";
import { useUser } from "../App";
import { useToast } from "../components/Toast";

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
