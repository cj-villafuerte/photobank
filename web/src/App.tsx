import { createContext, useContext } from "react";
import { Navigate, NavLink, Route, Routes, useNavigate } from "react-router-dom";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { api, ApiError, User } from "./api";
import Login from "./pages/Login";
import Timeline from "./pages/Timeline";
import Albums from "./pages/Albums";
import AlbumDetail from "./pages/AlbumDetail";
import Trash from "./pages/Trash";
import Admin from "./pages/Admin";
import Settings from "./pages/Settings";
import Hidden from "./pages/Hidden";
import Search from "./pages/Search";
import Stats from "./pages/Stats";
import Duplicates from "./pages/Duplicates";
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
      <NavLink to="/" end className={({ isActive }) => `navlink${isActive ? " active" : ""}`}>
        Timeline
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
      {user.is_admin && (
        <NavLink to="/admin" className={({ isActive }) => `navlink${isActive ? " active" : ""}`}>
          Admin
        </NavLink>
      )}
      <span className="spacer" />
      <NavLink to="/settings" className={({ isActive }) => `navlink${isActive ? " active" : ""}`}>
        ⚙ {user.display_name}
      </NavLink>
      <button onClick={logout}>Log out</button>
    </nav>
  );
}

export default function App() {
  const { data: user, isLoading, error } = useQuery({
    queryKey: ["me"],
    queryFn: api.me,
    retry: (count, err) => !(err instanceof ApiError && err.status === 401) && count < 2,
  });

  if (isLoading) {
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
          <Route path="/" element={<Timeline favorites={false} />} />
          <Route path="/favorites" element={<Timeline favorites={true} />} />
          <Route path="/albums" element={<Albums />} />
          <Route path="/albums/:id" element={<AlbumDetail />} />
          <Route path="/trash" element={<Trash />} />
          <Route path="/search" element={<Search />} />
          <Route path="/stats" element={<Stats />} />
          <Route path="/duplicates" element={<Duplicates />} />
          <Route path="/settings" element={<Settings />} />
          <Route path="/settings/hidden" element={<Hidden />} />
          {user.is_admin && <Route path="/admin" element={<Admin />} />}
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </ToastProvider>
    </UserContext.Provider>
  );
}
