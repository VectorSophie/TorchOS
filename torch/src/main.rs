use clap::{Parser, Subcommand};
use std::process::ExitCode;

mod commands {
    pub mod diagnose;
    pub mod doctor;
    pub mod gpu;
    pub mod hardware;
    pub mod install;
    pub mod kernel;
    pub mod service;
    pub mod snapshot;
    pub mod status;
    pub mod update;
}
mod torchd_client;

// PHASE 1 NOTE: every command here shells out directly to snapper/systemctl/etc.
// That's a deliberate stopgap, not the target architecture — per the locked design
// (see ../CLAUDE.md), Phase 2 introduces `torchd`, a privileged broker with a typed
// operation surface, and these commands should become thin clients that talk to it
// over its Unix socket instead of invoking system tools directly. Keeping the direct
// shell-outs isolated to commands/*.rs (not scattered through main.rs) is what makes
// that swap a contained change later rather than a rewrite.
//
// PHASE 2 UPDATE: snapshot create/rollback, update, and service restart are now
// torchd clients (see torchd_client.rs). status/doctor/gpu/diagnose/snapshot list
// remain direct — they're unprivileged reads with nothing to broker.

#[derive(Parser)]
#[command(name = "torch")]
#[command(version)]
#[command(about = "TorchOS CLI — the single human-facing interface to the system", long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Show basic host status (uptime, disk, memory)
    Status,
    /// Run health checks (exit 0 healthy, 1 degraded/failed, 2 unsupported environment)
    Doctor {
        /// Machine-readable output
        #[arg(long)]
        json: bool,
    },
    /// GPU detection
    Gpu,
    /// Structured JSON diagnostics for scripts, support bundles and tests
    Diagnose,
    /// Btrfs/Snapper snapshot management
    Snapshot {
        #[command(subcommand)]
        action: SnapshotAction,
    },
    /// Upgrade the whole system, or install repo packages (always with a full upgrade: Arch has no partial upgrades)
    Update {
        /// Package names to install; none = just upgrade everything
        packages: Vec<String>,
    },
    /// Install anything: repo package, Flathub app, AUR package (--aur), a Debian package in a
    /// container (--distrobox), or a file (.pkg.tar.zst, .AppImage, .flatpakref, .exe/.msi, .deb, .rpm)
    Install {
        /// Package/app name or path to a file
        target: String,
        /// Allow the AUR (community-maintained, unreviewed): shows the PKGBUILD and asks before building
        #[arg(long)]
        aur: bool,
        /// Only look on Flathub
        #[arg(long, conflicts_with = "aur")]
        flatpak: bool,
        /// Install a Debian package into a Distrobox container and export it to the desktop
        #[arg(long, conflicts_with_all = ["aur", "flatpak"])]
        distrobox: bool,
    },
    /// Remove repo packages via torchd (asks for confirmation)
    Remove {
        #[arg(required = true)]
        packages: Vec<String>,
    },
    /// Kernels: list installed ones, add another (incl. the CachyOS kernel layer)
    Kernel {
        #[command(subcommand)]
        action: KernelAction,
    },
    /// Hardware summary: CPU level, GPUs + drivers in use, memory, disks, firmware/Secure Boot
    Hardware,
    /// Manage systemd services via torchd
    Service {
        #[command(subcommand)]
        action: ServiceAction,
    },
}

#[derive(Subcommand)]
enum SnapshotAction {
    /// List snapshots
    List,
    /// Create a labeled checkpoint snapshot
    Create {
        /// What this snapshot is for, e.g. "before enabling nvidia-open driver"
        description: String,
    },
    /// Roll back to a prior snapshot (takes effect on next reboot)
    Rollback {
        /// Snapshot number, from `torch snapshot list`
        snapshot_id: String,
    },
}

#[derive(Subcommand)]
enum KernelAction {
    /// Installed and running kernels
    List,
    /// Install another kernel: linux, linux-lts, linux-zen, linux-hardened, linux-cachyos
    Add { name: String },
}

#[derive(Subcommand)]
enum ServiceAction {
    /// Restart a systemd service
    Restart {
        /// Service name, e.g. "NetworkManager"
        name: String,
    },
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    // Exit codes: 0 healthy, 1 degraded/failed checks, 2 unsupported environment, 3 internal failure.
    let result: anyhow::Result<u8> = match cli.command {
        Commands::Status => commands::status::run().map(|_| 0),
        Commands::Doctor { json } => commands::doctor::run(json),
        Commands::Gpu => commands::gpu::run(),
        Commands::Diagnose => commands::diagnose::run(),
        Commands::Snapshot { action } => match action {
            SnapshotAction::List => commands::snapshot::list(),
            SnapshotAction::Create { description } => commands::snapshot::create(&description),
            SnapshotAction::Rollback { snapshot_id } => commands::snapshot::rollback(&snapshot_id),
        }
        .map(|_| 0),
        Commands::Update { packages } => commands::update::run(&packages).map(|_| 0),
        Commands::Install { target, aur, flatpak, distrobox } => {
            commands::install::run(&target, aur, flatpak, distrobox).map(|_| 0)
        }
        Commands::Remove { packages } => commands::update::remove(&packages).map(|_| 0),
        Commands::Kernel { action } => match action {
            KernelAction::List => commands::kernel::list(),
            KernelAction::Add { name } => commands::kernel::add(&name),
        }
        .map(|_| 0),
        Commands::Hardware => commands::hardware::run().map(|_| 0),
        Commands::Service { action } => match action {
            ServiceAction::Restart { name } => commands::service::restart(&name).map(|_| 0),
        },
    };
    match result {
        Ok(code) => ExitCode::from(code),
        Err(e) => {
            eprintln!("torch: {e:#}");
            ExitCode::from(3)
        }
    }
}
