#!/bin/sh
# Run a command in the VM over SSH (live session uses user liveuser; installed system uses the user you made).
#   VM_USER=liveuser vmssh.sh 'uname -r'      Wayland env is exported so `hyprctl`/`grim` work.
KEY=${TORCH_VM_KEY:-$HOME/.ssh/torchos_vm}
ssh -i "$KEY" -o IdentitiesOnly=yes -p "${SSH_PORT:-2222}" -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "${VM_USER:-liveuser}@localhost" \
    'export XDG_RUNTIME_DIR=/run/user/$(id -u) HYPRLAND_INSTANCE_SIGNATURE=$(ls /run/user/$(id -u)/hypr 2>/dev/null | head -1) WAYLAND_DISPLAY=wayland-1; '"$*"
