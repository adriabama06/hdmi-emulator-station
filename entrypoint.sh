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

# --- Audio HDMI (ALSA + PulseAudio): detectar TV, desmutear, mezclar y loguear ---
# Por qué Dolphin se quedaba mudo y PCSX2 no:
# - PCSX2 usa Cubeb con dispositivo "default" y le bastaba con
#   defaults.pcm.card/device + IEC958 desmuteado.
# - Dolphin por defecto también usa Cubeb, pero su Cubeb intenta hablar con un
#   servidor PulseAudio/PipeWire y en este contenedor no había ninguno corriendo
#   (solo estaban los clientes pulseaudio-utils). Sin servidor, Cubeb/Pulse no
#   suenan aunque el backend ALSA esté compilado. De ahí que no sonara "con
#   ninguno de los backends".
# La solución es un mezclador PulseAudio como dueño único del hw HDMI y que
# todo (ALSA/Cubeb/Pulse) pase por él, con fallback a ALSA directo con dmix si
# Pulse no arranca. Se permite forzar con HDMI_CARD / HDMI_DEVICE.
HDMI_CARD="${HDMI_CARD:-0}"
if [ -z "${HDMI_DEVICE:-}" ]; then
    HDMI_DEVICE="$(aplay -l 2>/dev/null \
        | grep -m1 -E "^card ${HDMI_CARD}:.*device [0-9]+:.*HDMI" \
        | sed -E 's/.*device ([0-9]+):.*/\1/')"
    HDMI_DEVICE="${HDMI_DEVICE:-7}"
fi
echo "Audio HDMI: card $HDMI_CARD device $HDMI_DEVICE"
aplay -l 2>&1 | head -n 20 || true

# Desmutear salidas digitales HDMI (IEC958 0..3 = dispositivos 3/7/8/9) y
# controles analógicos por si existen. Antes de que Pulse capture el hw.
for _c in 0 1 2 3; do
    amixer -c"$HDMI_CARD" sset "IEC958",${_c} unmute 2>/dev/null || true
done
amixer -c"$HDMI_CARD" sset Master unmute 2>/dev/null || true
amixer -c"$HDMI_CARD" sset PCM 100% unmute 2>/dev/null || true
amixer -c"$HDMI_CARD" scontents 2>&1 | head -n 30 || true

# Arrancar PulseAudio como demonio de usuario (dueño único de hw:X,Y).
# Sin esto, los backends Cubeb/Pulse de Dolphin no tienen servidor al que
# conectarse y se quedan mudos.
PULSE_OK=false
if command -v pulseaudio >/dev/null 2>&1; then
    mkdir -p "$HOME/.config/pulse"
    chmod 700 "$HOME/.config/pulse" 2>/dev/null || true
    # Desactivar respawn automático dentro del contenedor para un arranque limpio.
    printf 'autospawn = no\n' > "$HOME/.config/pulse/client.conf" 2>/dev/null || true
    if pulseaudio --start --exit-idle-time=-1 2>&1 || true; then
        for _i in $(seq 1 10); do
            pactl info >/dev/null 2>&1 && break
            sleep 0.5
        done
    fi
    if pactl info >/dev/null 2>&1; then
        # Asegurar un sink ALSA sobre el HDMI si udev no lo creó solo.
        if ! pactl list short sinks 2>/dev/null | grep -q .; then
            pactl load-module module-alsa-sink "device=hw:${HDMI_CARD},${HDMI_DEVICE}" sink_properties=device.description=HDMI 2>/dev/null || true
            sleep 1
        fi
        HDMI_SINK="$(pactl list short sinks 2>/dev/null | grep -m1 -i -E "alsa|hdmi" | awk '{print $2}')"
        HDMI_SINK="${HDMI_SINK:-$(pactl list short sinks 2>/dev/null | head -n1 | awk '{print $2}')}"
        if [ -n "$HDMI_SINK" ]; then
            pactl set-default-sink "$HDMI_SINK" 2>/dev/null || true
            pactl set-sink-mute "$HDMI_SINK" 0 2>/dev/null || true
            pactl set-sink-volume "$HDMI_SINK" 100% 2>/dev/null || true
        fi
        echo "--- pactl info ---"
        pactl info 2>&1 | head -n 20 || true
        echo "--- pactl sinks ---"
        pactl list short sinks 2>&1 || true
        PULSE_OK=true
    else
        echo "PulseAudio no arrancó; se usará ALSA directo con dmix." >&2
    fi
else
    echo "pulseaudio no instalado; se usará ALSA directo con dmix." >&2
fi

if [ "$PULSE_OK" = true ]; then
    # Todo el audio (ALSA/Cubeb/Pulse) pasa por el mezclador Pulse.
    sudo tee /etc/asound.conf >/dev/null <<'EOF'
pcm.!default { type pulse }
ctl.!default { type pulse }
EOF
else
    # ALSA directo con mezcla por software (varias apps a la vez) y
    # re-muestreo a 48 kHz, que es lo que esperan los HDMI.
    sudo tee /etc/asound.conf >/dev/null <<EOF
pcm.!default {
    type plug
    slave.pcm "hdmi_mix"
}
pcm.hdmi_mix {
    type dmix
    ipc_key 1024
    ipc_perm 0666
    slave {
        pcm "hw:${HDMI_CARD},${HDMI_DEVICE}"
        rate 48000
        format S16_LE
        channels 2
        period_time 0
        period_size 1024
        buffer_size 8192
    }
}
ctl.!default { type hw card ${HDMI_CARD} }
defaults.pcm.card ${HDMI_CARD}
defaults.pcm.device ${HDMI_DEVICE}
defaults.ctl.card ${HDMI_CARD}
EOF
fi
echo "--- /etc/asound.conf ---"
cat /etc/asound.conf 2>&1 || true
echo "--- speaker-test HDMI (5s, debe oírse en la TV) ---"
timeout 5 speaker-test -c2 -D default -t wav 2>&1 | head -n 15 || true

# Defaults sanos de Dolphin: Cubeb (recomendado, tira de Pulse si lo hay y de
# ALSA si no) a volumen 100. Solo se aplican si el usuario no eligió backend,
# para no pisar su configuración manual.
DOLPHIN_INI="$HOME/.config/dolphin-emu/Dolphin.ini"
mkdir -p "$(dirname "$DOLPHIN_INI")"
touch "$DOLPHIN_INI"
if ! grep -qE '^[[:space:]]*Backend[[:space:]]*=' "$DOLPHIN_INI" 2>/dev/null; then
    if grep -q '^\[DSP\]' "$DOLPHIN_INI" 2>/dev/null; then
        sed -i '/^\[DSP\]/a Backend = Cubeb' "$DOLPHIN_INI"
    else
        printf '\n[DSP]\nBackend = Cubeb\n' >> "$DOLPHIN_INI"
    fi
    echo "Dolphin: backend de audio por defecto -> Cubeb ($DOLPHIN_INI)"
fi
if ! grep -qE '^[[:space:]]*Volume[[:space:]]*=' "$DOLPHIN_INI" 2>/dev/null; then
    if grep -q '^\[DSP\]' "$DOLPHIN_INI" 2>/dev/null; then
        sed -i '/^\[DSP\]/a Volume = 100' "$DOLPHIN_INI"
    else
        printf '\n[DSP]\nVolume = 100\n' >> "$DOLPHIN_INI"
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
