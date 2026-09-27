use super::check_name;
use anyhow::{bail, Context, Result};
use serde::Deserialize;
use std::process::Command;

#[derive(Deserialize)]
struct PackageArgs {
    names: Vec<String>,
}

/// pacman sync right after boot fails with an opaque download error when the network is not up yet.
/// Wait for it (bounded) and say so plainly instead.
pub fn wait_for_network() -> Result<()> {
    let online = Command::new("nm-online").args(["-q", "-t", "30"]).status().is_ok_and(|s| s.success());
    if !online {
        bail!("no network: NetworkManager is still offline after 30 s. Connect (nmtui, or the Waybar network icon) and retry");
    }
    Ok(())
}

pub fn pacman(flags: &[&str], targets: &[String]) -> Result<()> {
    let status = Command::new("pacman")
        .args(flags)
        .arg("--noconfirm")
        .arg("--")
        .args(targets)
        .status()
        .context("running pacman")?;
    if !status.success() {
        bail!("pacman {} failed for: {}", flags.join(" "), targets.join(", "));
    }
    Ok(())
}

fn run(flags: &[&str], verb: &str, args: &serde_json::Value) -> Result<String> {
    let args: PackageArgs =
        serde_json::from_value(args.clone()).with_context(|| format!("bad args for package.{verb}"))?;
    if args.names.is_empty() {
        bail!("package.{verb} requires at least one package name");
    }
    args.names.iter().try_for_each(|n| check_name(n))?;
    pacman(flags, &args.names)?;
    Ok(format!("{verb}: {}", args.names.join(", ")))
}

pub fn install(args: &serde_json::Value) -> Result<String> {
    // -Syu, never a bare -Sy: Arch does not support partial upgrades, and a fresh install has no sync
    // databases at all. snap-pac takes the pre/post snapshots around this.
    wait_for_network()?;
    run(&["-Syu", "--needed"], "installed (system upgraded)", args)
}

pub fn remove(args: &serde_json::Value) -> Result<String> {
    run(&["-R"], "removed", args)
}

pub fn upgrade() -> Result<String> {
    wait_for_network()?;
    pacman(&["-Syu"], &[])?;
    Ok("system upgraded".into())
}

#[derive(Deserialize)]
struct FileArgs {
    path: String,
}

/// A package file the client built (AUR) or downloaded. Only a plain absolute path to an existing
/// `*.pkg.tar.zst` reaches pacman; it must not be a symlink (the file checked is the file installed).
pub fn check_package_path(path: &str) -> Result<()> {
    let p = std::path::Path::new(path);
    let name_ok = p.is_absolute()
        && path.ends_with(".pkg.tar.zst")
        && !path.contains("/../")
        && !path.contains('\n');
    if !name_ok {
        bail!("not an absolute *.pkg.tar.zst path: {path:?}");
    }
    let meta = std::fs::symlink_metadata(p).with_context(|| format!("{path} not found"))?;
    if !meta.is_file() {
        bail!("{path} is not a regular file");
    }
    Ok(())
}

pub fn install_file(args: &serde_json::Value) -> Result<String> {
    let args: FileArgs = serde_json::from_value(args.clone()).context("bad args for package.install_file")?;
    check_package_path(&args.path)?;
    wait_for_network()?; // dependencies may come from the repos
    // -U resolves repo dependencies itself; --needed keeps reinstalls cheap.
    pacman(&["-U", "--needed"], std::slice::from_ref(&args.path))?;
    Ok(format!("installed {}", args.path))
}

#[cfg(test)]
mod tests {
    use super::check_package_path;

    #[test]
    fn package_path_rules() {
        for bad in ["rel/x.pkg.tar.zst", "/tmp/x.tar.gz", "/tmp/../etc/x.pkg.tar.zst", "/nonexistent/x.pkg.tar.zst"] {
            assert!(check_package_path(bad).is_err(), "{bad}");
        }
        let f = std::env::temp_dir().join(format!("t-{}.pkg.tar.zst", std::process::id()));
        std::fs::write(&f, b"x").unwrap();
        assert!(check_package_path(f.to_str().unwrap()).is_ok());
        std::fs::remove_file(f).ok();
    }
}
