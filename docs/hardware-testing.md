# Torch OS Hardware & Local Machine Guide

This guide describes how to run Torch OS on actual hardware (ISO) or on an existing Linux Mint PC.

## Option 1: Running on an existing Linux Mint PC

If you have a PC running Linux Mint (Cinnamon), you can install the Torch OS components directly.

### 1. Transfer the Folder
Copy the `torch-os` project folder to your Mint machine.

### 2. Run the Installation Script
```bash
cd torch-os
chmod +x scripts/setup-mint.sh
./scripts/setup-mint.sh
```

### 3. Handle the Btrfs Requirement
Torch OS requires a Btrfs filesystem to manage labs. If your Mint PC is installed on EXT4, you can create a virtual Btrfs drive:

```bash
# Create a 10GB virtual drive
truncate -s 10G torch-disk.img
mkfs.btrfs torch-disk.img

# Mount it to the path Torch expects
sudo mkdir -p /torch
sudo mount torch-disk.img /torch
```

### 4. Initialize and Run
```bash
sudo torch init
# Now open 'Torch Labs Manager' from your Cinnamon Menu.
```

---

## Option 2: Generating a Bootable ISO (Cubic)

1. **Launch Cubic** and select the Ubuntu 24.04 ISO as the base.
2. **Virtual Root Environment**: Once Cubic opens the terminal (chroot), copy the `scripts/cubic/setup-iso.sh` content or run it.
3. **Mocking GPU (Optional)**: If testing on hardware without an NVIDIA GPU, install the mock script:
   ```bash
   cp scripts/mock-gpu/nvidia-smi /usr/local/bin/nvidia-smi
   chmod +x /usr/local/bin/nvidia-smi
   ```
4. **Generate**: Complete the Cubic wizard to generate `torch-os-custom.iso`.

## Hardware Testing Workflow

### 1. Boot & Login
- Flash the ISO to a USB drive (using Etcher or `dd`).
- Boot the hardware from USB.
- Log in to the Cinnamon desktop (Branded with Torch wallpaper and theme).

### 2. System Initialization
Open a terminal (Ctrl+Alt+T) and run:
```bash
sudo torch init
```
*Note: Ensure the disk you are installing on is formatted as Btrfs.*

### 3. Torch Labs Manager
- Open the Cinnamon Menu.
- Navigate to **Development** -> **Torch Labs Manager**.
- Click **Create Lab**, name it `hw-test`.

### 4. GPU Verification
Inside the terminal or GUI:
```bash
torch gpu status
```
**Expected Result**: Displays the mocked "RTX 4090 Mock" information (Name, VRAM, Driver).

### 5. Entering the Lab
- In the GUI, select `hw-test` and click **Enter Lab**.
- A new terminal window should open with the prompt `root@hw-test`.
- Run `ls /data/datasets` to verify persistence mounts.

## Summary of Success
The workflow is successful if the GUI successfully triggers CLI actions and the isolated environment is established using the underlying Btrfs subvolumes on actual hardware.
