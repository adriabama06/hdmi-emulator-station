# ============================================================
# 1. Base: HDMI + X11 + XFCE + default user 1000:1000
# ============================================================
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    TZ=Europe/Madrid \
    APPIMAGE_EXTRACT_AND_RUN=1

# 1.1 Essentials: GPU/HDMI, input (controllers), X11, lightweight XFCE, VNC
RUN apt-get update && apt-get install -y --no-install-recommends \
        sudo ca-certificates curl wget jq \
        locales tzdata \
        mesa-utils libgl1 libglx-mesa0 libegl1 libgles2 libopengl0 \
        libegl-mesa0 libgl1-mesa-dri libgbm1 \
        mesa-vulkan-drivers libvulkan1 vulkan-tools \
        xserver-xorg-video-all xserver-xorg-input-all \
        x11-xserver-utils xinit x11-utils x11-xkb-utils \
        xfce4 xfce4-terminal dbus-x11 \
        x11vnc xvfb \
        xdg-utils desktop-file-utils \
        hicolor-icon-theme adwaita-icon-theme \
        alsa-utils pulseaudio-utils \
        joystick jstest-gtk evtest \
        unzip p7zip-full \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

# 1.2 Default user "ubuntu" 1000:1000 with /home/ubuntu
# Ubuntu 24.04 ships 'ubuntu' (UID 1000) and a system 'games' user: remove the latter
RUN (userdel games 2>/dev/null || true) && \
    (groupdel games 2>/dev/null || true) && \
    usermod -aG sudo ubuntu && \
    echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ubuntu && \
    chmod 0440 /etc/sudoers.d/ubuntu

# 1.3 Desktop launchers (copied to ~/Desktop at startup)
COPY launchers/ /usr/share/applications/
RUN update-desktop-database /usr/share/applications

# 1.4 Patched Xvfb with DRI3/GLAMOR (LinuxServer, Ubuntu 24.04 build).
# Single-binary copy: the rest of their rootfs is NOT needed (same distro,
# same SONAMEs). If this image/tag ever disappears, delete this COPY line and
# the entrypoint automatically falls back to stock Xvfb (software rendering).
COPY --from=lscr.io/linuxserver/xvfb:ubuntunoble /usr/bin/Xvfb /usr/local/bin/Xvfb-patched

# ============================================================
# 2. PS2 Emulator - PCSX2 (AppImage)
# ============================================================
RUN url=$(curl -fsSL "https://api.github.com/repos/PCSX2/pcsx2/releases" \
        | jq -er '[.[].assets[] | select(.name | test("linux-appimage-x64.*\\.AppImage$"))][0].browser_download_url') \
    && curl -fsSL -o /opt/pcsx2.AppImage "$url" \
    && chmod +x /opt/pcsx2.AppImage \
    && ln -sf /opt/pcsx2.AppImage /usr/local/bin/pcsx2

# ============================================================
# 3. Wii / GameCube Emulator - Dolphin (AppImage)
# ============================================================
RUN url=$(curl -fsSL "https://api.github.com/repos/pkgforge-dev/Dolphin-emu-AppImage/releases" \
        | jq -er '[.[].assets[] | select(.name | test("x86_64\\.AppImage$"))][0].browser_download_url') \
    && curl -fsSL -o /opt/dolphin.AppImage "$url" \
    && chmod +x /opt/dolphin.AppImage \
    && ln -sf /opt/dolphin.AppImage /usr/local/bin/dolphin-emu

# ============================================================
# 4. 3DS Emulator - Azahar (AppImage)
# ============================================================
RUN curl -fsSL -o /opt/azahar.AppImage \
        "https://github.com/azahar-emu/azahar/releases/latest/download/azahar.AppImage" \
    && chmod +x /opt/azahar.AppImage \
    && ln -sf /opt/azahar.AppImage /usr/local/bin/azahar

# ============================================================
# 5. RetroArch + cores
# ============================================================
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        retroarch \
        libretro-core-info \
        libretro-beetle-psx \
        libretro-nestopia \
        libretro-snes9x \
        libretro-genesisplusgx \
        libretro-mgba \
        libretro-gambatte \
    && rm -rf /var/lib/apt/lists/*

# ============================================================
# 6. Device permissions
# ============================================================
RUN usermod -aG video,audio ubuntu && \
    (getent group input >/dev/null && usermod -aG input ubuntu || true) && \
    (getent group render >/dev/null && usermod -aG render ubuntu || true)

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# ============================================================
# 7. Final build
# ============================================================
WORKDIR /home/ubuntu
USER ubuntu
ENV HOME=/home/ubuntu
EXPOSE 5900
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
