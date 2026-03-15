# Building Torch OS ISO on Linux Mint

Since Linux Mint is Ubuntu-based, it is the perfect environment to build the Torch OS ISO using **Cubic**.

## 1. Install Cubic
Run the provided helper script to add the repository and install Cubic:
```bash
chmod +x scripts/install-cubic-mint.sh
./scripts/install-cubic-mint.sh
```

## 2. Launch Cubic
1. Open Cubic from your Mint Menu.
2. Select a project directory (e.g., `~/torch-os-build`).
3. Select an **Ubuntu 24.04 Desktop ISO** as the original ISO.

## 3. Customize in the Chroot (Terminal)
When Cubic opens the terminal environment, follow these steps:

### A. Run the Setup Script
Copy the content of `scripts/cubic/setup-iso.sh` into the Cubic terminal to install dependencies and create the directory structure.

### B. Copy Torch Files
From your host (Mint machine), you can drag and drop these files directly into the Cubic window to copy them into the ISO:
- `torch-cli/target/release/torch` -> `/usr/local/bin/`
- `ui/src/torch-labs-gui.py` -> `/usr/local/bin/`
- `assets/logo.png` -> `/usr/share/torch/`
- `ui/torch-labs.desktop` -> `/usr/share/applications/`
- `ui/theme/` -> `/usr/share/themes/torch-theme/`

### C. Set Mock GPU (If needed)
If you want the mock GPU status to be available on the Live ISO:
```bash
# In Cubic terminal:
cp /path/to/scripts/mock-gpu/nvidia-smi /usr/local/bin/
chmod +x /usr/local/bin/nvidia-smi
```

## 4. Generate the ISO
1. Click **Next** through the Cubic wizard.
2. Select `lightdm` as the default display manager if prompted.
3. On the **Generate** page, wait for Cubic to build the `torch-os-custom.iso`.

## 5. Test the ISO
You can now flash this ISO to a USB drive or test it in QEMU:
```bash
qemu-system-x86_64 -m 4G -enable-kvm -cdrom torch-os-custom.iso
```
