# Torch OS Graphical Interface

Phase 3 introduces a minimal graphical layer to Torch OS to improve ergonomics while keeping the system lightweight.

## Components

### Torch Labs Manager
A GTK-based GUI for managing Torch Labs. It provides a visual interface for:
- Creating new labs
- Entering labs (via a new terminal window)
- Resetting labs to base snapshots
- Deleting labs
- Viewing lab metadata

Launch it from the **Development** category in the Cinnamon menu.

### Torch Branding
- **Logo**: Located at `/usr/share/torch/logo.png`.
- **Theme**: A custom dark ember and torch orange theme applied to Cinnamon.
- **Wallpaper**: A subtle flame-gradient dark background with the Torch logo.

## Implementation Details

The GUI acts as a wrapper around the `torch` CLI. Every action taken in the GUI translates to a standard CLI command, ensuring that the CLI remains the single source of truth for the system state.

## Configuration

The theme files are located in `/usr/share/themes/torch-theme`.
The wallpaper is located in `/usr/share/backgrounds/torch-wallpaper.png`.
