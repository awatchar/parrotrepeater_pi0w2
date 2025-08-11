#!/usr/bin/env bash
# Parrot/ Simplex Repeater Installer for Raspberry Pi OS (Bookworm)
# - Sets up Python venv, dependencies
# - Deploys parrot_service.py + webui.py + config.json
# - Creates systemd services (parrot.service, parrot-web.service)
# - Grants sudoers for service control + reboot from Web UI
# Usage:
#   bash install.sh            # install / update
#   bash install.sh --uninstall  # remove services/files/sudoers (keeps ~/parrot by default)

set -euo pipefail

APP_USER="${SUDO_USER:-$USER}"
HOME_DIR="$(getent passwd "$APP_USER" | cut -d: -f6)"
PARROT_DIR="$HOME_DIR/parrot"
VENV_DIR="$PARROT_DIR/venv"
PYBIN="$VENV_DIR/bin/python"
PIPBIN="$VENV_DIR/bin/pip"
WEB_PORT="${WEB_PORT:-8080}"

SERVICE_PARROT="parrot.service"
SERVICE_WEB="parrot-web.service"

# Colors
c_ok="\033[1;32m"; c_warn="\033[1;33m"; c_err="\033[1;31m"; c_off="\033[0m"

msg() { echo -e "${c_ok}==>${c_off} $*"; }
warn(){ echo -e "${c_warn}[!]${c_off} $*"; }
err() { echo -e "${c_err}[x]${c_off} $*" >&2; }

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    err "Please run as root (sudo bash install.sh)"; exit 1
  fi
}

# -------- Uninstall mode --------
if [[ "${1:-}" == "--uninstall" ]]; then
  require_root
  systemctl stop "$SERVICE_PARROT" 2>/dev/null || true
  systemctl stop "$SERVICE_WEB" 2>/dev/null || true
  systemctl disable "$SERVICE_PARROT" 2>/dev/null || true
  systemctl disable "$SERVICE_WEB" 2>/dev/null || true
  rm -f /etc/systemd/system/"$SERVICE_PARROT"
  rm -f /etc/systemd/system/"$SERVICE_WEB"
  rm -f /etc/sudoers.d/parrot
  rm -f /etc/sudoers.d/parrot-reboot
  systemctl daemon-reload
  systemctl reset-failed || true
  msg "Services and sudoers removed."
  warn "Leaving $PARROT_DIR in place. Remove manually if desired:"
  echo "  rm -rf \"$PARROT_DIR\""
  exit 0
fi

require_root

# -------- APT dependencies --------
msg "Installing system packages…"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y \
  python3 python3-venv python3-dev build-essential libffi-dev \
  alsa-utils ffmpeg libportaudio2 \
  python3-numpy

# -------- Create project structure --------
msg "Preparing project directory at $PARROT_DIR"
mkdir -p "$PARROT_DIR"
chown -R "$APP_USER":"$APP_USER" "$PARROT_DIR"

# -------- Python venv --------
if [[ ! -x "$PYBIN" ]]; then
  msg "Creating virtualenv with system-site-packages (to reuse apt numpy)…"
  sudo -u "$APP_USER" python3 -m venv --system-site-packages "$VENV_DIR"
fi

msg "Installing Python deps in venv…"
sudo -u "$APP_USER" "$PIPBIN" install --upgrade pip setuptools wheel
sudo -u "$APP_USER" "$PIPBIN" install sounddevice webrtcvad flask waitress psutil

# -------- Deploy parrot_service.py --------
msg "Writing parrot_service.py"
sudo -u "$APP_USER" tee "$PARROT_DIR/parrot_service.py" >/dev/null <<'PY'
#!/usr/bin/env python3
import json, os, time, math, queue, wave
import numpy as np
import sounddevice as sd
from datetime import datetime

# Optional VAD
try:
    import webrtcvad
except Exception:
    webrtcvad = None

CFG_PATH   = os.path.expanduser('~/parrot/config.json')
LOG_PATH   = '/dev/shm/parrot_log.txt'   # RAM log
STATE_PATH = '/dev/shm/parrot_state.json'
MAX_LOG_BYTES = 512*1024

def nowts(): return datetime.now().strftime('%Y-%m-%d %H:%M:%S')

def rotate_log_if_needed():
    try:
        if os.path.exists(LOG_PATH) and os.path.getsize(LOG_PATH) > MAX_LOG_BYTES:
            with open(LOG_PATH, 'rb') as f:
                data = f.read()[-(MAX_LOG_BYTES//2):]
            with open(LOG_PATH, 'wb') as f:
                f.write(data)
    except Exception:
        pass

def write_state(state):
    try:
        with open(STATE_PATH, 'w') as f:
            json.dump({"state": state, "ts": nowts()}, f)
    except Exception:
        pass

def log_event(msg, state=None):
    try:
        rotate_log_if_needed()
        with open(LOG_PATH, 'a') as f:
            f.write(f"[{nowts()}] {msg}\n")
    except Exception:
        pass
    if state is not None:
        write_state(state)

def db_to_gain(db): return float(10 ** (db / 20.0))

def ensure_cfg(defaults):
    if not os.path.exists(CFG_PATH):
        os.makedirs(os.path.dirname(CFG_PATH), exist_ok=True)
        with open(CFG_PATH, 'w') as f: json.dump(defaults, f, indent=2)

def load_cfg():
    defaults = {
        "input_device_index": None,
        "output_device_index": None,
        "sample_rate": 16000,
        "frame_ms": 20,
        "vox_mode": "hybrid",      # "rms" | "vad" | "hybrid"
        "use_webrtcvad": True,
        "vad_aggressiveness": 2,
        "threshold": 0.02,         # RMS 0..1
        "timeout_ms": 1500,        # ms of silence to stop
        "ctcss_hz": 150.0,
        "ctcss_amplitude": 0.05,   # ~0.04–0.07 ≈ −26…−20 dB
        "pre_beep_hz": 400.0,
        "pre_beep_ms": 120,
        "post_beep_hz": 400.0,
        "post_beep_ms": 80,
        "input_gain_db": 0.0,
        "output_gain_db": 0.0,
        "use_gpio_ptt": False,
        "gpio_pin": 18,
        "ptt_leadin_ms": 80,
        "ptt_tail_ms": 50,
        "use_tmpfs": True
    }
    ensure_cfg(defaults)
    with open(CFG_PATH, 'r') as f:
        data = json.load(f)
    for k,v in defaults.items():
        data.setdefault(k, v)
    return data

def write_wav(path, sr, pcm):
    pcm16 = np.clip(pcm, -1.0, 1.0)
    pcm16 = (pcm16 * 32767.0).astype(np.int16)
    with wave.open(path, 'wb') as wf:
        wf.setnchannels(1); wf.setsampwidth(2); wf.setframerate(sr)
        wf.writeframes(pcm16.tobytes())

def sine(hz, dur_ms, sr, amp=0.3):
    n = int(sr * dur_ms / 1000.0)
    if n <= 0: return np.zeros(0, dtype=np.float32)
    t = np.arange(n) / float(sr)
    x = amp * np.sin(2*np.pi*hz*t).astype(np.float32)
    # fade edges (~10ms)
    edge = max(1, int(0.01 * sr))
    win = np.ones_like(x)
    win[:edge] = np.linspace(0,1,edge, dtype=np.float32)
    win[-edge:] = np.linspace(1,0,edge, dtype=np.float32)
    return x * win

def mix_ctcss(audio, sr, hz, amp):
    t = np.arange(len(audio)) / float(sr)
    tone = (amp * np.sin(2*np.pi*hz*t)).astype(np.float32)
    return np.clip(audio + tone, -1.0, 1.0).astype(np.float32)

class PTT:
    def __init__(self, use_gpio, pin, lead_ms, tail_ms):
        self.use = use_gpio
        self.lead = lead_ms/1000.0
        self.tail = tail_ms/1000.0
        if self.use:
            import RPi.GPIO as GPIO
            self.GPIO = GPIO
            GPIO.setmode(GPIO.BCM)
            GPIO.setup(pin, GPIO.OUT, initial=GPIO.LOW)
            self.pin = pin
    def key(self):
        if self.use: self.GPIO.output(self.pin, self.GPIO.HIGH)
        time.sleep(self.lead)
    def unkey(self):
        time.sleep(self.tail)
        if self.use: self.GPIO.output(self.pin, self.GPIO.LOW)

class Parrot:
    def __init__(self, cfg):
        self.cfg = cfg
        self.sr = int(cfg["sample_rate"])
        self.frame_ms = int(cfg["frame_ms"])
        self.frame_len = int(self.sr * self.frame_ms / 1000)
        self.threshold = float(cfg["threshold"])
        self.timeout_s = float(cfg["timeout_ms"])/1000.0
        self.vox_mode = cfg.get("vox_mode","hybrid")

        self.ctcss_hz  = float(cfg["ctcss_hz"])
        self.ctcss_amp = float(cfg["ctcss_amplitude"])

        self.pre_beep_hz = float(cfg["pre_beep_hz"])
        self.pre_beep_ms = int(cfg["pre_beep_ms"])
        self.post_beep_hz = float(cfg["post_beep_hz"])
        self.post_beep_ms = int(cfg["post_beep_ms"])

        self.input_gain  = db_to_gain(float(cfg["input_gain_db"]))
        self.output_gain = db_to_gain(float(cfg["output_gain_db"]))

        self.ptt = PTT(bool(cfg.get("use_gpio_ptt", False)),
                       int(cfg.get("gpio_pin",18)),
                       int(cfg.get("ptt_leadin_ms",80)),
                       int(cfg.get("ptt_tail_ms",50)))

        if cfg["input_device_index"] is not None or cfg["output_device_index"] is not None:
            sd.default.device = (cfg["input_device_index"], cfg["output_device_index"])
        sd.default.samplerate = self.sr
        sd.default.channels = 1

        self.use_vad = bool(cfg.get("use_webrtcvad", True)) and (webrtcvad is not None)
        self.vad = webrtcvad.Vad(int(cfg.get("vad_aggressiveness",2))) if self.use_vad else None

    def _is_speech(self, frame_bytes):
        if not self.use_vad or self.vad is None: return False
        try: return self.vad.is_speech(frame_bytes, self.sr)
        except Exception: return False

    def run(self):
        log_event(f"Parrot start sr={self.sr}, frame={self.frame_ms}ms, vox={self.vox_mode}, vad={self.use_vad}", state="IDLE")
        q = queue.Queue()

        def cb(indata, frames, time_info, status):
            if status: log_event(f"InStream status: {status}")
            q.put(indata.copy())

        try:
            with sd.InputStream(blocksize=self.frame_len, callback=cb):
                while True:
                    recording = []; started = False; last_voice = None

                    # Wait/Record with VOX+VAD
                    while True:
                        frame = q.get()
                        frame = np.array(frame, dtype=np.float32) * self.input_gain
                        rms = float(np.linalg.norm(frame) / math.sqrt(len(frame)+1e-12))
                        frame16 = (np.clip(frame, -1.0, 1.0) * 32767.0).astype(np.int16)
                        vad_flag = self._is_speech(frame16.tobytes())

                        if self.vox_mode == "rms": trig = rms > self.threshold
                        elif self.vox_mode == "vad": trig = vad_flag
                        else: trig = (rms > self.threshold) or vad_flag

                        if trig:
                            if not started:
                                log_event(f"VOX start (rms={rms:.3f}, vad={vad_flag})", state="RECORDING")
                                started = True
                            recording.append(frame); last_voice = time.time()
                        else:
                            if started:
                                recording.append(frame)
                                if last_voice and (time.time() - last_voice) >= self.timeout_s:
                                    log_event("VOX stop (silence timeout)", state="PROCESSING")
                                    break
                            else:
                                pass

                    if not recording:
                        write_state("IDLE"); continue

                    # Mix CTCSS + beeps
                    audio = np.concatenate(recording, axis=0).astype(np.float32)
                    log_event(f"Mix CTCSS {self.ctcss_hz:.1f} Hz, amp {self.ctcss_amp:.3f}", state="MIXING")
                    audio = mix_ctcss(audio, self.sr, self.ctcss_hz, self.ctcss_amp)
                    pre  = sine(self.pre_beep_hz,  self.pre_beep_ms,  self.sr, amp=0.25)
                    post = sine(self.post_beep_hz, self.post_beep_ms, self.sr, amp=0.20)
                    out = np.concatenate([pre, audio, post]).astype(np.float32)
                    out = np.clip(out * self.output_gain, -1.0, 1.0)

                    # Save last TX (tmpfs by default)
                    try:
                        p = "/dev/shm/last_tx.wav" if bool(self.cfg.get("use_tmpfs", True)) \
                            else os.path.expanduser("~/parrot/last_tx.wav")
                        write_wav(p, self.sr, out)
                    except Exception as e:
                        log_event(f"WARN write wav: {e}")

                    # Transmit
                    log_event("TX start", state="TX")
                    try:
                        self.ptt.key()
                        sd.play(out, self.sr); sd.wait()
                        self.ptt.unkey()
                        log_event("TX done", state="IDLE")
                    except Exception as e:
                        log_event(f"TX error: {e}", state="ERROR")

        except Exception as e:
            log_event(f"FATAL: {e}", state="ERROR")
            time.sleep(1)  # allow systemd restart

if __name__ == "__main__":
    cfg = load_cfg()
    Parrot(cfg).run()
PY
chmod +x "$PARROT_DIR/parrot_service.py"

# -------- Deploy webui.py --------
msg "Writing webui.py (Realtime Status, Reboot, Interfaces)…"
sudo -u "$APP_USER" tee "$PARROT_DIR/webui.py" >/dev/null <<'PY'
#!/usr/bin/env python3
import os, json, time, subprocess, socket
from datetime import timedelta
from flask import Flask, request, redirect, url_for, render_template_string, jsonify, Response
import sounddevice as sd
import psutil

CFG_PATH   = os.path.expanduser('~/parrot/config.json')
SERVICE_NAME = 'parrot.service'
LOG_PATH   = '/dev/shm/parrot_log.txt'
STATE_PATH = '/dev/shm/parrot_state.json'

app = Flask(__name__)

HTML = r"""<!doctype html><html><head>
<meta charset="utf-8"><title>Parrot Repeater Control</title>
<style>
body{font-family:system-ui,Segoe UI,Arial,sans-serif;max-width:1000px;margin:24px auto;padding:0 12px}
section{background:#fafafa;border:1px solid #ddd;border-radius:12px;padding:16px;margin:14px 0}
label{display:block;margin:.4rem 0 .2rem;font-weight:600}
input,select,textarea{width:100%;padding:.45rem;border:1px solid #bbb;border-radius:8px}
textarea{height:240px;white-space:pre;overflow:auto}
.row{display:grid;grid-template-columns:1fr 1fr;gap:12px}
.row3{display:grid;grid-template-columns:1fr 1fr 1fr;gap:12px}
button{padding:.55rem 1rem;border:0;border-radius:10px;cursor:pointer}
.btn{background:#0066cc;color:#fff}.btn2{background:#eee}
pre{background:#fff;border:1px dashed #ccc;border-radius:8px;padding:8px;overflow:auto;max-height:300px}
.metric{display:inline-block;min-width:160px}
.small{font-size:.9rem;color:#555}
h1 a{font-size:.6em;margin-left:10px;text-decoration:none}
</style>
<script>
async function restartSvc(){ const r=await fetch("/service/restart",{method:"POST"}); const j=await r.json(); alert("Restart: "+j.status+"\n"+(j.detail||"")); }
async function ctlSvc(a){ const r=await fetch("/service/"+a,{method:"POST"}); const j=await r.json(); alert(a.toUpperCase()+": "+j.status+"\n"+(j.detail||"")); }
async function refreshMetrics(){
  const r=await fetch("/metrics"); const m=await r.json();
  for (const k of ["cpu","mem","disk","temp","uptime"]) { document.getElementById(k).textContent = m[k+"_str"]; }
}
async function refreshLog(){
  const t=await fetch("/events?limit=400"); const s=await t.text();
  const ta=document.getElementById('logbox'); ta.value=s; ta.scrollTop=ta.scrollHeight;
  const st=await fetch("/state"); const js=await st.json();
  document.getElementById('currstate').textContent = js.state + " @ " + js.ts;
}
async function doReboot(){
  if (!confirm("Reboot Raspberry Pi ตอนนี้เลยหรือไม่?")) return;
  const r = await fetch("/reboot",{method:"POST"});
  const j = await r.json();
  alert("Reboot: "+j.status+"\n"+(j.detail||"")+"\nถ้า success ระบบจะตัดการเชื่อมต่อภายใน ~20s");
}
setInterval(refreshMetrics, 1000);
setInterval(refreshLog, 1000);
window.onload = () => { refreshMetrics(); refreshLog(); }
</script></head><body>
<h1>Parrot / Simplex Repeater Control
  <a href="/interfaces">ดู IP ของทุก interface ⟶</a>
</h1>

<section>
  <h3>Realtime Status</h3>
  <div class="small">สถานะ: <b id="currstate">-</b></div>
  <textarea id="logbox" readonly>กำลังโหลด log ...</textarea>
  <div style="margin-top:8px">
    <button class="btn2" type="button" onclick="doReboot()">Reboot Pi</button>
  </div>
</section>

<section>
<form method="post" action="{{ url_for('save') }}">
  <h3>Audio Devices</h3>
  <div class="row">
    <div><label>Input Device</label>
      <select name="input_device_index">
        <option value="">-- Select Input --</option>
        {% for d in inputs %}<option value="{{d.index}}" {{ "selected" if cfg.input_device_index==d.index else "" }}>[{{d.index}}] {{d.name}}</option>{% endfor %}
      </select>
    </div>
    <div><label>Output Device</label>
      <select name="output_device_index">
        <option value="">-- Select Output --</option>
        {% for d in outputs %}<option value="{{d.index}}" {{ "selected" if cfg.output_device_index==d.index else "" }}>[{{d.index}}] {{d.name}}</option>{% endfor %}
      </select>
    </div>
  </div>
  <div class="row3">
    <div><label>Sample Rate (Hz)</label><input type="number" name="sample_rate" value="{{cfg.sample_rate}}"></div>
    <div><label>Frame (ms)</label><input type="number" name="frame_ms" value="{{cfg.frame_ms}}"></div>
    <div><label>VOX Mode</label><select name="vox_mode">
      {% for m in ["rms","vad","hybrid"] %}<option value="{{m}}" {{ "selected" if cfg.vox_mode==m else "" }}>{{m}}</option>{% endfor %}
    </select></div>
  </div>

  <h3>VOX / VAD & Timing</h3>
  <div class="row3">
    <div><label>Threshold (RMS 0..1)</label><input type="number" step="0.001" min="0" max="1" name="threshold" value="{{cfg.threshold}}"></div>
    <div><label>Timeout (ms)</label><input type="number" name="timeout_ms" value="{{cfg.timeout_ms}}"></div>
    <div><label>Use WebRTC VAD</label><select name="use_webrtcvad">
      <option value="true" {{ "selected" if cfg.use_webrtcvad else "" }}>true</option>
      <option value="false" {{ "" if cfg.use_webrtcvad else "selected" }}>false</option>
    </select></div>
  </div>
  <div class="row">
    <div><label>VAD Aggressiveness (0–3)</label><input type="number" name="vad_aggressiveness" value="{{cfg.vad_aggressiveness}}"></div>
    <div><label>Input Gain (dB)</label><input type="number" name="input_gain_db" step="0.5" value="{{cfg.input_gain_db}}"><div class="small">เกนเป็น dB (ไม่ใช่ ms)</div></div>
  </div>
  <div class="row">
    <div><label>Output Gain (dB)</label><input type="number" name="output_gain_db" step="0.5" value="{{cfg.output_gain_db}}"></div>
    <div><label>Use tmpfs (/dev/shm)</label><select name="use_tmpfs"><option value="true" {{ "selected" if cfg.use_tmpfs else "" }}>true</option><option value="false" {{ "" if cfg.use_tmpfs else "selected" }}>false</option></select></div>
  </div>

  <h3>CTCSS</h3>
  <div class="row">
    <div><label>CTCSS Frequency (Hz)</label><input type="number" name="ctcss_hz" value="{{cfg.ctcss_hz}}" step="0.1"></div>
    <div><label>CTCSS Amplitude (0.00–0.15)</label><input type="number" name="ctcss_amplitude" value="{{cfg.ctcss_amplitude}}" step="0.005"><div class="small">แนะนำ ~0.04–0.07 (≈ −26 ถึง −20 dB)</div></div>
  </div>

  <h3>Beep (ก่อน/หลัง)</h3>
  <div class="row">
    <div><label>Pre-Beep Freq (Hz)</label><input type="number" name="pre_beep_hz" value="{{cfg.pre_beep_hz}}"></div>
    <div><label>Pre-Beep Duration (ms)</label><input type="number" name="pre_beep_ms" value="{{cfg.pre_beep_ms}}"></div>
  </div>
  <div class="row">
    <div><label>Post-Beep Freq (Hz)</label><input type="number" name="post_beep_hz" value="{{cfg.post_beep_hz}}"></div>
    <div><label>Post-Beep Duration (ms)</label><input type="number" name="post_beep_ms" value="{{cfg.post_beep_ms}}"></div>
  </div>

  <h3>GPIO PTT (ตัวเลือก)</h3>
  <div class="row3">
    <div><label>Use GPIO PTT</label><select name="use_gpio_ptt"><option value="false" {{ "" if cfg.use_gpio_ptt else "selected" }}>false</option><option value="true" {{ "selected" if cfg.use_gpio_ptt else "" }}>true</option></select></div>
    <div><label>GPIO Pin (BCM)</label><input type="number" name="gpio_pin" value="{{cfg.gpio_pin}}"></div>
    <div><label>PTT Lead-in (ms)</label><input type="number" name="ptt_leadin_ms" value="{{cfg.ptt_leadin_ms}}"></div>
  </div>
  <div class="row">
    <div><label>PTT Tail (ms)</label><input type="number" name="ptt_tail_ms" value="{{cfg.ptt_tail_ms}}"></div>
  </div>

  <div class="row">
    <div>
      <button class="btn" type="submit">Save Config</button>
      <button class="btn2" type="button" onclick="restartSvc()">Restart Service</button>
    </div>
    <div>
      <button class="btn2" type="button" onclick="ctlSvc('stop')">Stop Service</button>
      <button class="btn2" type="button" onclick="ctlSvc('start')">Start Service</button>
      <button class="btn2" type="button" onclick="ctlSvc('status')">Status</button>
    </div>
  </div>
</form>
</section>

<section>
  <h3>System Metrics</h3>
  <div class="metric"><b>CPU</b>: <span id="cpu">-</span></div>
  <div class="metric"><b>Memory</b>: <span id="mem">-</span></div>
  <div class="metric"><b>Disk</b>: <span id="disk">-</span></div>
  <div class="metric"><b>Temp</b>: <span id="temp">-</span></div>
  <div class="metric"><b>Uptime</b>: <span id="uptime">-</span></div>
</section>

<section><h3>Detected Audio Devices</h3><pre>{{ devices_pretty }}</pre></section>
</body></html>
"""

def ensure_cfg():
    if not os.path.exists(CFG_PATH):
        os.makedirs(os.path.dirname(CFG_PATH), exist_ok=True)
        with open(CFG_PATH, 'w') as f: json.dump({}, f)

def load_cfg():
    ensure_cfg()
    with open(CFG_PATH, 'r') as f: return json.load(f) or {}

def save_cfg(cfg):
    tmp = CFG_PATH + ".tmp"
    with open(tmp, 'w') as f: json.dump(cfg, f, indent=2)
    os.replace(tmp, CFG_PATH)

def b(v): return True if str(v).lower()=="true" else False
def f(v, d=0.0):
  try: return float(v)
  except: return d
def i(v, d=0):
  try: return int(v)
  except: return d

def sudo_systemctl(args):
  try:
    out = subprocess.check_output(["sudo","/bin/systemctl"] + args, stderr=subprocess.STDOUT, text=True)
    return {"status":"ok","detail":out}
  except subprocess.CalledProcessError as e:
    return {"status":"error","detail":e.output}

def sudo_reboot():
  try:
    out = subprocess.check_output(["sudo","/sbin/reboot"], stderr=subprocess.STDOUT, text=True)
    return {"status":"ok","detail":out}
  except subprocess.CalledProcessError as e:
    return {"status":"error","detail":e.output}

def get_temp_c():
  try:
    with open('/sys/class/thermal/thermal_zone0/temp') as f:
      return float(f.read().strip())/1000.0
  except:
    try:
      out = subprocess.check_output(['vcgencmd','measure_temp']).decode()
      return float(out.strip().split('=')[1].split("'")[0])
    except: return None

def tail_lines(path, n=400):
  try:
    with open(path, 'rb') as f: data = f.read()
    txt = data.decode(errors='ignore')
    return "\n".join(txt.splitlines()[-n:])
  except FileNotFoundError:
    return "No log yet."
  except Exception as e:
    return f"Error reading log: {e}"

@app.route("/", methods=["GET"])
def index():
  cfg = load_cfg()
  defaults = {
    "input_device_index": None, "output_device_index": None,
    "sample_rate": 16000, "frame_ms": 20, "vox_mode":"hybrid",
    "use_webrtcvad": True, "vad_aggressiveness": 2,
    "threshold": 0.02, "timeout_ms": 1500,
    "ctcss_hz": 150.0, "ctcss_amplitude": 0.05,
    "pre_beep_hz": 400.0, "pre_beep_ms": 120,
    "post_beep_hz": 400.0, "post_beep_ms": 80,
    "input_gain_db": 0.0, "output_gain_db": 0.0,
    "use_gpio_ptt": False, "gpio_pin": 18,
    "ptt_leadin_ms": 80, "ptt_tail_ms": 50,
    "use_tmpfs": True
  }
  for k,v in defaults.items(): cfg.setdefault(k, v)

  devs = sd.query_devices()
  inputs, outputs = [], []
  for idx, d in enumerate(devs):
    item = {"index": idx, "name": d.get("name","")}
    if d.get("max_input_channels",0) > 0: inputs.append(item)
    if d.get("max_output_channels",0) > 0: outputs.append(item)

  return render_template_string(HTML,
    cfg=cfg, inputs=inputs, outputs=outputs, devices_pretty=json.dumps(devs, indent=2))

@app.route("/save", methods=["POST"])
def save():
  cfg = load_cfg(); form = request.form
  cfg["input_device_index"] = i(form.get("input_device_index"), None)
  cfg["output_device_index"] = i(form.get("output_device_index"), None)
  cfg["sample_rate"] = i(form.get("sample_rate"), 16000)
  cfg["frame_ms"] = i(form.get("frame_ms"), 20)
  cfg["vox_mode"] = form.get("vox_mode","hybrid")
  cfg["use_webrtcvad"] = b(form.get("use_webrtcvad","true"))
  cfg["vad_aggressiveness"] = i(form.get("vad_aggressiveness"), 2)
  cfg["threshold"] = f(form.get("threshold"), 0.02)
  cfg["timeout_ms"] = i(form.get("timeout_ms"), 1500)
  cfg["ctcss_hz"] = f(form.get("ctcss_hz"), 150.0)
  cfg["ctcss_amplitude"] = f(form.get("ctcss_amplitude"), 0.05)
  cfg["pre_beep_hz"] = f(form.get("pre_beep_hz"), 400.0)
  cfg["pre_beep_ms"] = i(form.get("pre_beep_ms"), 120)
  cfg["post_beep_hz"] = f(form.get("post_beep_hz"), 400.0)
  cfg["post_beep_ms"] = i(form.get("post_beep_ms"), 80)
  cfg["input_gain_db"] = f(form.get("input_gain_db"), 0.0)
  cfg["output_gain_db"] = f(form.get("output_gain_db"), 0.0)
  cfg["use_gpio_ptt"] = b(form.get("use_gpio_ptt","false"))
  cfg["gpio_pin"] = i(form.get("gpio_pin"), 18)
  cfg["ptt_leadin_ms"] = i(form.get("ptt_leadin_ms"), 80)
  cfg["ptt_tail_ms"] = i(form.get("ptt_tail_ms"), 50)
  cfg["use_tmpfs"] = b(form.get("use_tmpfs","true"))
  save_cfg(cfg); return redirect(url_for('index'))

# service control
@app.route("/service/restart", methods=["POST"])
def svc_restart(): return jsonify(sudo_systemctl(["restart", SERVICE_NAME]))
@app.route("/service/start", methods=["POST"])
def svc_start():    return jsonify(sudo_systemctl(["start", SERVICE_NAME]))
@app.route("/service/stop", methods=["POST"])
def svc_stop():     return jsonify(sudo_systemctl(["stop", SERVICE_NAME]))
@app.route("/service/status", methods=["POST"])
def svc_status():   return jsonify(sudo_systemctl(["status", SERVICE_NAME]))

# metrics
@app.route("/metrics")
def metrics():
  cpu = psutil.cpu_percent(interval=0.2)
  vm = psutil.virtual_memory()
  du = psutil.disk_usage('/')
  boot = psutil.boot_time()
  upt = time.time()-boot
  temp = get_temp_c()
  return jsonify({
    "cpu": cpu, "cpu_str": f"{cpu:.1f}%",
    "mem": vm.percent, "mem_str": f"{vm.percent:.1f}% ({vm.used/1e9:.2f}G/{vm.total/1e9:.2f}G)",
    "disk": du.percent, "disk_str": f"{du.percent:.1f}% ({du.used/1e9:.2f}G/{du.total/1e9:.2f}G)",
    "temp": temp, "temp_str": "-" if temp is None else f"{temp:.1f} °C",
    "uptime": int(upt), "uptime_str": str(timedelta(seconds=int(upt)))
  })

# realtime log/state
@app.route("/events")
def events():
  limit = int(request.args.get("limit", 400))
  try:
    with open('/dev/shm/parrot_log.txt','rb') as f: data = f.read()
    txt = data.decode(errors='ignore')
    txt = "\n".join(txt.splitlines()[-limit:])
  except FileNotFoundError:
    txt = "No log yet."
  return Response(txt, mimetype="text/plain; charset=utf-8")

@app.route("/state")
def state():
  try:
    with open(STATE_PATH,'r') as f: return jsonify(json.load(f))
  except FileNotFoundError:
    return jsonify({"state":"UNKNOWN","ts":"-"})
  except Exception as e:
    return jsonify({"state":"ERROR","ts":"-", "detail": str(e)})

# reboot
@app.route("/reboot", methods=["POST"])
def reboot():
  try:
    out = subprocess.check_output(["sudo","/sbin/reboot"], stderr=subprocess.STDOUT, text=True)
    return jsonify({"status":"ok","detail":out})
  except subprocess.CalledProcessError as e:
    return jsonify({"status":"error","detail":e.output})

# interfaces page
@app.route("/interfaces")
def interfaces():
  lst = []
  addrs = psutil.net_if_addrs()
  for name, alist in addrs.items():
    entry = {"name": name, "ipv4": [], "ipv6": []}
    for a in alist:
      fam = getattr(a, "family", None)
      if fam == socket.AF_INET:
        entry["ipv4"].append({"addr": a.address, "netmask": a.netmask})
      elif fam == socket.AF_INET6:
        entry["ipv6"].append({"addr": a.address})
    lst.append(entry)
  html = "<h2>Network Interfaces</h2><ul>"
  for e in lst:
    html += f"<li><b>{e['name']}</b><ul>"
    for v4 in e["ipv4"]: html += f"<li>IPv4: {v4['addr']} / {v4['netmask']}</li>"
    for v6 in e["ipv6"]: html += f"<li>IPv6: {v6['addr']}</li>"
    html += "</ul></li>"
  html += "</ul><p><a href='/'>⟵ Back</a></p>"
  return html

if __name__ == "__main__":
  app.run(host="0.0.0.0", port=8080, debug=True)
PY
chmod +x "$PARROT_DIR/webui.py"

# -------- Default config.json --------
if [[ ! -f "$PARROT_DIR/config.json" ]]; then
  msg "Writing default config.json"
  sudo -u "$APP_USER" tee "$PARROT_DIR/config.json" >/dev/null <<'JSON'
{
  "input_device_index": null,
  "output_device_index": null,
  "sample_rate": 16000,
  "frame_ms": 20,
  "vox_mode": "hybrid",
  "use_webrtcvad": true,
  "vad_aggressiveness": 2,
  "threshold": 0.02,
  "timeout_ms": 1500,
  "ctcss_hz": 150.0,
  "ctcss_amplitude": 0.05,
  "pre_beep_hz": 400.0,
  "pre_beep_ms": 120,
  "post_beep_hz": 400.0,
  "post_beep_ms": 80,
  "input_gain_db": 0.0,
  "output_gain_db": 0.0,
  "use_gpio_ptt": false,
  "gpio_pin": 18,
  "ptt_leadin_ms": 80,
  "ptt_tail_ms": 50,
  "use_tmpfs": true
}
JSON
fi

# -------- systemd units --------
msg "Creating systemd service units…"
/bin/cat >/etc/systemd/system/$SERVICE_PARROT <<UNIT
[Unit]
Description=Parrot/Simplex Repeater with CTCSS (Python)
After=sound.target network-online.target
Wants=network-online.target

[Service]
User=$APP_USER
WorkingDirectory=$PARROT_DIR
ExecStart=$PYBIN -u $PARROT_DIR/parrot_service.py
Restart=always
RestartSec=2
Nice=-5
ExecStartPre=/bin/sleep 5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

/bin/cat >/etc/systemd/system/$SERVICE_WEB <<UNIT
[Unit]
Description=Parrot Web UI (Flask via Waitress)
After=network-online.target
Wants=network-online.target

[Service]
User=$APP_USER
WorkingDirectory=$PARROT_DIR
ExecStart=$PYBIN -m waitress --listen=0.0.0.0:$WEB_PORT webui:app
Restart=always
RestartSec=2
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

# -------- sudoers --------
msg "Adding sudoers rules for service control + reboot…"
/bin/cat >/etc/sudoers.d/parrot <<SUD
$APP_USER ALL=(ALL) NOPASSWD: /bin/systemctl restart $SERVICE_PARROT, /bin/systemctl start $SERVICE_PARROT, /bin/systemctl stop $SERVICE_PARROT, /bin/systemctl status $SERVICE_PARROT
SUD
chmod 440 /etc/sudoers.d/parrot

/bin/cat >/etc/sudoers.d/parrot-reboot <<SUD
$APP_USER ALL=(ALL) NOPASSWD: /sbin/reboot, /usr/sbin/reboot, /bin/systemctl reboot
SUD
chmod 440 /etc/sudoers.d/parrot-reboot

# -------- enable services --------
msg "Reloading systemd and starting Web UI on port $WEB_PORT…"
systemctl daemon-reload
systemctl enable --now "$SERVICE_WEB"
# Do not auto-start parrot.service; user can Start/Restart from Web UI after selecting sound devices.

IP_HINT="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo -e "${c_ok}\nDone.${c_off} Open Web UI at: http://${IP_HINT:-<PI-IP>}:$WEB_PORT/"
echo "Then select Input/Output devices, Save, and click Restart Service."
