# GPU Support in Torch OS

Torch OS provides built-in GPU detection to ensure research environments can leverage hardware acceleration.

## Detection

You can check the GPU status using:
```bash
torch gpu status
```

This command detects NVIDIA GPUs and displays:
- GPU Model Name
- Total VRAM
- Driver Version
- CUDA availability

## Inside Labs

To use GPUs inside a Torch Lab, ensure the host has NVIDIA drivers and `nvidia-container-toolkit` installed. 

Phase 2 uses `systemd-nspawn` for isolation. GPU passthrough to `systemd-nspawn` requires mounting the NVIDIA device nodes:
- `/dev/nvidia*`
- `/dev/nvidia-uvm`
- `/dev/nvidiactl`

*Note: Future phases will automate GPU passthrough configuration.*
