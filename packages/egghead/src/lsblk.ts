// Reads visible whole-disk block devices via `lsblk`. Best-effort —
// if lsblk is missing or fails (running on a non-Linux dev box, etc.),
// returns an empty list and the disk-picker step degrades to a plain
// text input.
import { execFileSync } from "node:child_process";

export interface DiskCandidate {
  path: string;
  size: string;
  model: string;
}

export function listDisks(): DiskCandidate[] {
  try {
    const out = execFileSync(
      "lsblk",
      ["-d", "-n", "-o", "NAME,SIZE,MODEL,TYPE"],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
    );
    return out
      .split("\n")
      .map((line) => line.trim())
      .filter(Boolean)
      .map((line) => {
        // NAME SIZE MODEL... TYPE — collapse runs of whitespace; the
        // last field is TYPE, first is NAME, second is SIZE, the rest
        // (joined back together) is MODEL.
        const parts = line.split(/\s+/);
        const type = parts.pop() ?? "";
        const name = parts.shift() ?? "";
        const size = parts.shift() ?? "";
        const model = parts.join(" ") || "(no model)";
        return { name, size, model, type };
      })
      .filter((d) => d.type === "disk")
      .map(({ name, size, model }) => ({
        path: `/dev/${name}`,
        size,
        model,
      }));
  } catch {
    return [];
  }
}
