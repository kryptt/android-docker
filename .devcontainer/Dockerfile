FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Kernel build dependencies
RUN apt-get update && apt-get install -y \
    bc \
    bison \
    build-essential \
    ccache \
    curl \
    flex \
    git \
    gnupg \
    gperf \
    imagemagick \
    lib32readline-dev \
    lib32z1-dev \
    libelf-dev \
    liblz4-tool \
    libncurses5-dev \
    libsdl1.2-dev \
    libssl-dev \
    libxml2 \
    libxml2-utils \
    lzop \
    pngcrush \
    rsync \
    schedtool \
    squashfs-tools \
    xsltproc \
    zip \
    zlib1g-dev \
    python3 \
    python-is-python3 \
    cpio \
    kmod \
    # USB / Android device tools
    android-tools-adb \
    android-tools-fastboot \
    usbutils \
    udev \
    # Development tools
    wget \
    unzip \
    sudo \
    openssh-client \
    less \
    vim \
    ripgrep \
    fd-find \
    jq \
    # Claude Code dependency
    nodejs \
    npm \
    && rm -rf /var/lib/apt/lists/*

# Install latest platform-tools for up-to-date adb/fastboot
RUN curl -fsSL https://dl.google.com/android/repository/platform-tools-latest-linux.zip -o /tmp/platform-tools.zip \
    && unzip /tmp/platform-tools.zip -d /opt \
    && rm /tmp/platform-tools.zip

ENV PATH="/opt/platform-tools:${PATH}"

# udev rules for common Android/OnePlus USB IDs
RUN mkdir -p /etc/udev/rules.d
COPY 51-android.rules /etc/udev/rules.d/51-android.rules

# Create non-root user with sudo
ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=1000
RUN groupadd --gid $USER_GID $USERNAME \
    && useradd --uid $USER_UID --gid $USER_GID -m -s /bin/bash $USERNAME \
    && echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/$USERNAME \
    && chmod 0440 /etc/sudoers.d/$USERNAME

# Add user to plugdev for USB device access
RUN groupadd -f plugdev && usermod -aG plugdev $USERNAME

USER $USERNAME
WORKDIR /home/$USERNAME

CMD ["bash"]
