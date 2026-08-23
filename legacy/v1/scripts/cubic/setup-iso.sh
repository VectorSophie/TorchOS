#!/bin/bash
# Cubic Chroot Environment Setup Script for Torch OS

set -e

echo "--- Customizing Torch OS ISO via Cubic ---"

# 1. Update and install core dependencies
apt update
apt install -y cinnamon lightdm systemd-container btrfs-progs python3-gi gir1.2-gtk-3.0 gnome-terminal

# 2. Setup Torch Directories
mkdir -p /torch/labs /torch/base-lab /torch-data/datasets /torch-data/models

# 3. Install Torch CLI (Assumes binary is already compiled or available in context)
# In Cubic, you would copy the binary from your host to the chroot
# cp /path/to/torch-cli /usr/local/bin/torch
chmod +x /usr/local/bin/torch

# 4. Install UI Components
# cp /path/to/torch-labs-gui.py /usr/local/bin/torch-labs-gui.py
chmod +x /usr/local/bin/torch-labs-gui.py

# 5. Apply Branding
# cp /path/to/logo.png /usr/share/torch/logo.png
# cp /path/to/torch-labs.desktop /usr/share/applications/
# cp -r /path/to/torch-theme /usr/share/themes/

# 6. Configure Default Wallpaper (Cinnamon)
gsettings set org.cinnamon.desktop.background picture-uri "file:///usr/share/backgrounds/torch-wallpaper.png"

# 7. Enable systemd-nspawn services if needed
systemctl enable systemd-nspawn@

echo "--- Customization Complete ---"
