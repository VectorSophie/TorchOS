#!/bin/bash
# setup-mint.sh: Install Torch OS on a Linux Mint PC

set -e

echo "--- Installing Torch OS Dependencies ---"
sudo apt update
sudo apt install -y \
    btrfs-progs \
    systemd-container \
    python3-gi \
    gir1.2-gtk-3.0 \
    gnome-terminal \
    build-essential \
    pkg-config \
    libssl-dev

echo "--- Building Torch CLI ---"
cd torch-cli
cargo build --release
sudo cp target/release/torch-cli /usr/local/bin/torch
cd ..

echo "--- Installing UI Components ---"
sudo mkdir -p /usr/share/torch
sudo cp assets/logo.png /usr/share/torch/logo.png
sudo cp ui/src/torch-labs-gui.py /usr/local/bin/torch-labs-gui.py
sudo chmod +x /usr/local/bin/torch-labs-gui.py
sudo cp ui/torch-labs.desktop /usr/share/applications/

echo "--- Setting up Theme ---"
sudo mkdir -p /usr/share/themes/torch-theme
sudo cp -r ui/theme/* /usr/share/themes/torch-theme/

echo "--- DONE ---"
echo "Next steps:"
echo "1. Ensure you have a Btrfs partition mounted at /torch"
echo "2. Run 'sudo torch init' to prepare the system."
echo "3. Open 'Torch Labs Manager' from your Mint Menu."
