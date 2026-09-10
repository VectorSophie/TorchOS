# TorchOS v2 — Desktop Polish (Group A) — Design

Status: **approved by user 2026-08-26**, pending written self-review below.
Author: Claude (Sonnet 5), in conversation with the project owner.
Parent doc: `docs/superpowers/specs/2026-08-24-torchos-v2-architecture-design.md` (locked architecture,
not re-litigated here). Sources verified directly against upstream, not assumed — see citations inline.

## 1. Scope

Group A = desktop polish on top of the already-provisioned Phase 1 Hyprland baseline: an application
bundle, a first-login status dashboard (`torch-welcome`), palette/theming, chezmoi-managed dotfiles, and
a handful of QoL keybinds. **Group B (Calamares/installer partitioning) is explicitly out of scope**,
deferred per the owner's own sequencing choice (needs its own fresh `brainstorming` pass later).

**Also explicitly out of scope for Group A**: forking in Omarchy's Quickshell-based shell (replacing
waybar/wofi/mako with one IPC'd process). Phase 1 already has a working waybar+wofi baseline; Group A
extends it, it doesn't replace it. This matters below — several QoL patterns below are the wofi-native
*equivalent* of what real Omarchy does with its walker-based shell, not a literal copy of Omarchy's own
binds (see §5).

## 2. App bundle (`install-apps.sh`)

**Source of truth**: Omarchy's actual `install/omarchy-base.packages` and `install/omarchy-other.packages`
manifests, pulled directly from `github.com/basecamp/omarchy` at tag `v3.8.4` (the last pre-Quickshell
release — matches TorchOS's current waybar-based architecture, not the v4.0 Quickshell rewrite).

**`omarchy-other.packages` is mostly not applicable and is not copied wholesale.** It's Omarchy's
from-scratch-Arch-install scaffolding (`base`, `base-devel`, `linux`, `linux-headers`, `linux-firmware`,
`limine`, `limine-mkinitcpio-hook`, `limine-snapper-sync`) plus a long tail of hardware-specific drivers
(Nvidia, Broadcom Wi-Fi, ASUS, Dell XPS, T2 Mac, Surface, a specific Realtek ethernet chip). TorchOS
already has a base system, kernel, and bootloader from Phase 1 — and specifically uses **GRUB, not
Limine** (Limine's `bios-install` doesn't work against this VM's virtio-blk, see the `bootloader`
Gotcha in `CLAUDE.md`). Installing Omarchy's `limine*`/`linux`/`base` packages here would be actively
wrong, not just redundant. The only line pulled from this file is **`zram-generator`** (explicitly
wanted, per the tight-RAM VM).

**From `omarchy-base.packages`, excluded:**
- Omarchy-branded, need Omarchy's own repo: `aether`, `cliamp`, `tobi-try`, `omarchy-nvim`,
  `omarchy-walker` (the last one because Group A stays on wofi, §1).
- Already installed and verified working in Phase 1 (not swapped for Omarchy's picks — Phase 1's
  `hyprpaper`+`kitty`+`wofi` are proven via real `grim` captures, not being re-litigated here):
  `hyprland`, `hypridle`, `hyprlock`, `hyprpaper` (Omarchy uses `swaybg` instead — not adopted),
  `waybar`, `xdg-desktop-portal-hyprland`, `polkit-gnome`, and the `pipewire`/`wireplumber` stack.

**Real gap found, not in either list as "missing" but genuinely needed**: Phase 1 never installed a
notification daemon. Nothing in the Phase 1 checklist provides one, and without it `notify-send`/mako-
dependent tooling (including `makoctl` used by nothing here yet, but standard for any future Omarchy-
pattern work) has nowhere to render. **Adding `mako`** — it's what Omarchy itself uses pre-Quickshell.

**Final `install-apps.sh` package set** (grouped for readability; installed via `pacman -S --needed`
where in official repos, `yay -S` for AUR — `yay` itself is in this same list, bootstrapped first):

| Group | Packages |
|---|---|
| Shell/CLI quality-of-life | `bash-completion`, `bat`, `btop`, `dust`, `eza`, `fastfetch`, `fd`, `fzf`, `jq`, `less`, `man-db`, `plocate`, `ripgrep`, `starship`, `tldr`, `tmux`, `tree-sitter-cli`, `usage`, `zoxide`, `gum`, `expac`, `inxi` |
| Notifications / OSD / input | `mako`, `swayosd`, `fcitx5`, `fcitx5-gtk`, `fcitx5-qt`, `brightnessctl`, `playerctl`, `pamixer`, `wiremix` |
| Screenshot / capture / clipboard | `grim`, `slurp`, `satty`, `hyprpicker`, `wl-clipboard`, `cliphist` *(not in Omarchy's list — needed for the wofi-native clipboard pattern, §5)*, `imv`, `ffmpegthumbnailer` |
| File management | `nautilus`, `nautilus-python`, `sushi`, `gnome-disk-utility`, `gvfs-mtp`, `gvfs-nfs`, `gvfs-smb`, `dosfstools`, `exfatprogs` |
| Terminal apps | `lazydocker`, `lazygit`, `neovim`, `mise` |
| Productivity / office | `libreoffice-fresh`, `libqalculate`, `gnome-calculator`, `obsidian`, `evince` |
| Creative / media | `imagemagick`, `pinta`, `mpv`, `obs-studio`, `gpu-screen-recorder` |
| Printing | `cups`, `cups-browsed`, `cups-filters`, `cups-pdf`, `system-config-printer` |
| Fonts / theming | `noto-fonts`, `noto-fonts-cjk`, `noto-fonts-emoji`, `ttf-jetbrains-mono-nerd`, `woff2-font-awesome`, `gnome-themes-extra`, `yaru-icon-theme`, `kvantum-qt5`, `qt5-wayland` |
| System / power | `power-profiles-daemon`, `zram-generator`, `avahi`, `nss-mdns`, `bluetui`, `bolt`, `iwd`, `wireless-regdb`, `plymouth` |
| Dev tooling | `github-cli`, `rust`, `docker`, `docker-compose`, `docker-buildx` |
| Windows compatibility | **`bottles`** — not in Omarchy's list at all; explicit ask, per the compatibility ladder's Wine tier (§6 of the locked architecture spec) |
| AUR bootstrap | `yay` |

Explicitly **not** carried over, and not re-raised here since it's outside Group A's remit: proprietary
picks that are genuinely optional/personal taste rather than desktop-functionality (`1password-beta`,
`1password-cli`, `signal-desktop`, `spotify`, `chromium`, `typora`, `localsend`) — Omarchy bundles these
as opinionated defaults; TorchOS's `torch install` resolver (Phase 4) is the intended path for a user to
add these themselves once it exists, not a hardcoded base-bundle decision made now. `claude-code` is
also left out of this bundle specifically — it's Phase 3's concern (Agent SDK daemon), not Group A's.

**Idempotency**: `install-apps.sh` is a flat `pacman -S --needed <list>` plus one `yay -S --needed
<aur-list>` call — `--needed` already makes re-runs no-ops for installed packages, no custom
already-installed tracking logic needed.

**Trust-boundary**: `snapper create -d "before Group A app bundle install" -u important=yes` before
running, per `CLAUDE.md`'s mutating-action rule.

## 3. `torch-welcome` — status dashboard

**Rust + GTK4** (`gtk4-rs`), a new crate in the existing `torch/` Cargo workspace (`torch/torch-welcome/`
or a workspace member — implementation plan decides the exact crate layout). Rationale: reuses the
project's one existing toolchain (the `torch` CLI is already Rust); GTK4 is the actively-developed line
for new Rust/GTK work in 2026, versus **cachyos-hello's actual stack, which is Rust + GTK3** (verified
directly: `github.com/CachyOS/CachyOS-Welcome`, `meson.build` declares `gtk+-3.0 >= 3.24.33`) — that
project predates GTK4's maturity, so it's not being copied verbatim, just its architecture pattern:

- Launches via a plain `.desktop` autostart entry (`Exec=torch-welcome`), **no systemd unit** — matches
  cachyos-hello exactly.
- Shells out to `torch diagnose` (already built, Phase 1, structured JSON) for all displayed data —
  kernel, hostname, root fstype, GPU, failed systemd units, available memory. No independent diagnostic
  logic in the GUI; it's a renderer, matching the "CLI is the source of truth, GUI wraps it" principle
  carried over from v1 (§11 of the locked architecture spec).
- Read-only — no buttons that change system state (that's `torchd`'s job once it exists, Phase 2+).
- Shows on every login by default; a "don't show again" checkbox writes
  `~/.config/torch/welcome-dismissed`, checked at startup before rendering.
- Styled via a GTK4 CSS provider using the locked palette (`#ff4500`/`#ff6a00`/`#2b0a00`, light
  background) — same hexes as the wallpaper/branding work, not a separate theme decision.

## 4. Palette / theming

Already locked (2026-08-26 branding session): light UI, orange accent, hexes `#ff4500`/`#ff6a00`/
`#2b0a00`, replacing stock Hyprland's dark-blue defaults. Applies to: waybar CSS, wofi CSS, wlogout CSS,
GTK3/GTK4 theme (via `gnome-themes-extra`/custom CSS override — exact mechanism is an implementation-plan
detail, not a design decision), and `torch-welcome` (§3). Not re-litigated here.

## 5. Dotfiles: chezmoi

New `dotfiles/` directory in this repo as chezmoi's source dir. `chezmoi diff` is a **mandatory preview**
before every `chezmoi apply` — no exceptions, per the locked spec (§5). This closes the exact gap the
Phase 1 Gotchas record: the hand-typed-over-SSH `hyprland.conf`/`hypridle.conf` fix is real on the VM
disk but not reproducible from the repo. Managed files for Group A: `hypr/hyprland.conf` (including the
already-verified `exec-once` lines for hyprpaper/waybar/hypridle, plus new ones for `mako` and
`swayosd-server`), `hypr/hypridle.conf`, `hypr/bindings.conf` (or an included fragment, §6), waybar
config/CSS, wofi config/CSS, wlogout config/CSS.

## 6. QoL keybinds

Translated from real Omarchy source (`github.com/basecamp/omarchy` tag `v3.8.4`, files
`default/hypr/bindings/{media,clipboard,utilities}.conf`, fetched and grepped directly) to TorchOS's
actual stack — wofi, not walker; standalone tools, not the `omarchy-menu` wrapper suite, which is out of
scope for Group A.

| Bind | Action | Note |
|---|---|---|
| `, Print` | full-screen → `~/Pictures/Screenshots/<timestamp>.png` | |
| `SUPER SHIFT, S` | region select → clipboard (`grim -g "$(slurp)" - \| wl-copy`) | |
| `SUPER, V` | clipboard history (`cliphist list \| wofi --dmenu \| cliphist decode \| wl-copy`) | Real Omarchy binds `SUPER CTRL, V` because plain `SUPER, V` is taken by their "universal paste" sendshortcut, which TorchOS doesn't have — `SUPER, V` is free and is the more common Hyprland-community convention |
| `SUPER, ESCAPE` | power menu (`wlogout`) | Same key real Omarchy uses for its system menu; `wlogout` substitutes for their `omarchy-menu system` wrapper, which isn't being built here |
| `XF86Audio{Raise,Lower}Volume`, `XF86AudioMute` | `swayosd-client --output-volume {raise,lower,mute-toggle}` | Matches real Omarchy exactly, minus their `omarchy-swayosd-client` wrapper script layer |
| `XF86MonBrightness{Up,Down}` | `swayosd-client --brightness {raise,lower}` | Same |

`swayosd-server` needs an `exec-once` line alongside the existing hyprpaper/waybar/hypridle ones (§5).

## 7. Verification plan

Real, non-LLM checks, per the locked spec's verification discipline (§8 — the agent proposing a change
is never the sole judge it's correct):

- **`install-apps.sh`**: snapshot first (§2). Run once → `pacman -Q <pkg>` for at least one package per
  group in §2's table (not just the script's exit code). Run again → confirm idempotent (no errors, no
  new changes). Reboot the VM → `grim`-confirm the desktop still boots and renders.
- **chezmoi**: `chezmoi diff` output captured and reviewed before every `apply`. After apply, don't trust
  `hyprctl reload` for new `exec-once` lines — restart the Hyprland session (or `hyprctl dispatch exec`
  each new program manually) and `pgrep` each of `mako`/`swayosd-server` to confirm they're actually
  running, not just that the config file changed.
- **`torch-welcome`**: `cargo build --release` succeeds. Runs standalone in the VM
  (`hyprctl dispatch exec torch-welcome`). `grim` screenshot cross-checked against a `torch diagnose` run
  in a terminal at the same moment — catches stale/mocked data, not just "a window appeared."
- **Keybinds**: each bind in §6 exercised individually via the QEMU monitor's `sendkey`, before/after
  `grim` screenshots diffed to confirm the actual effect (a screenshot file lands in
  `~/Pictures/Screenshots/`, the wofi clipboard menu appears, `wlogout`'s menu appears, swayosd's OSD bar
  appears on a volume key).
- **Palette**: `grim` screenshot, accent-colored pixels sampled programmatically (not eyeballed) and
  diffed against the locked hex values.

## 8. Risks / open items

- The exact GTK4-CSS-vs-GTK3-theme-override mechanism for a consistent look across waybar/wofi/wlogout/
  torch-welcome/native GTK apps isn't nailed down — real implementation detail, left to the implementation
  plan, not a design gap (all four locked hex values are fixed; only the CSS plumbing to reach every
  surface is undecided).
- `torch-welcome`'s exact crate layout inside the `torch/` Cargo workspace (separate crate vs. new binary
  target) is left to the implementation plan.
- `install-apps.sh`'s AUR tier uses `yay` directly (matching Omarchy's own choice) rather than routing
  through the not-yet-built `torch install` gated-AUR resolver (Phase 4) — acceptable since Group A predates
  Phase 4, but worth a code comment noting this is a temporary direct path, not the final compatibility
  model.

## Self-review (brainstorming skill checklist)

- **Placeholder scan**: no TBD/TODO markers. The two "left to the implementation plan" items in §8 are
  genuine implementation-level decisions (crate layout, CSS plumbing mechanism), not unresolved design
  questions — the design constrains their outcome (workspace member; must reach all 5 listed surfaces)
  without over-specifying mechanism.
- **Internal consistency**: §2's package exclusions and §1's "wofi, not walker" scope statement agree;
  §6's keybind choices explicitly reconcile with §1's scope boundary rather than silently copying Omarchy.
  §5 and §6 agree on which `exec-once` lines are needed (mako, swayosd-server).
- **Scope check**: Group B and the Quickshell/walker fork are explicitly out (§1), matching the owner's
  prior sequencing decision. Package selections in §2 explicitly stop at "install it," not "configure
  Docker groups" or other post-install setup — that's implementation-plan-level detail.
- **Ambiguity check**: the app-bundle table in §2 states real package names, not category descriptions,
  removing any "which packages exactly" ambiguity for the implementation plan.

## Next steps

1. Owner reviews this file.
2. Invoke `writing-plans` for a Group A implementation plan.
3. Execute it (with the trust-boundary/verification rules above enforced, not just stated).
