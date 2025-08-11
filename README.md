# Parrot / Simplex Repeater for Raspberry Pi (Zero 2W)

A tiny **software-defined simplex/parrot repeater** built in Python for Raspberry Pi.  
It records on voice activity, then plays back with an injected **CTCSS** tone, plus **pre/post beeps**.  
A clean **Web UI (Flask + Waitress)** lets you pick USB sound devices, tune VOX/VAD, adjust gains (dB), tweak tones, view real-time status/logs, reboot the Pi, and inspect network interfaces.

Repository: **https://github.com/awatchar/parrotrepeater_pi0w2/**

---

## Features

- **VOX + WebRTC VAD** (aggressiveness 0–3) for robust voice detection
- **CTCSS** injection (e.g., 150.0 Hz) with adjustable amplitude (~−26 to −20 dB of speech)
- **Pre/Post Beeps** (pleasant low tone; adjustable frequency & duration)
- **USB Soundcard selection** (Input/Output) via dropdown
- **Gains in dB**, and time parameters **in ms** (threshold timeout, beep length, etc.)
- **Real-time status box** (IDLE / RECORDING / MIXING / TX) + live text log
- **System metrics** (CPU, Memory, Disk, Temperature, Uptime)
- **Reboot** button and **Interfaces** page (all IPs)
- Optional **GPIO PTT** (BCM pin; lead-in/tail timings)
- Runs as **systemd** services; Web served by **Waitress**
- Writes rotating logs to **/dev/shm** (tmpfs) to protect the SD card

---

## Hardware

- Raspberry Pi **Zero 2W** (works on other Pis as well)
- **USB soundcard** with mic-in and line/headphone-out
- Handheld/mobile **radio** on the same frequency (simplex)
- Recommended between soundcard out and radio mic-in:
  - **Audio isolation transformer** (1:1)
  - **10–20 dB pad/attenuator**

> You can rely on the radio’s VOX or use **GPIO PTT** (with proper level shifting/optocoupler).

---

## Quick Install

```bash
git clone https://github.com/awatchar/parrotrepeater_pi0w2.git
cd parrotrepeater_pi0w2
sudo bash install.sh
```

What the installer does:

- Creates a venv at `~/parrot/venv` and installs Python deps
- Deploys:
  - `~/parrot/parrot_service.py` (audio engine)
  - `~/parrot/webui.py` (Web UI)
  - `~/parrot/config.json` (configuration)
- Creates and loads systemd services:
  - `parrot.service` — the audio engine (you start/restart it from Web UI)
  - `parrot-web.service` — Web UI via Waitress on **port 8080**
- Adds minimal sudoers rules so the Web UI can control the service and reboot the Pi
- Starts the **Web UI** immediately

Open the Web UI:
```
http://<PI-IP>:8080/
```

Find IP quickly:
```bash
hostname -I
```

---

## First Run (Recommended Settings)

1. Plug the **USB soundcard**, refresh the Web UI.
2. Select **Input** and **Output** devices from the dropdowns.
3. Start with:
   - **Threshold (RMS)**: `0.02`
   - **Timeout (ms)**: `1500`
   - **Use WebRTC VAD**: `true`, **VAD Aggressiveness**: `2`
   - **CTCSS**: `150.0` Hz, **Amplitude**: `0.05` (≈ −26…−20 dB vs speech)
   - **Pre-Beep**: `400 Hz / 120 ms`, **Post-Beep**: `400 Hz / 80 ms`
   - **Input/Output Gain (dB)**: `0.0`
4. **Save Config** → **Restart Service**.
5. Watch **Realtime Status**: you should see `VOX start`, `VOX stop`, `TX start`, `TX done`.

---

## Web UI Endpoints

| Path | Method | Description |
|---|---|---|
| `/` | GET | Main UI: devices, config, status, controls |
| `/save` | POST | Save config to `~/parrot/config.json` |
| `/service/start` `/service/stop` `/service/restart` `/service/status` | POST | Control `parrot.service` (via sudoers) |
| `/metrics` | GET (JSON) | CPU, Memory, Disk, Temp, Uptime |
| `/events?limit=N` | GET (text) | Tail of recent log (`/dev/shm/parrot_log.txt`) |
| `/state` | GET (JSON) | Current state (`IDLE/RECORDING/MIXING/TX/ERROR`) |
| `/interfaces` | GET (HTML) | All network interfaces & IPs |
| `/reboot` | POST | Reboot the Pi (via sudoers) |

---

## Configuration (`~/parrot/config.json`)

| Key | Type | Unit | Notes |
|---|---|---|---|
| `input_device_index` / `output_device_index` | int / null | – | Selected from dropdown |
| `sample_rate` | int | Hz | Default `16000` (light on CPU) |
| `frame_ms` | int | ms | Default `20` |
| `vox_mode` | str | – | `"rms"`, `"vad"`, `"hybrid"` |
| `use_webrtcvad` | bool | – | Enable/disable VAD |
| `vad_aggressiveness` | int | 0–3 | Higher = stricter |
| `threshold` | float | RMS 0..1 | RMS trigger for VOX |
| `timeout_ms` | int | ms | Silence to stop recording |
| `ctcss_hz` | float | Hz | e.g., `150.0` |
| `ctcss_amplitude` | float | linear | ~`0.04–0.07` → −26…−20 dB vs speech |
| `pre_beep_hz` / `post_beep_hz` | float | Hz | Pleasant low tones (e.g., 300–500 Hz) |
| `pre_beep_ms` / `post_beep_ms` | int | ms | Typical 80–150 ms |
| `input_gain_db` / `output_gain_db` | float | dB | Software gains |
| `use_gpio_ptt` | bool | – | If not using the radio’s VOX |
| `gpio_pin` | int | BCM | Default `18` |
| `ptt_leadin_ms` / `ptt_tail_ms` | int | ms | Key-down pre/post delays |
| `use_tmpfs` | bool | – | Write logs/last TX to `/dev/shm` |

> The Web UI reads/writes this file. You can edit it by hand if needed, then restart the service.

---

## Service Management

```bash
# Web UI service (should be running)
systemctl status parrot-web.service
journalctl -u parrot-web.service -f

# Audio engine service (start/restart it from the Web UI after selecting devices)
systemctl status parrot.service
journalctl -u parrot.service -f

# Enable on boot (optional)
sudo systemctl enable parrot-web.service
sudo systemctl enable parrot.service
```

---

## Audio Notes & Tuning

- Keep **CTCSS amplitude** modest to avoid degrading intelligibility.
- The **pre-beep** helps wake VOX on the target radio so you don’t clip the first syllable.
- Use an **isolation transformer** and **attenuator pad** to avoid ground loops and over-modulation.
- If VOX is too sensitive or not sensitive enough, adjust **Threshold**, **VAD aggressiveness**, and **input gain (dB)**.

---

## Troubleshooting

- **No audio devices appear**:
  ```bash
  arecord -l
  aplay -l
  source ~/parrot/venv/bin/activate
  python -c "import sounddevice as sd; print(sd.query_devices())"
  ```

- **Device open errors**: re-select the correct indices in the Web UI.  
- **CTCSS not decoded**: increase `ctcss_amplitude` in small steps (`+0.005`).  
- **Clicks at start/end**: slightly increase pre/post beep durations; verify cabling/isolation.  
- **High CPU** on Pi Zero 2W: keep `sample_rate=16000`, `frame_ms=20`.

---

## Security

- The Web UI runs on **port 8080**.  
  Restrict access to your LAN or place behind a reverse proxy (Caddy/NGINX) with auth if exposed.  
- Sudoers rules are limited to **service control** and **reboot** only.

---

## Uninstall

```bash
cd parrotrepeater_pi0w2
sudo bash install.sh --uninstall
# (keeps ~/parrot; remove manually if desired)
```

---

## Roadmap

- Optional basic auth for the Web UI  
- Live waveform/spectrum preview  
- ALSA mixer control via Web UI  
- Profiles for multiple channels/tones

---

## License

MIT

---

## Regulatory Note

Amateur radio regulations vary by country. Ensure licensing and compliance with local rules regarding tone access, identification, occupied bandwidth, and unattended operation.

---

## Screenshots (placeholders)

```
docs/
  screenshots/
    webui-main.png
    interfaces.png
    metrics.png
```
Add screenshots to the paths above and reference them here:

- Main UI: ![Main UI](docs/screenshots/webui-main.png)  
- Interfaces: ![Interfaces](docs/screenshots/interfaces.png)  
- Metrics: ![Metrics](docs/screenshots/metrics.png)
