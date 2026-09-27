//! `torch install`: one verb for every way software reaches this system, in the locked order
//! pacman -> Flatpak -> gated AUR -> Distrobox -> AppImage -> Wine. Anything that needs root goes
//! through torchd; Flatpak (--user), AppImages and containers stay unprivileged.
use anyhow::{bail, Context, Result};
use serde_json::Value;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;

use super::doctor::out;
use crate::torchd_client;

const FLATHUB: &str = "https://dl.flathub.org/repo/flathub.flatpakrepo";
const BOX_DEBIAN: (&str, &str) = ("torch-debian", "docker.io/library/debian:stable");
const BOX_FEDORA: (&str, &str) = ("torch-fedora", "registry.fedoraproject.org/fedora:latest");

pub fn run(target: &str, aur: bool, flatpak_only: bool, distrobox: bool) -> Result<()> {
    let path = Path::new(target);
    if path.is_file() {
        return install_file(&std::fs::canonicalize(path)?);
    }
    if !valid_name(target) {
        bail!("{target:?} is neither an existing file nor a valid package name");
    }
    if distrobox {
        return in_box(BOX_DEBIAN, &["sudo", "env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "install", "-y", "-q", target], Some(target));
    }
    if !aur && !flatpak_only && in_repos(target) {
        return super::update::run(&[target.to_string()]);
    }
    if !aur {
        match flathub_match(target)? {
            Some((id, name)) => {
                if flatpak_only || confirm(&format!("{target} is not in the Arch repos. Install {name} ({id}) from Flathub?"))? {
                    return flatpak(&["install", "--user", "-y", "flathub", &id]);
                }
                bail!("cancelled");
            }
            None if flatpak_only => bail!("{target} not found on Flathub"),
            None => {}
        }
    }
    match aur_info(target)? {
        Some(info) if aur => aur_install(&info),
        Some(_) => bail!(
            "{target} is only in the AUR (community-maintained, not reviewed by Arch or TorchOS).\n\
             Review its PKGBUILD and build it with: torch install --aur {target}"
        ),
        None => bail!(
            "{target} was not found in the Arch repos, on Flathub or in the AUR.\n\
             Debian/Ubuntu software: torch install --distrobox {target}"
        ),
    }
}

fn valid_name(n: &str) -> bool {
    !n.is_empty() && !n.starts_with('-') && n.chars().all(|c| c.is_ascii_alphanumeric() || "@._+-".contains(c))
}

fn confirm(question: &str) -> Result<bool> {
    print!("{question} [y/N] ");
    std::io::stdout().flush().ok();
    let mut a = String::new();
    std::io::stdin().read_line(&mut a)?;
    Ok(a.trim().eq_ignore_ascii_case("y"))
}

fn sh(cmd: &str, args: &[&str]) -> Result<()> {
    let s = Command::new(cmd).args(args).status().with_context(|| format!("running {cmd}"))?;
    if !s.success() {
        bail!("{cmd} {} failed", args.join(" "));
    }
    Ok(())
}

fn http_json(args: &[&str]) -> Result<Value> {
    let body = Command::new("curl").args(["-fsSL", "--max-time", "20"]).args(args).output().context("running curl")?;
    if !body.status.success() {
        bail!("network request failed: {}", args.last().unwrap_or(&""));
    }
    serde_json::from_slice(&body.stdout).context("parsing JSON response")
}

/// Make sure a tool exists, installing its repo package through torchd if not.
fn ensure(binary: &str, packages: &[&str]) -> Result<()> {
    if out("which", &[binary]).is_none() {
        println!("{binary} is not installed; installing {} first", packages.join(", "));
        let names: Vec<String> = packages.iter().map(|s| s.to_string()).collect();
        super::update::run(&names)?;
    }
    Ok(())
}

// ---- pacman ----

fn in_repos(name: &str) -> bool {
    // Local sync DB first (covers every configured repo); a fresh install may not have one yet.
    if out("pacman", &["-Si", "--", name]).is_some() {
        return true;
    }
    http_json(&[&format!("https://archlinux.org/packages/search/json/?name={name}")])
        .is_ok_and(|v| v["results"].as_array().is_some_and(|r| !r.is_empty()))
}

// ---- Flatpak ----

/// Exact matches only (app id, last id component, or display name): a resolver must never
/// install a *different* app than the one asked for. Near misses are listed instead.
pub fn pick_flathub(hits: &Value, want: &str) -> Result<Option<(String, String)>, Vec<String>> {
    let hits = hits["hits"].as_array().cloned().unwrap_or_default();
    let w = want.to_lowercase();
    let exact = hits.iter().find(|h| {
        let id = h["app_id"].as_str().unwrap_or("").to_lowercase();
        let name = h["name"].as_str().unwrap_or("").to_lowercase();
        id == w || id.rsplit('.').next() == Some(w.as_str()) || name == w
    });
    match exact {
        Some(h) => Ok(Some((h["app_id"].as_str().unwrap_or("").into(), h["name"].as_str().unwrap_or("").into()))),
        None if hits.is_empty() => Ok(None),
        None => Err(hits
            .iter()
            .take(5)
            .map(|h| format!("{} ({})", h["name"].as_str().unwrap_or("?"), h["app_id"].as_str().unwrap_or("?")))
            .collect()),
    }
}

fn flathub_match(name: &str) -> Result<Option<(String, String)>> {
    let q = serde_json::json!({"query": name, "filters": []}).to_string();
    let hits = match http_json(&["-X", "POST", "-H", "Content-Type: application/json", "-d", &q, "https://flathub.org/api/v2/search"]) {
        Ok(h) => h,
        Err(_) => return Ok(None), // Flathub unreachable: fall through to the AUR check
    };
    match pick_flathub(&hits, name) {
        Ok(m) => Ok(m),
        Err(near) => {
            println!("No exact Flathub match for {name}. Close ones (install by id with --flatpak):");
            near.iter().for_each(|n| println!("  {n}"));
            Ok(None)
        }
    }
}

fn flatpak(args: &[&str]) -> Result<()> {
    ensure("flatpak", &["flatpak"])?;
    sh("flatpak", &["remote-add", "--user", "--if-not-exists", "flathub", FLATHUB])?;
    sh("flatpak", args)
}

// ---- AUR ----

fn aur_info(name: &str) -> Result<Option<Value>> {
    let v = http_json(&[&format!("https://aur.archlinux.org/rpc/v5/info?arg[]={name}")])?;
    Ok(v["results"].as_array().and_then(|r| r.first().cloned()))
}

/// Dependency names from `makepkg --printsrcinfo` (version constraints stripped).
pub fn srcinfo_deps(srcinfo: &str) -> Vec<String> {
    let mut v: Vec<String> = srcinfo
        .lines()
        .filter_map(|l| l.trim().split_once(" = "))
        .filter(|(k, _)| matches!(*k, "depends" | "makedepends" | "checkdepends"))
        .map(|(_, d)| d.split(['<', '>', '=']).next().unwrap_or(d).to_string())
        .collect();
    v.sort();
    v.dedup();
    v
}

fn aur_install(info: &Value) -> Result<()> {
    let base = info["PackageBase"].as_str().context("AUR reply without PackageBase")?;
    if !valid_name(base) {
        bail!("unexpected AUR package base {base:?}");
    }
    let s = |k: &str| info[k].as_str().unwrap_or("-").to_string();
    println!("AUR package {} {}", s("Name"), s("Version"));
    println!("  maintainer: {}   votes: {}   popularity: {:.2}", s("Maintainer"), info["NumVotes"], info["Popularity"].as_f64().unwrap_or(0.0));
    if !info["OutOfDate"].is_null() {
        println!("  WARNING: flagged out of date");
    }
    if info["Maintainer"].is_null() {
        println!("  WARNING: orphaned (no maintainer)");
    }

    let cache = PathBuf::from(std::env::var("HOME").context("HOME not set")?).join(".cache/torch/aur");
    std::fs::create_dir_all(&cache)?;
    let dir = cache.join(base);
    let dir_s = dir.to_str().context("non-UTF-8 cache path")?;
    // Diff-before-apply: on a rebuild, show what changed since the last reviewed version.
    let rebuilt = dir.join(".git").is_dir();
    if rebuilt {
        sh("git", &["-C", dir_s, "fetch", "-q"])?;
        let _ = Command::new("git").args(["-C", dir_s, "--no-pager", "diff", "HEAD", "FETCH_HEAD"]).status();
        sh("git", &["-C", dir_s, "merge", "-q", "--ff-only", "FETCH_HEAD"])?;
    } else {
        sh("git", &["clone", "-q", &format!("https://aur.archlinux.org/{base}.git"), dir_s])?;
        println!("----- PKGBUILD -----\n{}\n--------------------", std::fs::read_to_string(dir.join("PKGBUILD"))?);
    }
    if !confirm("You reviewed the PKGBUILD above. Build it?")? {
        bail!("cancelled");
    }
    ensure("fakeroot", &["base-devel"])?; // makepkg's toolchain is not on the ISO

    let srcinfo = Command::new("makepkg").arg("--printsrcinfo").current_dir(&dir).output()?;
    let deps = srcinfo_deps(&String::from_utf8_lossy(&srcinfo.stdout));
    // pacman -T prints the dependencies that are not satisfied yet.
    let missing: Vec<String> = Command::new("pacman").arg("-T").args(&deps).output()
        .map(|o| String::from_utf8_lossy(&o.stdout).lines().map(String::from).collect())
        .unwrap_or_default();
    let (repo, aur_only): (Vec<String>, Vec<String>) = missing.into_iter().partition(|d| in_repos(d));
    if !aur_only.is_empty() {
        // ponytail: no recursive AUR builds; each AUR dependency is its own reviewed install.
        bail!("needs AUR packages first: {} (torch install --aur <name> for each)", aur_only.join(", "));
    }
    if !repo.is_empty() {
        super::update::run(&repo)?;
    }
    sh_in(&dir, "makepkg", &["-f", "--noconfirm"])?;
    let list = Command::new("makepkg").arg("--packagelist").current_dir(&dir).output()?;
    let built: Vec<String> = String::from_utf8_lossy(&list.stdout).lines().filter(|p| Path::new(p).exists()).map(String::from).collect();
    if built.is_empty() {
        bail!("makepkg produced no package");
    }
    for p in built {
        println!("{}", torchd_client::call("package.install_file", serde_json::json!({"path": p}))?);
    }
    Ok(())
}

fn sh_in(dir: &Path, cmd: &str, args: &[&str]) -> Result<()> {
    let s = Command::new(cmd).args(args).current_dir(dir).status().with_context(|| format!("running {cmd}"))?;
    if !s.success() {
        bail!("{cmd} failed in {}", dir.display());
    }
    Ok(())
}

// ---- Distrobox ----

fn in_box((name, image): (&str, &str), cmd: &[&str], export_app: Option<&str>) -> Result<()> {
    ensure("distrobox", &["distrobox", "podman"])?;
    let boxes = out("distrobox", &["list", "--no-color"]).unwrap_or_default();
    if !boxes.lines().any(|l| l.split('|').nth(1).is_some_and(|c| c.trim() == name)) {
        sh("distrobox", &["create", "--yes", "--name", name, "--image", image])?;
    }
    let mut args = vec!["enter", name, "--"];
    args.extend_from_slice(cmd);
    if cmd.contains(&"apt-get") {
        sh("distrobox", &["enter", name, "--", "sudo", "apt-get", "update", "-q"])?;
    }
    sh("distrobox", &args)?;
    let Some(app) = export_app else { return Ok(()) };
    let quiet = |args: &[&str]| Command::new("distrobox").args(args).output().is_ok_and(|o| o.status.success());
    if quiet(&["enter", name, "--", "distrobox-export", "--app", app]) {
        println!("{app} is in your app launcher (runs inside the {name} container)");
        return Ok(());
    }
    // No desktop entry: a CLI tool. Export the binary as a wrapper in ~/.local/bin.
    // `app` passed valid_name(), so it is safe inside this shell snippet.
    let bin = format!("p=$(command -v {app} || echo /usr/games/{app}); distrobox-export --bin \"$p\" --export-path \"$HOME/.local/bin\"");
    if quiet(&["enter", name, "--", "sh", "-c", &bin]) {
        println!("{app} exported to ~/.local/bin/{app} (runs inside the {name} container)");
    } else {
        println!("Installed in the container; run it with: distrobox enter {name} -- {app}");
    }
    Ok(())
}

// ---- files ----

fn install_file(p: &Path) -> Result<()> {
    let s = p.to_str().context("non-UTF-8 path")?;
    let lower = s.to_lowercase();
    let stem = p.file_name().and_then(|n| n.to_str()).unwrap_or("app");
    if lower.ends_with(".pkg.tar.zst") {
        println!("{}", torchd_client::call("package.install_file", serde_json::json!({"path": s}))?);
    } else if lower.ends_with(".flatpakref") {
        flatpak(&["install", "--user", "-y", "--from", s])?;
    } else if lower.ends_with(".appimage") {
        appimage(p, stem)?;
    } else if lower.ends_with(".exe") || lower.ends_with(".msi") {
        ensure("wine", &["wine"])?;
        if lower.ends_with(".msi") { sh("wine", &["msiexec", "/i", s])? } else { sh("wine", &[s])? }
    } else if lower.ends_with(".deb") {
        in_box(BOX_DEBIAN, &["sudo", "env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "install", "-y", "-q", s], None)?;
    } else if lower.ends_with(".rpm") {
        in_box(BOX_FEDORA, &["sudo", "dnf", "install", "-y", s], None)?;
    } else {
        bail!("don't know how to install {stem}: expected .pkg.tar.zst, .flatpakref, .AppImage, .exe/.msi, .deb or .rpm");
    }
    Ok(())
}

fn appimage(p: &Path, file: &str) -> Result<()> {
    // Type-2 AppImages mount themselves with libfuse2.
    if !Path::new("/usr/lib/libfuse.so.2").exists() {
        super::update::run(&["fuse2".to_string()])?;
    }
    let home = PathBuf::from(std::env::var("HOME").context("HOME not set")?);
    let apps = home.join("Applications");
    std::fs::create_dir_all(&apps)?;
    let dest = apps.join(file);
    std::fs::copy(p, &dest)?;
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&dest, std::fs::Permissions::from_mode(0o755))?;
    let name = file.split(['-', '_', '.']).next().unwrap_or(file);
    let desktop = home.join(".local/share/applications").join(format!("appimage-{name}.desktop"));
    std::fs::create_dir_all(desktop.parent().unwrap())?;
    std::fs::write(&desktop, format!("[Desktop Entry]\nType=Application\nName={name}\nExec=\"{}\" %U\nTerminal=false\nCategories=Utility;\n", dest.display()))?;
    println!("Installed to {} (launcher: {name})", dest.display());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn flathub_picks_exact_matches_only() {
        let hits = json!({"hits": [
            {"name": "Spotify", "app_id": "com.spotify.Client"},
            {"name": "Spot", "app_id": "dev.alextren.Spot"}]});
        assert_eq!(pick_flathub(&hits, "spotify").unwrap(), Some(("com.spotify.Client".into(), "Spotify".into())));
        assert_eq!(pick_flathub(&hits, "com.spotify.Client").unwrap().unwrap().0, "com.spotify.Client");
        assert_eq!(pick_flathub(&hits, "spo").unwrap_err().len(), 2);
        assert_eq!(pick_flathub(&json!({"hits": []}), "x").unwrap(), None);
    }

    #[test]
    fn srcinfo_deps_strip_versions() {
        let s = "pkgbase = x\n\tmakedepends = cargo\n\tdepends = gtk3>=3.24\n\tdepends = nss\n\toptdepends = foo\npkgname = x\n\tdepends = nss\n";
        assert_eq!(srcinfo_deps(s), ["cargo", "gtk3", "nss"]);
    }

    #[test]
    fn names_reject_options_and_paths() {
        assert!(valid_name("visual-studio-code-bin") && valid_name("g++"));
        for bad in ["", "-x", "a/b", "a b", "$(x)"] {
            assert!(!valid_name(bad), "{bad}");
        }
    }
}
