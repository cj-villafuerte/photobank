import { createContext, useContext, useEffect, useState } from "react";
import { Navigate, NavLink, Route, Routes, useNavigate } from "react-router-dom";
import { QueryClient, useQuery, useQueryClient } from "@tanstack/react-query";
import { api, ApiError, User } from "./api";
import Login from "./pages/Login";
import Timeline from "./pages/Timeline";
import Albums from "./pages/Albums";
import AlbumDetail from "./pages/AlbumDetail";
import Trash from "./pages/Trash";
import Settings from "./pages/Settings";
import Hidden from "./pages/Hidden";
import Search from "./pages/Search";
import Stats from "./pages/Stats";
import Duplicates from "./pages/Duplicates";
import Console from "./pages/Console";

/** Running inside the desktop app's window (pywebview injects this). */
export const isDesktop = () => typeof window !== "undefined" && !!window.pywebview;

declare global {
  interface Window {
    pywebview?: {
      api?: {
        pick_folder?: () => Promise<string | null>;
        local_token?: () => Promise<string>;
        set_storage_root?: (path: string) => Promise<string>;
      };
    };
  }
}

/**
 * After the session cookie changed (login, logout, switching to the administrator):
 * drop every cached view and re-read who we are. Not `qc.clear()` - that empties the
 * cache but does not refetch queries that are still mounted, so `me` would keep
 * reporting the previous user and the login screen would never appear.
 */
export async function refreshSession(qc: QueryClient) {
  qc.removeQueries({ predicate: (q) => q.queryKey[0] !== "me" && q.queryKey[0] !== "health" });
  await qc.resetQueries({ queryKey: ["me"] });
}

/** Desktop window: become the passwordless local administrator (loopback + secret). */
export async function localAdminLogin(): Promise<boolean> {
  try {
    // pywebview injects its bridge shortly after load; wait briefly for it
    for (let i = 0; i < 20 && !window.pywebview?.api?.local_token; i++) {
      await new Promise((r) => setTimeout(r, 100));
    }
    const token = await window.pywebview?.api?.local_token?.();
    if (!token) return false;
    await api.localLogin(token);
    return true;
  } catch {
    return false;
  }
}
import { ToastProvider, useToast } from "./components/Toast";
import { useDemo } from "./demo";

const UserContext = createContext<User | null>(null);
export const useUser = () => useContext(UserContext)!;

/** Public demo server: say so, and say what the rules are. */
function DemoBanner() {
  const demo = useDemo();
  if (!demo) return null;
  return (
    <div className="demo-banner">
      <span className="mono">Demo server</span>
      <span>
        The sample library is read-only · your uploads (images up to {demo.max_upload_mb} MB,{" "}
        {demo.max_uploads} at a time) are removed after {demo.upload_ttl_seconds} s
      </span>
    </div>
  );
}

/** On the demo server, refusals (read-only library, limits) come back as 403/413/415/429
 *  from many places; one listener turns them into toasts instead of silent failures. */
function ApiErrorToaster() {
  const demo = useDemo();
  const toast = useToast();
  useEffect(() => {
    if (!demo) return;
    const onError = (e: Event) => {
      const d = (e as CustomEvent).detail as { status: number; message: string };
      if ([403, 413, 415, 429].includes(d.status)) toast(d.message, true);
    };
    window.addEventListener("pb:api-error", onError);
    return () => window.removeEventListener("pb:api-error", onError);
  }, [demo, toast]);
  return null;
}

function NavBar({ user }: { user: User }) {
  const navigate = useNavigate();
  const qc = useQueryClient();
  const logout = async (to = "/login") => {
    await api.logout();
    navigate(to);
    await refreshSession(qc); // me -> 401 -> the login screen renders
  };
  // desktop: the member's library shows in this same window, as they see it themselves
  const viewAsMember = () => logout("/login?as=member");
  const openConsole = async () => {
    if (await localAdminLogin()) {
      navigate("/console");
      await refreshSession(qc);
    }
  };
  return (
    <nav className="nav">
      <span className="brand">Photobank<small>by CJ Villafuerte</small></span>
      {user.is_admin && (
        <NavLink to="/console" className={({ isActive }) => `navlink${isActive ? " active" : ""}`}>
          Console
        </NavLink>
      )}
      <NavLink to="/library" className={({ isActive }) => `navlink${isActive ? " active" : ""}`}>
        Library
      </NavLink>
      <NavLink to="/favorites" className={({ isActive }) => `navlink${isActive ? " active" : ""}`}>
        Favorites
      </NavLink>
      <NavLink to="/albums" className={({ isActive }) => `navlink${isActive ? " active" : ""}`}>
        Albums
      </NavLink>
      <NavLink to="/search" className={({ isActive }) => `navlink${isActive ? " active" : ""}`}>
        Search
      </NavLink>
      <NavLink to="/stats" className={({ isActive }) => `navlink${isActive ? " active" : ""}`}>
        Dashboard
      </NavLink>
      <NavLink to="/trash" className={({ isActive }) => `navlink${isActive ? " active" : ""}`}>
        Trash
      </NavLink>
      <span className="spacer" />
      <NavLink to="/settings" className={({ isActive }) => `navlink${isActive ? " active" : ""}`}>
        {user.display_name}
      </NavLink>
      {isDesktop() && user.is_admin ? (
        <button onClick={viewAsMember}>View as member…</button>
      ) : isDesktop() ? (
        <button onClick={openConsole}>Administrator console</button>
      ) : (
        <button onClick={() => logout()}>Log out</button>
      )}
    </nav>
  );
}

export default function App() {
  const { data: user, isLoading, error } = useQuery({
    queryKey: ["me"],
    queryFn: api.me,
    retry: (count, err) => !(err instanceof ApiError && err.status === 401) && count < 2,
  });

  // desktop window with no session: sign in as the local administrator automatically
  const qcBoot = useQueryClient();
  const [autoTried, setAutoTried] = useState(false);
  // once anyone has been signed in, an empty session is a deliberate sign-out
  // ("View as member…", "Log out") - never auto-restore the administrator over it
  useEffect(() => {
    if (user) setAutoTried(true);
  }, [user]);
  useEffect(() => {
    if (!isLoading && !user && isDesktop() && !autoTried) {
      setAutoTried(true);
      localAdminLogin().then((ok) => {
        if (ok) qcBoot.invalidateQueries({ queryKey: ["me"] });
      });
    }
  }, [isLoading, user, autoTried, qcBoot]);

  if (isLoading || (!user && isDesktop() && !autoTried)) {
    return <div className="auth-wrap muted">Loading…</div>;
  }

  if (!user || (error instanceof ApiError && error.status === 401)) {
    return (
      <ToastProvider>
        <Routes>
          <Route path="/login" element={<Login />} />
          <Route path="*" element={<Navigate to="/login" replace />} />
        </Routes>
      </ToastProvider>
    );
  }

  return (
    <UserContext.Provider value={user}>
      <ToastProvider>
        <NavBar user={user} />
        <DemoBanner />
        <ApiErrorToaster />
        <Routes>
          {/* admins on the desktop app land on the Console; everyone else on the library */}
          <Route
            path="/"
            element={user.is_admin && isDesktop() ? <Navigate to="/console" replace /> : <Timeline favorites={false} />}
          />
          <Route path="/library" element={<Timeline favorites={false} />} />
          {user.is_admin && <Route path="/console" element={<Console />} />}
          <Route path="/favorites" element={<Timeline favorites={true} />} />
          <Route path="/albums" element={<Albums />} />
          <Route path="/albums/:id" element={<AlbumDetail />} />
          <Route path="/trash" element={<Trash />} />
          <Route path="/search" element={<Search />} />
          <Route path="/stats" element={<Stats />} />
          <Route path="/duplicates" element={<Duplicates />} />
          <Route path="/settings" element={<Settings />} />
          <Route path="/settings/hidden" element={<Hidden />} />
          {user.is_admin && <Route path="/admin" element={<Navigate to="/console" replace />} />}
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </ToastProvider>
    </UserContext.Provider>
  );
}
