// Role table. Mirrors the role_* assoc-arrays in scripts/egghead.sh
// (lines 229-260). We deliberately duplicate the table here rather
// than parse the bash file — the role catalog is small, stable, and
// human-curated; a parser would be more code than the data itself.
//
// Keep in sync: any new role added to scripts/egghead.sh must also
// land here. The bash script is still the source of truth at execution
// time — this table only drives the TUI's defaults so the user sees
// sensible pre-filled values per role.

export type RoleName =
  | "bare-metal-laptop"
  | "bare-metal-desktop"
  | "vm-headless"
  | "vm-desktop";

export interface Role {
  name: RoleName;
  layout: "bare-metal" | "vm";
  features: string;
  hm: "base" | "dev" | "desktop" | "kid";
  disk: string;
  unattended: "yes" | "no";
}

export const ROLES: Role[] = [
  {
    name: "bare-metal-laptop",
    layout: "bare-metal",
    features:
      "battery biometrics face-unlock bluetooth audio gpu power niri quickshell hardware-hacking file-manager login-ly kicad freecad firefox",
    hm: "desktop",
    disk: "/dev/nvme0n1",
    unattended: "no",
  },
  {
    name: "bare-metal-desktop",
    layout: "bare-metal",
    features:
      "bluetooth audio gpu power niri quickshell hardware-hacking file-manager login-ly kicad freecad firefox",
    hm: "desktop",
    disk: "/dev/sda",
    unattended: "no",
  },
  {
    name: "vm-headless",
    layout: "vm",
    features: "",
    hm: "dev",
    disk: "/dev/vda",
    unattended: "yes",
  },
  {
    name: "vm-desktop",
    layout: "vm",
    features: "audio gpu niri quickshell file-manager login-ly",
    hm: "desktop",
    disk: "/dev/vda",
    unattended: "no",
  },
];

export const roleByName = (name: string): Role | undefined =>
  ROLES.find((r) => r.name === name);
