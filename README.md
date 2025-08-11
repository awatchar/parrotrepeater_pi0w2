# Parrot / Simplex Repeater for Raspberry Pi (Zero 2W)

A tiny **software-defined simplex/parrot repeater** for Raspberry Pi (Zero 2W or newer).  
It records on voice activity, then plays back with injected **CTCSS**, **pre/post beeps**, and now includes:

- **Optional Basic Auth** (PAM) — use your Pi username/password
- **Live waveform & spectrum** preview in the Web UI
- **ALSA mixer control** from the browser
- **Profiles** — save/apply multiple configuration sets

Repository: **https://github.com/awatchar/parrotrepeater_pi0w2/**

---

## Features

- **VOX + WebRTC VAD** (aggressiveness 0–3) for robust voice detection
- **CTCSS** injection (e.g., 150.0 Hz) with adjustable amplitude (~−26 to −20 dB of speech)
- **Pre/Post Beeps** (pleasant low tone; adjustable frequency & duration)
- **USB Soundcard selection** (Input/Output) via dropdown
- **Gains in dB**, time constants **in ms**
- **Realtime status** (IDLE / RECORDING / MIXING / TX) + live log
- **Live** waveform/spectrum (canvas) updated ~10 fps
- **ALSA mixer**: list simple controls and set volumes/mute
- **Profiles**: save/apply/delete configs; apply triggers service restart
- **Reboot button** and **Interfaces** page (all IPs)
- Runs as **systemd** services; Web served by **Waitress**
- Logs/state live in **/dev/shm** (tmpfs) to protect SD

---

## Hardware

- Raspberry Pi **Zero 2W** (works on other Pis as well)
- **USB soundcard** with mic-in and line/headphone-out
- Handheld/mobile **radio** on the same frequency (simplex)
- Recommended between soundcard out and radio mic-in:
  - **Audio isolation transformer** (1:1)
  - **10–20 dB pad/attenuator**

> Use the radio’s VOX or GPIO PTT (with proper interface).

---

## Quick Install

```bash
git clone https://github.com/awatchar/parrotrepeater_pi0w2.git
cd parrotrepeater_pi0w2
sudo bash install.sh
```

Installer will:
- Create `~/parrot/venv` and install Python deps: `sounddevice`, `webrtcvad`, `flask`, `waitress`, `psutil`, `python-pam`
- Deploy `parrot_service.py` (with visualization) and `webui.py` (auth/mixer/profiles)
- Create systemd units:
  - `parrot.service` — audio engine
  - `parrot-web.service` — Web UI on **port 8080**
- Add minimal sudoers for service control & reboot
- Start the **Web UI** immediately

Open the Web UI:
```
http://<PI-IP>:8080/
```

Find IP quickly:
```bash
hostname -I
```

---

## First Run

1. Plug the **USB soundcard** and refresh the Web UI.  
2. Pick **Input** and **Output** devices.  
3. Start with these values:
   - **Threshold (RMS)**: `0.02`
   - **Timeout (ms)**: `1500`
   - **Use WebRTC VAD**: `true`, **Aggressiveness**: `2`
   - **CTCSS**: `150.0` Hz, **Amplitude**: `0.05` (≈ −26…−20 dB vs speech)
   - **Pre-Beep**: `400 Hz / 120 ms`, **Post-Beep**: `400 Hz / 80 ms`
   - **Input/Output Gain (dB)**: `0.0`
4. **Save Config** → **Restart Service**.  
5. In **Realtime Status**, watch `VOX start/stop`, `TX start/done`.

---

## Web UI Endpoints

| Path | Method | Description |
|---|---|---|
| `/` | GET | Main UI: devices, config, status, visualization |
| `/save` | POST | Save config to `~/parrot/config.json` |
| `/service/start` `/service/stop` `/service/restart` `/service/status` | POST | Control `parrot.service` |
| `/metrics` | GET (JSON) | CPU, Memory, Disk, Temp, Uptime |
| `/events?limit=N` | GET (text) | Tail of `/dev/shm/parrot_log.txt` |
| `/state` | GET (JSON) | Current state |
| `/vis` | GET (JSON) | Waveform & spectrum snapshot |
| `/interfaces` | GET (HTML) | All network interfaces/IPs |
| `/reboot` | POST | Reboot the Pi |
| `/alsa/controls?card=N` | GET | List mixer controls via `amixer` |
| `/alsa/get?card=N&name=PCM` | GET | Get volume/mute |
| `/alsa/set` | POST (JSON) | Set volume (`value` 0–100) and/or `mute` |
| `/profiles/list` | GET | List profile names |
| `/profiles/save` | POST (JSON) | Save current config as a profile |
| `/profiles/apply` | POST (JSON) | Apply a profile and restart service |
| `/profiles/delete` | POST (JSON) | Delete a profile |

---

## Configuration (`~/parrot/config.json`)

| Key | Type | Unit | Notes |
|---|---|---|---|
| `input_device_index` / `output_device_index` | int / null | – | Selected from dropdown |
| `sample_rate` | int | Hz | Default `16000` |
| `frame_ms` | int | ms | Default `20` |
| `vox_mode` | str | – | `"rms"`, `"vad"`, `"hybrid"` |
| `use_webrtcvad` | bool | – | Enable/disable VAD |
| `vad_aggressiveness` | int | 0–3 | Higher = stricter |
| `threshold` | float | RMS 0..1 | VOX trigger |
| `timeout_ms` | int | ms | Silence to stop recording |
| `ctcss_hz` | float | Hz | e.g., `150.0` |
| `ctcss_amplitude` | float | linear | ~`0.04–0.07` → −26…−20 dB vs speech |
| `pre_beep_hz` / `post_beep_hz` | float | Hz | Low, pleasant tones |
| `pre_beep_ms` / `post_beep_ms` | int | ms | 80–150 typical |
| `input_gain_db` / `output_gain_db` | float | dB | Software gains |
| `use_gpio_ptt` | bool | – | If not using radio VOX |
| `gpio_pin` | int | BCM | Default `18` |
| `ptt_leadin_ms` / `ptt_tail_ms` | int | ms | Key-down pre/post |
| `use_tmpfs` | bool | – | Use `/dev/shm` for logs/last TX |
| `auth_enabled` | bool | – | Enable Basic Auth (PAM) |
| `auth_allowed_users` | list | – | Whitelist; empty = any user |
| `vis_enabled` | bool | – | Toggle waveform/spectrum |
| `vis_fps` | int | fps | Visualization update rate |
| `vis_fft_n` | int | samples | FFT size (e.g., 1024) |

> Edit by hand if needed and **restart** the service.

---

## ALSA Mixer Notes

- Enter your **card index** (often `0`), click **Load Controls**.  
- Use sliders to set volumes; some cards expose `PCM`, `Speaker`, `Headphone`, `Capture`, `Mic`, `Mic Boost`, etc.  
- Commands are executed via `amixer` under the hood.

---

## Basic Auth (PAM)

- Toggle **Enable Basic Auth** in the UI.  
- **Allowed Users** limits who can login (comma-separated). Leave empty to allow any valid PAM user.  
- Uses PAM service `login`. If your system only accepts `sudo`, change one line:  
  ```bash
  sudo sed -i "s/service='login'/service='sudo'/" ~/parrot/webui.py
  sudo systemctl restart parrot-web.service
  ```

---

## Service Management

```bash
systemctl status parrot-web.service
journalctl -u parrot-web.service -f

systemctl status parrot.service
journalctl -u parrot.service -f

# Enable on boot (optional)
sudo systemctl enable parrot-web.service
sudo systemctl enable parrot.service
```

---

## Troubleshooting

- **No audio devices appear**:
  ```bash
  arecord -l
  aplay -l
  source ~/parrot/venv/bin/activate
  python -c "import sounddevice as sd; print(sd.query_devices())"
  ```
- **CTCSS not decoded** → raise `ctcss_amplitude` in small steps (`+0.005`).  
- **First syllable clipped** → increase pre-beep duration a bit.  
- **High CPU** on Pi Zero 2W → keep `sample_rate=16000`, `frame_ms=20`.  
- **Basic Auth fails**: ensure the venv has `python-pam` and your user has a password (`sudo passwd <user>`).

---

## Security

- Web UI is on **port 8080**. Restrict to LAN or place behind a reverse proxy with HTTPS/auth if exposed.  
- Sudoers allow **only** service control and reboot.

---

## Uninstall

```bash
cd parrotrepeater_pi0w2
sudo bash install.sh --uninstall
# (keeps ~/parrot; remove manually if desired)
```

---

## License

MIT (recommended). Add a LICENSE file if you choose MIT or another license.

---

## Regulatory Note

Amateur radio regulations vary by country. Ensure you’re licensed and compliant with local rules (tone access, ID, BW, unattended operation).
