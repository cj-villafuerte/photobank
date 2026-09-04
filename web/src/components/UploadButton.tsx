import { useRef, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { api } from "../api";
import { useDemo } from "../demo";
import { useToast } from "./Toast";

export default function UploadButton() {
  const inputRef = useRef<HTMLInputElement>(null);
  const [progress, setProgress] = useState<string | null>(null);
  const qc = useQueryClient();
  const toast = useToast();
  const demo = useDemo();

  const onFiles = async (files: FileList | null) => {
    if (!files || files.length === 0) return;
    const list = Array.from(files);
    let uploaded = 0;
    let duplicates = 0;
    let failed = 0;
    for (let i = 0; i < list.length; i++) {
      setProgress(`Uploading ${i + 1} / ${list.length}…`);
      try {
        const result = await api.upload(list[i]);
        if (result.duplicate) duplicates++;
        else uploaded++;
      } catch (e) {
        failed++;
        console.error("upload failed", list[i].name, e);
      }
    }
    setProgress(null);
    if (inputRef.current) inputRef.current.value = "";
    const parts = [`${uploaded} uploaded`];
    if (duplicates) parts.push(`${duplicates} duplicate${duplicates > 1 ? "s" : ""} skipped`);
    if (failed) parts.push(`${failed} failed`);
    if (demo && uploaded) parts.push(`gone again in ${demo.upload_ttl_seconds} s (demo)`);
    toast(parts.join(", "), failed > 0);
    const refresh = () => {
      qc.invalidateQueries({ queryKey: ["buckets"] });
      qc.invalidateQueries({ queryKey: ["bucket"] });
      qc.invalidateQueries({ queryKey: ["sizelist"] });
    };
    refresh();
    // demo server purges uploads shortly after; make them leave the grid too
    if (demo && uploaded) window.setTimeout(refresh, (demo.upload_ttl_seconds + 2) * 1000);
  };

  return (
    <>
      <input
        ref={inputRef}
        type="file"
        multiple
        accept={demo ? "image/*,.heic,.heif" : "image/*,video/*,.heic,.heif"}
        style={{ display: "none" }}
        onChange={(e) => onFiles(e.target.files)}
      />
      <button className="primary" disabled={progress !== null} onClick={() => inputRef.current?.click()}>
        {progress ?? "⬆ Upload"}
      </button>
    </>
  );
}
