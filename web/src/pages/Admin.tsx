import { FormEvent, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { api, ApiError } from "../api";
import { useUser } from "../App";
import { useToast } from "../components/Toast";

export default function Admin() {
  const me = useUser();
  const qc = useQueryClient();
  const toast = useToast();
  const { data: users, isLoading } = useQuery({ queryKey: ["users"], queryFn: api.users });

  const [email, setEmail] = useState("");
  const [displayName, setDisplayName] = useState("");
  const [password, setPassword] = useState("");
  const [isAdmin, setIsAdmin] = useState(false);

  const invalidate = () => qc.invalidateQueries({ queryKey: ["users"] });

  const create = async (e: FormEvent) => {
    e.preventDefault();
    try {
      await api.createUser(email, password, displayName, isAdmin);
      setEmail("");
      setDisplayName("");
      setPassword("");
      setIsAdmin(false);
      toast("User created");
      invalidate();
    } catch (err) {
      toast(err instanceof ApiError ? err.message : "Failed to create user", true);
    }
  };

  const patch = async (id: string, p: { is_active?: boolean; is_admin?: boolean; password?: string }) => {
    try {
      await api.patchUser(id, p);
      invalidate();
    } catch (err) {
      toast(err instanceof ApiError ? err.message : "Update failed", true);
    }
  };

  const resetPassword = (id: string) => {
    const pw = window.prompt("New password (min 8 characters):");
    if (pw && pw.length >= 8) patch(id, { password: pw });
    else if (pw) toast("Password too short", true);
  };

  return (
    <div className="page">
      <h1>Users</h1>

      <form className="row" style={{ marginBottom: 20 }} onSubmit={create}>
        <input placeholder="Email" type="email" value={email} onChange={(e) => setEmail(e.target.value)} required />
        <input placeholder="Display name" value={displayName} onChange={(e) => setDisplayName(e.target.value)} required />
        <input placeholder="Password" type="password" value={password} minLength={8} onChange={(e) => setPassword(e.target.value)} required />
        <label className="row" style={{ gap: 4 }}>
          <input type="checkbox" checked={isAdmin} onChange={(e) => setIsAdmin(e.target.checked)} />
          Admin
        </label>
        <button className="primary" type="submit">Add user</button>
      </form>

      {isLoading && <p className="muted">Loading…</p>}
      {users && (
        <table className="admin">
          <thead>
            <tr>
              <th>Name</th>
              <th>Email</th>
              <th>Role</th>
              <th>Status</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            {users.map((u) => (
              <tr key={u.id}>
                <td>{u.display_name}{u.id === me.id && <span className="muted"> (you)</span>}</td>
                <td>{u.email}</td>
                <td>{u.is_admin ? "Admin" : "User"}</td>
                <td>{u.is_active ? "Active" : <span className="error">Disabled</span>}</td>
                <td className="row">
                  <button onClick={() => resetPassword(u.id)}>Reset password</button>
                  {u.id !== me.id && (
                    <>
                      <button onClick={() => patch(u.id, { is_admin: !u.is_admin })}>
                        {u.is_admin ? "Revoke admin" : "Make admin"}
                      </button>
                      <button
                        className={u.is_active ? "danger" : ""}
                        onClick={() => patch(u.id, { is_active: !u.is_active })}
                      >
                        {u.is_active ? "Deactivate" : "Reactivate"}
                      </button>
                    </>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}
