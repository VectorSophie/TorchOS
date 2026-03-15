FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    btrfs-progs \
    curl \
    git \
    vim \
    tmux \
    python3 \
    docker.io \
    build-essential \
    pkg-config \
    libssl-dev \
    qemu-system-x86 \
    systemd-container \
    cinnamon \
    lightdm \
    python3-gi \
    gir1.2-gtk-3.0 \
    gnome-terminal \
    && rm -rf /var/lib/apt/lists/*

COPY assets/logo.png /usr/share/torch/logo.png
COPY ui/torch-labs.desktop /usr/share/applications/torch-labs.desktop
COPY ui/src/torch-labs-gui.py /usr/local/bin/torch-labs-gui.py
RUN chmod +x /usr/local/bin/torch-labs-gui.py

RUN mkdir -p /usr/share/themes/torch-theme
COPY ui/theme/ /usr/share/themes/torch-theme/

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

RUN mkdir -p /torch/labs /torch/snapshots /torch/base-lab \
    /torch-data/models /torch-data/datasets /torch-data/results

WORKDIR /build/torch-cli
COPY torch-cli/ .
RUN cargo build --release && \
    cp target/release/torch-cli /usr/local/bin/torch

WORKDIR /root
CMD ["/bin/bash"]
