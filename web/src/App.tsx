import { createContext, useContext, useEffect, useState } from "react";
import { Navigate, NavLink, Route, Routes, useNavigate } from "react-router-dom";
import { useQuery, useQueryClient } from "@tanstack/react-query";
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
import { ToastProvider } from "./components/Toast";

const UserContext = createContext<User | null>(null);
export const useUser = () => useContext(UserContext)!;

function NavBar({ user }: { user: User }) {
  const navigate = useNavigate();
  const qc = useQueryClient();
  const logout = async () => {
    await api.logout();
    qc.clear();
    navigate("/login");
  };
  return (
    <nav className="nav">
      <span className="brand">Photobank<small>by Neodata</small></span>
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
        <button onClick={() => { api.logout().then(() => { qc.clear(); navigate("/login"); }); }}>
          View as member…
        </button>
      ) : isDesktop() ? (
        <button onClick={async () => { if (await localAdminLogin()) { qc.clear(); navigate("/console"); } }}>
          Administrator console
        </button>
      ) : (
        <button onClick={logout}>Log out</button>
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
