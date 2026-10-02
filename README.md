# hdmi-emulator-station

A single container with Ubuntu + lightweight XFCE that **outputs directly via HDMI from the server's GPU**
(Xorg on `/dev/dri`, no virtual screen), with the host controllers passed through
and remote access via VNC for when you don't have a keyboard/mouse plugged in.

Comes with:

| Emulator | System | Format |
|---|---|---|
| PCSX2 | PlayStation 2 | AppImage |
| Dolphin (`pkgforge-dev`) | Wii / GameCube | AppImage |
| Azahar | Nintendo 3DS | AppImage |
| RetroArch | PSX, SNES, NES, GB/GBA, ... | package + cores |

All emulators write their config to `~/` (`~/.config/PCSX2`, `~/.config/dolphin-emu`,
`~/.config/azahar`, `~/.config/retroarch`), and compose mounts `./data:/home/ubuntu`, so
**everything (configs, BIOS, ROMs, saves) stays in `./data` on the host**.

---

## Usage

```bash
mkdir -p data          # important: create it first, otherwise Docker creates it as root
docker compose up -d --build
docker compose logs -f          # here you can see if Xorg started correctly
```

- **TV via HDMI**: it's the real output of the container, nothing to configure.
- **VNC** (for mouse/keyboard): `vnc://SERVER_IP:5910` — inside the container it listens on 5900.
- **Inside the container**: `pcsx2`, `dolphin-emu`, `azahar`, `retroarch`.
- **Desktop**: there are launchers for the 4 emulators (generated in `~/Desktop` at startup).

### Virtual monitor mode (no HDMI)

To test via VNC without having the TV plugged in (or while the GPU is used by something else),
set in `compose.yml`:

```yaml
environment:
  - FORCE_VIRTUAL_MONITOR=true
```

This starts an **Xvfb** (1920x1080) instead of Xorg on the GPU: the full desktop
is still visible via VNC, regardless of whether HDMI is connected or not.

### Where to put games and BIOS

Everything you place in `./data` appears inside at `/home/ubuntu`:

```
./data/.config/PCSX2/          PCSX2 config
./data/.config/dolphin-emu/    Dolphin config
./data/.config/azahar/         Azahar config (+ keys)
./data/.config/retroarch/      RetroArch config
./data/roms/                   your ROMs/ISOs here (create the folder)
./data/bios/                   PS2 BIOS, etc.
./data/Desktop/                emulator launchers (regenerated automatically)
```

---

## Host requirements

1. **The GPU must be free**: if you have a display manager (GDM, LightDM) or a host Xorg
   using the GPU, Xorg inside the container won't be able to take control.
2. Check the GIDs of `render` and `input` on your host and adjust them if they differ:

   ```bash
   getent group render input
   ```

   They are in `group_add` in `compose.yml` (993 and 995 by default).
3. **NVIDIA**: uncomment the `gpus: all` block in `compose.yml` and make sure you have
   `nvidia-container-toolkit` on the host. With NVIDIA there is no `/dev/fb0` (not needed).

### If the TV stays black

The entrypoint prints the end of `/tmp/Xorg.log` when Xorg fails. To check it manually:

```bash
docker compose exec hdmi-emulator cat /tmp/Xorg.log
docker compose exec hdmi-emulator sudo chmod 666 /dev/dri/*   # permissions
```

Try first with `FORCE_VIRTUAL_MONITOR=true`: if it looks good via VNC, the problem is
the GPU/HDMI; if it doesn't show either, it's the container.

If your GPU needs a different driver, create the file on the host and mount it:

```yaml
volumes:
  - ./xorg.conf:/etc/X11/xorg.conf.d/20-hdmi.conf:ro
```

---

## Notes

- `APPIMAGE_EXTRACT_AND_RUN=1` is set because AppImages can't use FUSE inside Docker.
- RetroArch cores for **N64 and hardware-accelerated PSX** are not packaged in
  Ubuntu 24.04; they can be downloaded from RetroArch → *Online Updater* → *Core Downloader*.
- `privileged: true` is what allows Xorg to take the GPU and adjust `/dev/*` permissions.
