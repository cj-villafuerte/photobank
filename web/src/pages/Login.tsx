import { FormEvent, useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { useQueryClient } from "@tanstack/react-query";
import { api, ApiError } from "../api";
import { LOGIN_AS_MEMBER, isDesktop, localAdminLogin, refreshSession } from "../App";
import { useDemo } from "../demo";

export default function Login() {
  const [mode, setMode] = useState<"login" | "register">("login");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [displayName, setDisplayName] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const qc = useQueryClient();
  const navigate = useNavigate();
  const demo = useDemo();
  // desktop "View as member…": a member signs in here and sees their library in this window
  const asMember = isDesktop() && sessionStorage.getItem(LOGIN_AS_MEMBER) === "1";

  const openConsole = async () => {
    sessionStorage.removeItem(LOGIN_AS_MEMBER);
    if (await localAdminLogin()) {
      await refreshSession(qc);
      navigate("/console");
    }
  };

  // public demo: the shared account is the only account, so fill it in
  useEffect(() => {
    if (demo) {
      setEmail(demo.email);
      setPassword(demo.password);
      setMode("login");
    }
  }, [demo]);

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setError(null);
    setBusy(true);
    try {
      if (mode === "login") await api.login(email, password);
      else await api.register(email, password, displayName);
      sessionStorage.removeItem(LOGIN_AS_MEMBER);
      // no navigate(): once `me` is refreshed the signed-in routes take over and
      // their catch-all sends us home (library, or the Console for a desktop admin)
      await refreshSession(qc);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Something went wrong");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="auth-wrap">
      <form className="auth-card" onSubmit={submit}>
        <h1>Photobank</h1>
        <div className="mono" style={{ color: "var(--faint)", fontSize: 10, textAlign: "center", marginTop: -4 }}>
          by CJ Villafuerte
        </div>
        {demo && (
          <p className="muted" style={{ fontSize: "0.85rem", textAlign: "center", margin: "4px 0 8px" }}>
            Public demo server — the shared account is filled in. The sample library is
            read-only; anything you upload is removed after {demo.upload_ttl_seconds} seconds.
          </p>
        )}
        {asMember && (
          <p className="muted" style={{ fontSize: "0.85rem", textAlign: "center", margin: "4px 0 8px" }}>
            Sign in with a member's email and password to see their library here, exactly as
            they see it on their phone or in a browser.
          </p>
        )}
        {isDesktop() && !asMember && (
          <>
            <p className="muted" style={{ fontSize: "0.85rem", textAlign: "center", margin: "4px 0 8px" }}>
              Sign in as a member to view that person's photos. The administrator needs no
              password — this computer is the administrator.
            </p>
            <button type="button" className="primary" onClick={openConsole}>
              Open the administrator console
            </button>
          </>
        )}
        {mode === "register" && (
          <input
            placeholder="Display name"
            value={displayName}
            onChange={(e) => setDisplayName(e.target.value)}
            required
          />
        )}
        <input
          type="email"
          placeholder="Email"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          required
        />
        <input
          type="password"
          placeholder={mode === "register" ? "Password (min 8 chars)" : "Password"}
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          minLength={mode === "register" ? 8 : undefined}
          required
        />
        {error && <div className="error">{error}</div>}
        <button className="primary" type="submit" disabled={busy}>
          {busy ? "…" : mode === "login" ? "Log in" : "Create account"}
        </button>
        {asMember ? (
          <button type="button" onClick={openConsole}>
            Back to the administrator console
          </button>
        ) : (
          !demo && (
            <button
              type="button"
              onClick={() => {
                setMode(mode === "login" ? "register" : "login");
                setError(null);
              }}
            >
              {mode === "login" ? "Need an account? Register" : "Have an account? Log in"}
            </button>
          )
        )}
      </form>
    </div>
  );
}
