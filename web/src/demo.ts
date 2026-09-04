import { useQuery } from "@tanstack/react-query";
import { api, DemoInfo } from "./api";

/** Non-null when this server is the public demo (shared account, read-only sample
 *  library, uploads removed after a few seconds). Fetched once from /api/health. */
export function useDemo(): DemoInfo | null {
  const { data } = useQuery({
    queryKey: ["health"],
    queryFn: api.health,
    staleTime: Infinity,
    retry: 1,
  });
  return data?.demo ?? null;
}
