#!/bin/bash
# install-cubic-mint.sh: Install Cubic on Linux Mint

set -e

echo "--- Installing Cubic on Linux Mint ---"
sudo add-apt-repository -y ppa:cubic-wizard/release
sudo apt update
sudo apt install -y cubic

echo "--- Cubic Installation Complete ---"
echo "You can now launch Cubic from your Menu to start building Torch OS."
