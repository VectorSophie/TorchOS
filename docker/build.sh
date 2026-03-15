#!/bin/bash
set -e

docker build -t torch-os:latest -f docker/Dockerfile .

echo "Docker image built successfully: torch-os:latest"
