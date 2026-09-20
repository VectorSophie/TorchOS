use anyhow::Result;
use clap::{Parser, Subcommand};

mod commands {
    pub mod diagnose;
    pub mod doctor;
    pub mod gpu;
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
#[command(version = "0.1.0")]
#[command(about = "TorchOS CLI — the single human-facing interface to the system", long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Show basic host status (uptime, disk, memory)
    Status,
    /// Run basic health checks
    Doctor,
    /// GPU detection
    Gpu,
    /// Structured (JSON) system diagnostics — for scripts and the future AI assistant
    Diagnose,
    /// Btrfs/Snapper snapshot management
    Snapshot {
        #[command(subcommand)]
        action: SnapshotAction,
    },
    /// Install packages via torchd
    Update {
        /// Package names to install
        packages: Vec<String>,
    },
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
enum ServiceAction {
    /// Restart a systemd service
    Restart {
        /// Service name, e.g. "NetworkManager"
        name: String,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Commands::Status => commands::status::run()?,
        Commands::Doctor => commands::doctor::run()?,
        Commands::Gpu => commands::gpu::run()?,
        Commands::Diagnose => commands::diagnose::run()?,
        Commands::Snapshot { action } => match action {
            SnapshotAction::List => commands::snapshot::list()?,
            SnapshotAction::Create { description } => commands::snapshot::create(&description)?,
            SnapshotAction::Rollback { snapshot_id } => commands::snapshot::rollback(&snapshot_id)?,
        },
        Commands::Update { packages } => commands::update::run(&packages)?,
        Commands::Service { action } => match action {
            ServiceAction::Restart { name } => commands::service::restart(&name)?,
        },
    }

    Ok(())
}
