use super::package::{pacman, wait_for_network};
use anyhow::{bail, Context, Result};
use serde::Deserialize;
use std::process::Command;

#[derive(Deserialize)]
struct KernelArgs {
    name: String,
}

/// Kernels torchd will install. Anything else is refused, not passed through.
pub const KERNELS: &[&str] = &["linux", "linux-lts", "linux-zen", "linux-hardened", "linux-cachyos"];

// CachyOS layer (docs/decisions/0001): only the generic [cachyos] repo, listed *after* the Arch repos.
// pacman takes a package from the first repo that has it, so Arch's pacman/glibc/mesa keep coming from
// Arch and only CachyOS-only packages (the kernel, its keyring) come from CachyOS. The x86-64-v3/v4
// rebuilt-world repos are deliberately not added: they replace the whole base.
const CACHYOS_KEY: &str = "F3B607488DB35A47";
const CACHYOS_REPO: &str = "\n# TorchOS: CachyOS kernel layer (added by `torch kernel add linux-cachyos`)\n[cachyos]\nServer = https://mirror.cachyos.org/repo/$arch/$repo\n";

fn run(cmd: &str, args: &[&str]) -> Result<()> {
    let s = Command::new(cmd).args(args).status().with_context(|| format!("running {cmd}"))?;
    if !s.success() {
        bail!("{cmd} {} failed", args.join(" "));
    }
    Ok(())
}

fn ensure_cachyos_repo() -> Result<()> {
    let conf = std::fs::read_to_string("/etc/pacman.conf")?;
    if conf.contains("\n[cachyos]") {
        return Ok(());
    }
    run("pacman-key", &["--recv-keys", CACHYOS_KEY, "--keyserver", "hkps://keyserver.ubuntu.com"])?;
    run("pacman-key", &["--lsign-key", CACHYOS_KEY])?;
    std::fs::write("/etc/pacman.conf", conf + CACHYOS_REPO)?;
    Ok(())
}

pub fn install(args: &serde_json::Value) -> Result<String> {
    let args: KernelArgs = serde_json::from_value(args.clone()).context("bad args for kernel.install")?;
    if !KERNELS.contains(&args.name.as_str()) {
        bail!("unknown kernel {:?}; choose one of {}", args.name, KERNELS.join(", "));
    }
    wait_for_network()?;
    // Checkpoint before touching pacman.conf; snap-pac only wraps the pacman transaction itself.
    let desc = format!("before kernel.install {}", args.name);
    run("snapper", &["-c", "root", "create", "-d", &desc, "-u", "important=yes"])?;
    let mut pkgs = vec![args.name.clone()];
    if args.name == "linux-cachyos" {
        ensure_cachyos_repo()?;
        pkgs.push("cachyos-keyring".into());
    }
    pacman(&["-Syu", "--needed"], &pkgs)?;
    // Arch does not regenerate grub.cfg when a new kernel appears; the default entry stays `linux`
    // (GRUB_TOP_LEVEL, set at install time), the new kernel is under Advanced options.
    run("grub-mkconfig", &["-o", "/boot/grub/grub.cfg"])?;
    Ok(format!("{} installed; pick it under GRUB's Advanced options on the next boot", args.name))
}
