# Torch OS Architecture

Torch OS is an experimental Linux environment designed for fast, disposable AI experimentation.

## Core Concept: Torch Labs

The fundamental innovation of Torch OS is the **Torch Lab**. A lab is a disposable research environment implemented using Btrfs subvolume snapshots.

### Btrfs Snapshot Model

All labs are stored under `/torch/labs`. They are created as snapshots of `/torch/base-lab`.

- **Base Lab**: `/torch/base-lab` (Clean template)
- **Active Labs**: `/torch/labs/<lab-name>`
- **Snapshots**: `/torch/snapshots`

When a user creates a lab:
`btrfs subvolume snapshot /torch/base-lab /torch/labs/<name>`

When a user resets a lab:
1. `btrfs subvolume delete /torch/labs/<name>`
2. `btrfs subvolume snapshot /torch/base-lab /torch/labs/<name>`

This ensures that any changes made inside a lab can be wiped instantly, returning the environment to a known good state.

## Data Separation

Torch OS strictly separates the operating system environment from research data.

- `/torch`: Contains the OS environments (Labs).
- `/torch-data`: Persistent storage for models, datasets, and results.

Research data should always be stored in `/torch-data` to ensure it persists across lab resets.
