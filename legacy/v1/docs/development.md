# Torch OS Development Guide

This guide explains how to build and test Torch OS Phase 1.

## Building the CLI

The CLI is written in Rust and located in `torch-cli/`.

```bash
cd torch-cli
cargo build --release
```

The binary will be available at `target/release/torch-cli`.

## Docker Development Environment

A Dockerfile is provided to create a consistent development environment with all dependencies (including Btrfs tools).

```bash
./docker/build.sh
docker run -it --privileged torch-os:latest
```

*Note: `--privileged` is required for Btrfs operations if the host supports it.*

## VM Deployment

The Docker image can be converted to a `.qcow2` disk image for VM testing.

To run the VM:
```bash
./vm/run-vm.sh
```

## Testing Lab Snapshots

To verify the core concept:

1. `torch lab create test`
2. `torch lab enter test`
3. `touch hello.txt`
4. `exit`
5. `torch lab reset test`
6. `torch lab enter test`
7. Verify `hello.txt` is gone.
