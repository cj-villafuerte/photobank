import { createContext, ReactNode, useCallback, useContext, useRef, useState } from "react";

interface Toast {
  id: number;
  message: string;
  isError: boolean;
}

const ToastContext = createContext<(message: string, isError?: boolean) => void>(() => {});
export const useToast = () => useContext(ToastContext);

export function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([]);
  const nextId = useRef(1);

  const push = useCallback((message: string, isError = false) => {
    const id = nextId.current++;
    setToasts((t) => [...t, { id, message, isError }]);
    setTimeout(() => setToasts((t) => t.filter((x) => x.id !== id)), 4000);
  }, []);

  return (
    <ToastContext.Provider value={push}>
      {children}
      <div className="toast-area">
        {toasts.map((t) => (
          <div key={t.id} className={`toast${t.isError ? " err" : ""}`}>
            {t.message}
          </div>
        ))}
      </div>
    </ToastContext.Provider>
  );
}
