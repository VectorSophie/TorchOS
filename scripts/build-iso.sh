#!/bin/bash
# build-iso.sh: Automate Torch OS ISO creation via Cubic CLI
# This script assumes 'cubic' is installed and the base Mint ISO is available.

set -e

BASE_ISO="linuxmint-21.3-cinnamon-64bit.iso"
OUTPUT_DIR="./build"
PROJECT_ROOT=$(pwd)

if [ ! -f "$BASE_ISO" ]; then
    echo "Error: Base Mint ISO ($BASE_ISO) not found."
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "--- Starting ISO Build Process ---"

# Note: In a real environment, cubic commands require interactive steps
# unless using a pre-configured cubic project.
# We will simulate the automation by providing the setup scripts to the build dir.

cp scripts/cubic/setup-iso.sh "$OUTPUT_DIR/"
cp scripts/setup-mint.sh "$OUTPUT_DIR/"

echo "Steps for Manual ISO Generation (until full automation is ready):"
echo "1. Open Cubic and select $BASE_ISO"
echo "2. In the Chroot terminal, run: /mnt/project/scripts/cubic/setup-iso.sh"
echo "3. Generate the ISO and save it to $OUTPUT_DIR/torch-os.iso"

# Verification of current build assets
echo "--- Verifying Build Assets ---"
ls -l torch-cli/target/release/torch-cli
ls -l ui/src/torch-labs-gui.py

echo "Build assets ready for ISO injection."
