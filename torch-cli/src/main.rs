use anyhow::Result;
use clap::{Parser, Subcommand};

mod commands {
    pub mod dataset;
    pub mod init;
    pub mod lab;
}

mod system {
    pub mod btrfs;
    pub mod gpu_detect;
    pub mod isolation;
}

mod types {
    pub mod lab;
}

#[derive(Parser)]
#[command(name = "torch")]
#[command(version = "0.2.0")]
#[command(about = "Torch OS CLI - Disposable AI Research Environments", long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    Init,
    Lab {
        #[command(subcommand)]
        action: LabAction,
    },
    Dataset {
        #[command(subcommand)]
        action: DatasetAction,
    },
    Model {
        #[command(subcommand)]
        action: ModelAction,
    },
    Gpu {
        #[command(subcommand)]
        action: GpuAction,
    },
}

#[derive(Subcommand)]
enum LabAction {
    Create { name: String },
    Enter { name: String },
    Reset { name: String },
    Delete { name: String },
    Info { name: String },
    List,
}

#[derive(Subcommand)]
enum DatasetAction {
    List,
}

#[derive(Subcommand)]
enum ModelAction {
    List,
}

#[derive(Subcommand)]
enum GpuAction {
    Status,
}

fn main() -> Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Commands::Init => commands::init::run_init()?,
        Commands::Lab { action } => match action {
            LabAction::Create { name } => commands::lab::create(&name)?,
            LabAction::Enter { name } => system::isolation::enter_isolated(&name)?,
            LabAction::Reset { name } => commands::lab::reset(&name)?,
            LabAction::Delete { name } => commands::lab::delete(&name)?,
            LabAction::Info { name } => commands::lab::info(&name)?,
            LabAction::List => commands::lab::list()?,
        },
        Commands::Dataset { action } => match action {
            DatasetAction::List => commands::dataset::list_datasets()?,
        },
        Commands::Model { action } => match action {
            ModelAction::List => commands::dataset::list_models()?,
        },
        Commands::Gpu { action } => match action {
            GpuAction::Status => system::gpu_detect::get_gpu_status()?,
        },
    }

    Ok(())
}
