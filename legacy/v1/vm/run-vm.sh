#!/bin/bash
set -e

if [ ! -f "torch-os.qcow2" ]; then
    echo "Error: torch-os.qcow2 not found. Please build the VM image first."
    exit 1
fi

qemu-system-x86_64 \
    -m 8G \
    -smp 4 \
    -drive file=torch-os.qcow2,format=qcow2 \
    -net user,hostfwd=tcp::2222-:22 -net nic \
    -enable-kvm
