use anyhow::Result;
use clap::{Parser, Subcommand};

mod commands {
    pub mod doctor;
    pub mod gpu;
    pub mod snapshot;
    pub mod status;
}

// PHASE 1 NOTE: every command here shells out directly to snapper/systemctl/etc.
// That's a deliberate stopgap, not the target architecture — per the locked design
// (see ../CLAUDE.md), Phase 2 introduces `torchd`, a privileged broker with a typed
// operation surface, and these commands should become thin clients that talk to it
// over its Unix socket instead of invoking system tools directly. Keeping the direct
// shell-outs isolated to commands/*.rs (not scattered through main.rs) is what makes
// that swap a contained change later rather than a rewrite.

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
    /// Btrfs/Snapper snapshot management
    Snapshot {
        #[command(subcommand)]
        action: SnapshotAction,
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
}

fn main() -> Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Commands::Status => commands::status::run()?,
        Commands::Doctor => commands::doctor::run()?,
        Commands::Gpu => commands::gpu::run()?,
        Commands::Snapshot { action } => match action {
            SnapshotAction::List => commands::snapshot::list()?,
            SnapshotAction::Create { description } => commands::snapshot::create(&description)?,
        },
    }

    Ok(())
}
