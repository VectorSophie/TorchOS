# Datasets and Models

Torch OS maintains persistence for research data across disposable lab environments.

## Storage Paths

- **Datasets**: `/torch-data/datasets`
- **Models**: `/torch-data/models`

## Usage in Labs

When you enter a lab via `torch lab enter <name>`, the persistent directories are automatically bound into the container:

| Host Path | Lab Internal Path |
|-----------|-------------------|
| `/torch-data/datasets` | `/data/datasets` |
| `/torch-data/models` | `/data/models` |

## Management

### List Datasets
```bash
torch dataset list
```

### List Models
```bash
torch model list
```

Any data written to `/data/datasets` or `/data/models` while inside a lab will persist even after the lab is reset or deleted.
