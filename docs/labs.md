# Managing Torch Labs

Torch Labs are managed using the `torch` CLI.

## Initialization

Before using labs, initialize the system:
```bash
torch init
```

## Lifecycle Commands

### Create a Lab
```bash
torch lab create my-experiment
```

### Enter a Lab (Isolated)
Phase 2 uses `systemd-nspawn` for isolation.
```bash
torch lab enter my-experiment
```

### Reset a Lab
```bash
torch lab reset my-experiment
```

### Delete a Lab
```bash
torch lab delete my-experiment
```

### Lab Info
```bash
torch lab info my-experiment
```

### List Labs
```bash
torch lab list
```

## Example Workflow

1. Create a lab: `torch lab create test-run`
2. Enter the lab: `torch lab enter test-run`
3. Install dependencies or modify files.
4. If the environment becomes unstable, reset it: `torch lab reset test-run`
5. The lab is now clean again.
