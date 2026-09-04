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

/** sessionStorage flag: the desktop administrator chose "View as member…", so the
 *  next login screen is a member sign-in (kept out of the URL - redirects would drop it). */
export const LOGIN_AS_MEMBER = "pb_login_as_member";

/** sessionStorage flag: a member signed in with a password inside the desktop window.
 *  While set, the app shows exactly what that member sees in a browser - no Console,
 *  no administrator controls - even when the account itself has the admin role
 *  (the first account registered on a server always does). */
export const MEMBER_VIEW = "pb_member_view";
export const isMemberView = () => isDesktop() && sessionStorage.getItem(MEMBER_VIEW) === "1";
/** The administrator's controls belong to an admin account outside the member view. */
export const isAdminHere = (user: User) => user.is_admin && !isMemberView();

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
  const admin = isAdminHere(user);
  // No navigate() here: `me` updates on a later tick than the awaited refresh, and
  // the router's catch-all redirects against whoever it currently thinks we are.
  // Once `me` is 401 the logged-out routes take over and land on /login themselves.
  const logout = async () => {
    await api.logout();
    await refreshSession(qc);
  };
  // desktop: the member's library shows in this same window, as they see it themselves
  const viewAsMember = () => {
    sessionStorage.setItem(LOGIN_AS_MEMBER, "1");
    return logout();
  };
  const openConsole = async () => {
    if (await localAdminLogin()) {
      await refreshSession(qc);
      navigate("/console"); // either order ends on the Console for a desktop admin
    }
  };
  // member view over: the administrator comes straight back, no login screen in between
  const signOutToAdmin = async () => {
    await api.logout();
    sessionStorage.removeItem(MEMBER_VIEW);
    if (await localAdminLogin()) {
      await refreshSession(qc);
      navigate("/console");
    } else {
      await refreshSession(qc);
    }
  };
  return (
    <nav className="nav">
      <span className="brand">Photobank<small>by CJ Villafuerte</small></span>
      {admin && (
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
      <NavLink to="/duplicates" className={({ isActive }) => `navlink${isActive ? " active" : ""}`}>
        Duplicates
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
      {isMemberView() ? (
        <button onClick={signOutToAdmin}>Sign out</button>
      ) : isDesktop() && user.is_admin ? (
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

  const admin = isAdminHere(user);
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
            element={admin && isDesktop() ? <Navigate to="/console" replace /> : <Timeline favorites={false} />}
          />
          <Route path="/library" element={<Timeline favorites={false} />} />
          {admin && <Route path="/console" element={<Console />} />}
          <Route path="/favorites" element={<Timeline favorites={true} />} />
          <Route path="/albums" element={<Albums />} />
          <Route path="/albums/:id" element={<AlbumDetail />} />
          <Route path="/trash" element={<Trash />} />
          <Route path="/search" element={<Search />} />
          <Route path="/stats" element={<Stats />} />
          <Route path="/duplicates" element={<Duplicates />} />
          <Route path="/settings" element={<Settings />} />
          <Route path="/settings/hidden" element={<Hidden />} />
          {admin && <Route path="/admin" element={<Navigate to="/console" replace />} />}
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </ToastProvider>
    </UserContext.Provider>
  );
}
