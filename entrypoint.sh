#!/bin/bash
set -e

# /home/ubuntu must be writable (in case the volume is created by root)
sudo chown ubuntu:ubuntu /home/ubuntu 2>/dev/null || true

export DISPLAY=:0
export XDG_RUNTIME_DIR=/tmp/runtime-ubuntu
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

if [ "${FORCE_VIRTUAL_MONITOR}" = "true" ]; then
    # --- Virtual monitor (Xvfb) ---
    # Prefer the DRI3-capable patched Xvfb on the GPU render node (render nodes
    # need no DRM master, so this coexists with the host desktop). Fall back to
    # stock Xvfb + llvmpipe software rendering (no Vulkan presentation there:
    # stock X servers have no DRI3, and Dolphin's OpenGL backend is EGL-only).
    export GALLIUM_DRIVER=llvmpipe
    export LIBGL_ALWAYS_SOFTWARE=1
    DRINODE="${DRINODE:-/dev/dri/renderD128}"

    XVFB_BIN="Xvfb"
    if [ -x /usr/local/bin/Xvfb-patched ] && [ -e "$DRINODE" ] \
        && /usr/local/bin/Xvfb-patched -help 2>&1 | grep -q 'vfbdevice'; then
        XVFB_BIN="/usr/local/bin/Xvfb-patched"
        # Real GPU behind the virtual screen: unset software fallbacks so
        # hardware backends (including Vulkan) are used.
        unset GALLIUM_DRIVER LIBGL_ALWAYS_SOFTWARE
        XVFB_DRI="-vfbdevice $DRINODE"
        echo "Virtual monitor: patched Xvfb with DRI3 on $DRINODE"
    else
        XVFB_DRI=""
        echo "Virtual monitor: stock Xvfb (software rendering, Vulkan cannot present)"
        # Default Dolphin to the OpenGL backend (Vulkan needs DRI3 = GPU X server).
        # Only applied when no backend was explicitly configured before.
        DOLPHIN_INI="$HOME/.config/dolphin-emu/Dolphin.ini"
        if ! grep -qE '^[[:space:]]*GFXBackend[[:space:]]*=' "$DOLPHIN_INI" 2>/dev/null; then
            mkdir -p "$(dirname "$DOLPHIN_INI")"
            printf '\n[Core]\nGFXBackend = OGL\n' >> "$DOLPHIN_INI"
            echo "Virtual monitor: defaulted Dolphin backend to OpenGL ($DOLPHIN_INI)"
        fi
    fi

    # shellcheck disable=SC2086
    $XVFB_BIN :0 -ac -screen 0 1920x1080x24 \
        +extension COMPOSITE +extension DAMAGE +extension GLX +extension RANDR \
        +extension RENDER +extension MIT-SHM +extension XFIXES +extension XTEST \
        -iglx +render -nolisten tcp -noreset -shmem $XVFB_DRI &
    for _ in $(seq 1 20); do
        xdpyinfo -display :0 >/dev/null 2>&1 && break
        sleep 0.5
    done
    if ! xdpyinfo -display :0 >/dev/null 2>&1; then
        echo "=== Xvfb failed to start ===" >&2
        exit 1
    fi
    xdpyinfo -display :0 2>/dev/null | grep -iE 'DRI3|Present' || true
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

# --- Audio HDMI (ALSA): desmutear salidas digitales y fijar TV por defecto ---
# Tu TV es card 0 device 7 ("HDMI 1 [HAIER TV]"). En HDMI no hay control
# "Master", solo IEC958 (uno por salida 3/7/8/9 = 0/1/2/3). Vienen en [off].
for _c in 0 1 2 3; do
    amixer -c0 sset "IEC958",${_c} unmute 2>/dev/null || true
done
sudo tee /etc/asound.conf >/dev/null <<'EOF'
defaults.pcm.card 0
defaults.pcm.device 7
defaults.ctl.card 0
EOF

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
