#!/bin/bash
set -e

# /home/ubuntu must be writable (in case the volume is created by root)
sudo chown ubuntu:ubuntu /home/ubuntu 2>/dev/null || true

export DISPLAY=:0
export XDG_RUNTIME_DIR=/tmp/runtime-ubuntu
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

if [ "${FORCE_VIRTUAL_MONITOR}" = "true" ]; then
    # --- Virtual monitor (Xvfb): no GPU output, software rendering via llvmpipe ---
    # NOTE: stock X servers (Xvfb, dummy) have no DRI3, so Vulkan CANNOT present
    # here. Emulators must use OpenGL (llvmpipe) or Software backends in this mode.
    export GALLIUM_DRIVER=llvmpipe
    export LIBGL_ALWAYS_SOFTWARE=1

    Xvfb :0 -ac -screen 0 1920x1080x24 &
    for _ in $(seq 1 20); do
        xdpyinfo -display :0 >/dev/null 2>&1 && break
        sleep 0.5
    done
    if ! xdpyinfo -display :0 >/dev/null 2>&1; then
        echo "=== Xvfb failed to start ===" >&2
        exit 1
    fi

    # Default Dolphin to the OpenGL backend (Vulkan needs DRI3 = real HDMI).
    # Only applied when no backend was explicitly configured before.
    DOLPHIN_INI="$HOME/.config/dolphin-emu/Dolphin.ini"
    if ! grep -qE '^[[:space:]]*GFXBackend[[:space:]]*=' "$DOLPHIN_INI" 2>/dev/null; then
        mkdir -p "$(dirname "$DOLPHIN_INI")"
        printf '\n[Core]\nGFXBackend = OGL\n' >> "$DOLPHIN_INI"
        echo "Virtual monitor: defaulted Dolphin backend to OpenGL ($DOLPHIN_INI)"
    fi
else
    # --- Real HDMI: Xorg on /dev/dri ---
    if [ -e /dev/dri ]; then
        sudo chmod 666 /dev/dri/* 2>/dev/null || true
    fi

    sudo mkdir -p /etc/X11/xorg.conf.d
    sudo tee /etc/X11/xorg.conf.d/20-gpu.conf >/dev/null <<'EOF'
Section "Device"
    Identifier "GPU"
    Driver "modesetting"
    Option "DRI3" "true"
    Option "AccelMethod" "glamor"
EndSection
EOF

    sudo Xorg :0 -ac -logfile /tmp/Xorg.log &
    for _ in $(seq 1 20); do
        xdpyinfo -display :0 >/dev/null 2>&1 && break
        sleep 0.5
    done
    if ! xdpyinfo -display :0 >/dev/null 2>&1; then
        echo "=== Xorg failed to start. Log: ===" >&2
        tail -30 /tmp/Xorg.log >&2 || true
        exit 1
    fi
fi

# Desktop launchers
mkdir -p "$HOME/Desktop"
for f in pcsx2 dolphin-emu azahar retroarch; do
    src="/usr/share/applications/${f}.desktop"
    dst="$HOME/Desktop/${f}.desktop"
    [ -f "$src" ] || continue
    cp "$src" "$dst"
    chmod +x "$dst"
done

# VNC on display :0 (port 5900)
x11vnc -display :0 -forever -nopw -shared -rfbport 5900 &

# XFCE session
exec dbus-launch --exit-with-session startxfce4
