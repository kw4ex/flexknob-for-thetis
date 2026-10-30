#!/usr/bin/env python3
"""
flexknob_thetis.py  -  FlexControl Knob for Thetis
==================================================
Use the FlexRadio FlexControl USB tuning knob with Thetis, Thetis HL2 and
SDR-VST3. No amplifier needed. Concept, design and on-air testing: KW4EX.

What it does
  * Reads the knob straight from its USB serial port (no DDUtil, no virtual
    COM ports) and controls Thetis through Thetis' TCI server (127.0.0.1:50001).
  * Turning the knob: VFO A, VFO B, AF volume, AGC gain, RIT, XIT, tuning step
    or TX drive. The three button LEDs show which.
  * 12 presses (knob press and buttons 1-3, each tap / double tap / long) each
    run a function you choose.
  * A browser panel (http://127.0.0.1:8090) shows what the knob does right now
    and lets you choose the functions. An optional window INSIDE Thetis shows
    the same thing (set up by flexknob_thetis_setup.py).

Needs Python 3.8+ and one extra package:   py -m pip install pyserial

Safety rules built in
  * Only ONE program can open the knob at a time (the KPA1500 Thetis Bridge's
    knob feature, DDUtil ... must be off). This program says so if the knob is busy.
  * TUNE and MOX really transmit. TUNE stops by itself after a few seconds
    (default 20) and is refused while the radio is already transmitting.
  * The browser panel listens on this computer only (127.0.0.1).

No warranty - use at your own risk. MIT License. See LICENSE.txt.

Revision history
  1.0.0 (2026-10-29)  First release. The knob part of the KPA1500 Thetis Bridge
                      v2.31 as a stand-alone program: no amplifier settings.

Quick start
  py flexknob_thetis.py --selftest     (no hardware needed)
  py flexknob_thetis.py                (live; open http://127.0.0.1:8090)
  py flexknob_thetis.py --find-knob    (is the knob seen? which COM port?)
"""
import argparse
import base64
import collections
import datetime
import hashlib
import json
import os
import re
import socket
import struct
import sys
import threading
import time
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse
from xml.sax.saxutils import escape as xml_escape

VERSION = "1.0.0"
BUILD_DATE = "2026-10-29"
PROGRAM = "FlexControl Knob for Thetis"
HERE = os.path.dirname(os.path.abspath(__file__))

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class WebSocket:
    def __init__(self, sock, client=True, leftover=b""):
        self.sock = sock
        self.client = client
        self.buf = bytearray(leftover)
        self.frag = bytearray()

    @classmethod
    def connect(cls, host, port, path="/", timeout=5.0):
        s = socket.create_connection((host, port), timeout=timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        req = ("GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\n"
               "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
               "Sec-WebSocket-Version: 13\r\n\r\n" % (path, host, port, key))
        s.sendall(req.encode())
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = s.recv(4096)
            if not chunk:
                raise ConnectionError("closed during WebSocket handshake")
            data += chunk
        head, _, rest = data.partition(b"\r\n\r\n")
        if b"101" not in head.split(b"\r\n")[0]:
            raise ConnectionError("WebSocket upgrade refused: %r" % head[:60])
        s.settimeout(1.0)
        return cls(s, True, rest)

    def _send_frame(self, opcode, payload=b""):
        hdr = bytearray([0x80 | opcode])
        n = len(payload)
        mbit = 0x80 if self.client else 0
        if n < 126:
            hdr.append(mbit | n)
        elif n < 65536:
            hdr.append(mbit | 126)
            hdr += struct.pack(">H", n)
        else:
            hdr.append(mbit | 127)
            hdr += struct.pack(">Q", n)
        if self.client:
            mask = os.urandom(4)
            hdr += mask
            payload = bytes(c ^ mask[i % 4] for i, c in enumerate(payload))
        self.sock.sendall(bytes(hdr) + payload)

    def send_text(self, text):
        self._send_frame(1, text.encode("utf-8"))

    def _parse(self):
        b = self.buf
        if len(b) < 2:
            return None
        fin, op = b[0] & 0x80, b[0] & 0x0F
        masked, ln, pos = b[1] & 0x80, b[1] & 0x7F, 2
        if ln == 126:
            if len(b) < 4:
                return None
            ln, pos = struct.unpack(">H", bytes(b[2:4]))[0], 4
        elif ln == 127:
            if len(b) < 10:
                return None
            ln, pos = struct.unpack(">Q", bytes(b[2:10]))[0], 10
        mask = b""
        if masked:
            if len(b) < pos + 4:
                return None
            mask, pos = bytes(b[pos:pos + 4]), pos + 4
        if len(b) < pos + ln:
            return None
        payload = bytes(b[pos:pos + ln])
        if masked:
            payload = bytes(c ^ mask[i % 4] for i, c in enumerate(payload))
        del b[:pos + ln]
        return fin, op, payload

    def recv_message(self):
        """Return next text message. Raises socket.timeout if idle (fine)."""
        while True:
            fr = self._parse()
            if fr is None:
                chunk = self.sock.recv(65536)
                if not chunk:
                    raise ConnectionError("connection closed")
                self.buf += chunk
                continue
            fin, op, payload = fr
            if op == 9:
                self._send_frame(10, payload)
            elif op == 8:
                raise ConnectionError("closed by peer")
            elif op in (0, 1):
                self.frag += payload
                if fin:
                    msg = bytes(self.frag).decode("utf-8", "replace")
                    self.frag = bytearray()
                    return msg
            # binary (op 2) and pong (op 10) are ignored

    def close(self):
        try:
            self.sock.close()
        except Exception:
            pass


# --------------------------------------------------------------------------
# Status feed to the Thetis "FlexControl Knob" window (Multi Meter I/O, UDP, XML)
# --------------------------------------------------------------------------
def _mmio_str(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, float):
        return ("%.2f" % v).rstrip("0").rstrip(".") or "0"
    return str(v)


def mmio_xml(values, root="flexknob"):
    """one UDP datagram holding all variables, as XML (what Thetis' Multi Meter I/O reads)"""
    body = "".join("<%s>%s</%s>" % (k, xml_escape(_mmio_str(v)), k) for k, v in values.items())
    return ("<%s>%s</%s>" % (root, body, root)).encode("utf-8")


# --------------------------------------------------------------------------
# FlexRadio FlexControl tuning knob (USB serial: VID 0x2192 PID 0x0010)
#   knob -> PC:  U; D; (one click)  U03; D05; (several clicks when spun fast)
#                S; C; L;  knob press tap / double / long
#                X1S; X2C; X3L; ...  buttons 1-3 tap / double / long
#   PC -> knob:  Ixyz;  LEDs 1-3 on (1) / off (0)
# Thetis is controlled over TCI; Thetis CAT commands run through TCI run_cat_ex.
# --------------------------------------------------------------------------
KNOB_VID, KNOB_PID = 0x2192, 0x0010
KNOB_EVENTS = [
    ("knob_tap", "Knob press: tap"), ("knob_double", "Knob press: double tap"), ("knob_long", "Knob press: long"),
    ("b1_tap", "Button 1: tap"), ("b1_double", "Button 1: double tap"), ("b1_long", "Button 1: long"),
    ("b2_tap", "Button 2: tap"), ("b2_double", "Button 2: double tap"), ("b2_long", "Button 2: long"),
    ("b3_tap", "Button 3: tap"), ("b3_double", "Button 3: double tap"), ("b3_long", "Button 3: long"),
]
KNOB_EVENT_IDS = [e for e, _ in KNOB_EVENTS]
_KNOB_PRESS = {"S": "tap", "C": "double", "L": "long"}
# what turning the knob does: id -> (name, LEDs, kind, details)
#   step:  one Thetis CAT command per click (up, down)
#   value: read a value, change it, write it back (read, write, min, max)
KNOB_MODES = {
    "vfoa": ("VFO A tuning", "000", "step", ("ZZSB", "ZZSA")),
    "vfob": ("VFO B tuning", "101", "step", ("ZZSH", "ZZSG")),
    "af": ("AF volume (master)", "100", "value", ("cat:ZZAG", "cat:ZZAG%03d", 0, 100)),
    "agc": ("AGC gain (RX1)", "010", "value", ("tci:agc_gain:0", "tci:agc_gain:0,%d", -20, 120)),
    "rit": ("RIT (10 Hz per click)", "001", "step", ("ZZRU", "ZZRD")),
    "xit": ("XIT (10 Hz per click)", "011", "step", ("ZZXU", "ZZXD")),
    "step": ("Tuning step size", "110", "step", ("ZZSU", "ZZSD")),
    "drive": ("TX drive", "111", "value", ("cat:ZZPC", "cat:ZZPC%03d", 0, 100)),
}
KNOB_CYCLE = ["vfoa", "af", "agc"]
# what a press does: id -> (name, group, how)
#   mode:X / toggle_mode:X / cycle   change what turning does
#   cat_toggle:ZZxx  0/1 switch (read, then set the other)   cat:ZZxx  one CAT command
#   own:action       a function of this program
KNOB_ACTIONS = [
    ("none", "(nothing)", "", ""),
    ("mode_af_toggle", "Knob: AF volume <-> VFO A (toggle)", "Knob mode", "toggle_mode:af"),
    ("mode_agc_toggle", "Knob: AGC gain <-> VFO A (toggle)", "Knob mode", "toggle_mode:agc"),
    ("mode_vfob_toggle", "Knob: VFO B <-> VFO A (toggle)", "Knob mode", "toggle_mode:vfob"),
    ("mode_rit_toggle", "Knob: RIT <-> VFO A (toggle)", "Knob mode", "toggle_mode:rit"),
    ("mode_xit_toggle", "Knob: XIT <-> VFO A (toggle)", "Knob mode", "toggle_mode:xit"),
    ("mode_step_toggle", "Knob: tuning step size <-> VFO A (toggle)", "Knob mode", "toggle_mode:step"),
    ("mode_drive_toggle", "Knob: TX drive <-> VFO A (toggle)", "Knob mode", "toggle_mode:drive"),
    ("mode_cycle", "Knob: next mode (VFO A > AF volume > AGC gain)", "Knob mode", "cycle"),
    ("mode_vfoa", "Knob: back to VFO A tuning", "Knob mode", "mode:vfoa"),
    ("mute", "Mute on / off", "Thetis", "cat_toggle:ZZMA"),
    ("vox", "VOX on / off", "Thetis", "cat_toggle:ZZVE"),
    ("lock", "VFO A lock on / off", "Thetis", "cat_toggle:ZZUX"),
    ("split", "Split on / off", "Thetis", "cat_toggle:ZZSP"),
    ("rit_onoff", "RIT on / off", "Thetis", "cat_toggle:ZZRT"),
    ("rit_clear", "RIT clear (to 0)", "Thetis", "cat:ZZRC"),
    ("xit_onoff", "XIT on / off", "Thetis", "cat_toggle:ZZXS"),
    ("nr", "Noise reduction (NR) on / off", "Thetis", "cat_toggle:ZZNR"),
    ("nb", "Noise blanker (NB) on / off", "Thetis", "cat_toggle:ZZNA"),
    ("anf", "Auto notch (ANF) on / off", "Thetis", "cat_toggle:ZZNT"),
    ("step_up", "Tuning step: larger", "Thetis", "cat:ZZSU"),
    ("step_down", "Tuning step: smaller", "Thetis", "cat:ZZSD"),
    ("band_up", "Band up", "Thetis", "cat:ZZBU"),
    ("band_down", "Band down", "Thetis", "cat:ZZBD"),
    ("mox", "MOX on / off (TRANSMITS!)", "Transmit", "cat_toggle:ZZTX"),
    ("tune", "TUNE on / off (TRANSMITS! stops by itself)", "Transmit", "own:tune_toggle"),
    ("custom", "Custom command (type it below)", "Custom", "custom"),
]
KNOB_ACTION_MAP = {a[0]: a for a in KNOB_ACTIONS}
TRANSMIT_ACTIONS = ("mox", "tune")
# short names for the Thetis "FlexControl Knob" window
KNOB_MODE_SHORT = {"vfoa": "VFO A", "vfob": "VFO B", "af": "AF", "agc": "AGC", "rit": "RIT",
                   "xit": "XIT", "step": "Step", "drive": "Drive"}
KNOB_SHORT = {"none": "-", "mute": "Mute", "vox": "VOX", "lock": "Lock", "split": "Split", "rit_onoff": "RIT",
              "rit_clear": "RIT clr", "xit_onoff": "XIT", "nr": "NR", "nb": "NB", "anf": "ANF",
              "step_up": "Step +", "step_down": "Step -", "band_up": "Band +", "band_down": "Band -",
              "mox": "MOX!", "tune": "TUNE!"}
TITLE_KNOB = "FlexControl Knob {ver}"
# the defaults are the same as the KPA1500 Thetis Bridge's (button 3 tap is a plain TUNE here)
KNOB_DEFAULT_TABLE = {
    "knob_tap": "mode_af_toggle", "knob_double": "mute", "knob_long": "mode_vfoa",
    "b1_tap": "mode_af_toggle", "b1_double": "mode_agc_toggle", "b1_long": "mute",
    "b2_tap": "vox", "b2_double": "step_up", "b2_long": "step_down",
    "b3_tap": "tune", "b3_double": "band_up", "b3_long": "band_down",
}
CUSTOM_RE = re.compile(r"^(ZZ[A-Z0-9]{2}[^;]{0,20};?|[a-z_]{2,30}:[^;]{0,60};?)$")
VALID_BAUDS = (9600, 19200, 38400, 57600, 115200)
PORT_RE = re.compile(r"COM\d{1,3}|/dev/(tty|cu)[\w.\-]+", re.I)


def clean_title(s, default):
    """window title text: plain characters only ('%' has a meaning in Thetis); {ver} = program version"""
    if not isinstance(s, str):
        return default
    s = "".join(c for c in s if 32 <= ord(c) < 127 and c not in "%|<>&").strip()[:48]
    return s or default


def clean_knob(k):
    """settings value -> complete knob settings"""
    k = k if isinstance(k, dict) else {}
    port = k.get("port", "auto")
    if not isinstance(port, str) or not (port in ("", "auto") or PORT_RE.fullmatch(port)):
        port = "auto"
    table = dict(KNOB_DEFAULT_TABLE)
    for e, a in (k.get("table") or {}).items() if isinstance(k.get("table"), dict) else []:
        if e in table and a in KNOB_ACTION_MAP:
            table[e] = a
    custom = {}
    for e, c in (k.get("custom") or {}).items() if isinstance(k.get("custom"), dict) else []:
        if e in table and isinstance(c, str) and CUSTOM_RE.match(c.strip()):
            custom[e] = c.strip()

    def num(key, default, lo, hi):
        try:
            return max(lo, min(hi, int(k.get(key, default))))
        except (TypeError, ValueError):
            return default
    return {"port": port, "table": table, "custom": custom, "speed": num("speed", 2, 1, 8),
            "af_step": num("af_step", 1, 1, 10), "return_s": num("return_s", 0, 0, 600),
            "tune_s": num("tune_s", 20, 0, 120)}


def list_serial_ports():
    """(list of {device, desc}, note). Needs pyserial."""
    try:
        from serial.tools import list_ports
    except ImportError:
        return [], "pyserial is not installed (py -m pip install pyserial)"
    try:
        return [{"device": p.device, "desc": p.description or ""}
                for p in list_ports.comports()], ""
    except Exception as e:
        return [], str(e)


def default_serial_opener(port, baud):
    import serial  # pyserial
    return serial.Serial(port, baud, timeout=0.1)


def serial_available():
    try:
        import serial  # noqa: F401  (pyserial)
        from serial.tools import list_ports  # noqa: F401
        return True
    except ImportError:
        return False


def find_knob_port():
    """COM port of a connected FlexControl (by its USB id), or None"""
    try:
        from serial.tools import list_ports
        for p in list_ports.comports():
            if getattr(p, "vid", None) == KNOB_VID and getattr(p, "pid", None) == KNOB_PID:
                return p.device
    except Exception:
        pass
    return None


def parse_knob_code(code):
    """'U03' -> ('turn', 3)   'D' -> ('turn', -1)   'X2C' -> ('event', 'b2_double')   else (None, None)"""
    code = code.strip().upper()
    m = re.fullmatch(r"([UD])(\d{0,3})", code)
    if m:
        n = int(m.group(2) or 1) or 1
        return "turn", n if m.group(1) == "U" else -n
    if code in _KNOB_PRESS:
        return "event", "knob_" + _KNOB_PRESS[code]
    m = re.fullmatch(r"X([1-3])([SCL])", code)
    if m:
        return "event", "b%s_%s" % (m.group(1), _KNOB_PRESS[m.group(2)])
    return None, None


class FlexKnob(threading.Thread):
    """Reads the FlexControl; calls on_code('U03') for each message. Reconnects by itself."""
    def __init__(self, port, opener, on_code, log, finder=find_knob_port):
        super().__init__(daemon=True)
        self.port, self.opener, self.on_code, self.log, self.finder = port, opener, on_code, log, finder
        self.stop = threading.Event()
        self.ser, self.connected, self.device, self.error = None, False, "", ""
        self.out = []
        self._reconnect = False

    def set_port(self, port):
        self.port = port
        self._reconnect = True

    def send(self, text):
        self.out.append(text.encode("ascii"))

    def _close(self):
        try:
            if self.ser:
                self.ser.close()
        except Exception:
            pass
        self.ser, self.connected = None, False

    def run(self):
        buf = b""
        while not self.stop.is_set():
            if self._reconnect:
                self._reconnect = False
                self._close()
                self.error = ""
            if not self.port:
                self._close()
                self.device, self.error = "", ""
                self.stop.wait(0.5)
                continue
            if self.ser is None:
                dev = self.finder() if self.port == "auto" else self.port
                if not dev:
                    self.device = ""
                    self.error = ("not found (is it plugged in?)" if serial_available() else
                                  "pyserial is not installed - run:  py -m pip install pyserial")
                    self.stop.wait(2.0)
                    continue
                try:
                    self.ser = self.opener(dev, 9600)
                    self.connected, self.device, self.error, buf = True, dev, "", b""
                    self.log("FlexControl knob connected on %s" % dev)
                    self.on_code("__connected__")
                except Exception as e:
                    msg = str(e)
                    if "denied" in msg.lower() or "busy" in msg.lower() or "PermissionError" in msg:
                        msg = ("%s is in use by another program - close DDUtil, or turn the knob OFF in the "
                               "KPA1500 Thetis Bridge (see the Help page), then wait a few seconds" % dev)
                    elif "No module named" in msg and "serial" in msg:
                        msg = "pyserial is not installed - run:  py -m pip install pyserial"
                    if msg != self.error:
                        self.log("FlexControl knob: %s" % msg)
                    self.device, self.error = dev, msg
                    self.ser = None
                    self.stop.wait(3.0)
                    continue
            try:
                while self.out:
                    self.ser.write(self.out.pop(0))
                n = self.ser.in_waiting
                if n:
                    buf += self.ser.read(n)
                    while b";" in buf:
                        code, buf = buf.split(b";", 1)
                        code = code.decode("ascii", "replace").strip()
                        if code:
                            self.on_code(code)
                    buf = buf[-64:]
                else:
                    self.stop.wait(0.01)
            except Exception as e:
                self.log("FlexControl knob disconnected: %s" % e)
                self._close()
                self.error = "disconnected"
                self.stop.wait(1.0)
        self._close()


class FakeKnobSerial:
    """Stands in for pyserial in the self-test: feed() what the knob would send."""
    def __init__(self):
        self.buf, self.written = b"", []

    def feed(self, s):
        self.buf += s.encode("ascii")

    def write(self, b):
        self.written.append(b)

    @property
    def in_waiting(self):
        return len(self.buf)

    def read(self, n):
        d, self.buf = self.buf[:n], self.buf[n:]
        return d

    def close(self):
        pass


def load_settings(path):
    """Small JSON file next to the program remembering choices made in the panel."""
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def acquire_lock(port):
    """Single-instance guard: hold a localhost TCP port while running.
    Returns the socket (keep it alive) or None if another copy holds it."""
    if not port:
        return socket.socket()
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind(("127.0.0.1", port))
        s.listen(1)
        return s
    except OSError:
        s.close()
        return None


# --------------------------------------------------------------------------
# The program
# --------------------------------------------------------------------------
class App:
    CAT_REPLY_RE = re.compile(r"run_cat_ex:(ZZ[A-Z0-9]{2})[^;,]*;?,\s*(?:ZZ[A-Z0-9]{2})?([^;]*);?")

    def __init__(self, a, quiet=False):
        self.a = a
        self.quiet = quiet
        self.stop = threading.Event()
        self.print_lock = threading.Lock()
        self.recent = collections.deque(maxlen=40)       # last log lines, shown in the panel
        self.settings_file = a.settings_file
        self.settings = load_settings(self.settings_file)
        self._log_fh = None
        # Thetis (TCI)
        self.tci_ws, self.tci_ok, self.tci_cat_ok = None, False, None
        self.tci_send_lock = threading.Lock()
        self.cat_replies, self.cat_events, self.agc_val = {}, {}, {}
        self.tx = False
        self.tune_active, self.bridge_tune, self.tune_t = False, False, 0.0
        # the knob
        self.knob_cfg = clean_knob(self.settings.get("knob"))
        self.knob = None
        self.knob_mode = "vfoa"
        self.knob_vals = {}               # value modes: mode -> [value, time last used]
        self.knob_last = ("", "", 0.0)    # last message: code, meaning, time
        self.knob_t = 0.0                 # last knob activity
        self.web = None
        self.mmio_sock = None

    # ---- log -----------------------------------------------------------------
    def _write_log(self, text):
        if self.a.no_log:
            return
        try:
            path = self.a.logfile
            if not os.path.isabs(path):
                path = os.path.join(HERE, path)
            if os.path.exists(path) and os.path.getsize(path) > 1024 * 1024:
                try:
                    os.replace(path, path + ".old")
                except OSError:
                    pass
            with open(path, "a", encoding="utf-8") as f:
                f.write(text + "\n")
        except OSError:
            pass

    def log(self, msg, verbose=False):
        if verbose and not self.a.verbose:
            return
        line = "%s  %s" % (time.strftime("%H:%M:%S"), msg)
        self.recent.append(line)
        self._write_log(time.strftime("%Y-%m-%d ") + line)
        if not self.quiet:
            with self.print_lock:
                try:
                    print(line, flush=True)
                except (OSError, UnicodeEncodeError):
                    pass

    def save_setting(self, key, value):
        self.settings[key] = value
        tmp = self.settings_file + ".tmp"
        try:
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(self.settings, f, indent=1)
            os.replace(tmp, self.settings_file)
        except OSError as e:
            self.log("Could not save settings: %s" % e)

    # ---- Thetis over TCI -------------------------------------------------------
    def tci_loop(self):
        warned = False
        while not self.stop.is_set():
            ws = None
            try:
                ws = WebSocket.connect(self.a.tci_host, self.a.tci_port, self.a.tci_path)
                self.tci_ws = ws
                self.tci_ok = True
                warned = False
                self.log("Connected to Thetis (TCI at %s:%d)" % (self.a.tci_host, self.a.tci_port))
                threading.Thread(target=self.check_tci_cat, daemon=True).start()
                while not self.stop.is_set():
                    try:
                        msg = ws.recv_message()
                    except socket.timeout:
                        continue
                    self.on_tci(msg)
            except Exception as e:
                if self.tci_ok:
                    self.log("Lost the link to Thetis: %s" % e)
                elif not warned:
                    self.log("Waiting for Thetis (TCI server %s:%d) ... is Thetis running with TCI on? (%s)"
                             % (self.a.tci_host, self.a.tci_port, e))
                    warned = True
                self.tci_ok = False
                self.tci_cat_ok = None
                if self.tune_active and self.bridge_tune:
                    self.tune_active, self.bridge_tune = False, False
            finally:
                self.tci_ws = None
                if ws:
                    ws.close()
            self.stop.wait(2.0)

    def on_tci(self, msg):
        for m in self.CAT_REPLY_RE.finditer(msg):      # answers to Thetis CAT questions
            code, val = m.group(1), m.group(2).strip()
            self.cat_replies[code] = (val, time.time())
            ev = self.cat_events.get(code)
            if ev:
                ev.set()
        for tok in msg.split(";"):
            tok = tok.strip()
            if not tok:
                continue
            name, _, rest = tok.partition(":")
            args = [x.strip() for x in rest.split(",")] if rest else []
            self.log("<- TCI: %s" % tok, verbose=True)
            try:
                rx = int(args[0]) if args else None
                if name == "trx" and rx == self.a.rx and len(args) >= 2:
                    self.tx = args[1].lower() == "true"
                elif name == "tune" and rx == self.a.rx and len(args) >= 2:
                    on = args[1].lower() == "true"
                    if on and not self.tune_active:
                        self.tune_active, self.bridge_tune, self.tune_t = True, False, time.time()
                    elif not on:
                        self.tune_active, self.bridge_tune = False, False
                elif name == "agc_gain" and len(args) >= 2:
                    self.agc_val[rx] = (int(float(args[1])), time.time())
                    ev = self.cat_events.get("agc_gain")
                    if ev:
                        ev.set()
            except (ValueError, IndexError):
                pass

    def tci_send(self, text):
        ws = self.tci_ws
        if not (ws and self.tci_ok):
            return False
        try:
            with self.tci_send_lock:
                ws.send_text(text)
            return True
        except Exception as e:
            self.log("Could not send to Thetis: %s" % e)
            return False

    def tci_cat(self, cmd):
        """run one Thetis CAT command (e.g. ZZSB) through TCI"""
        return self.tci_send("run_cat_ex:%s;" % cmd.strip().rstrip(";"))

    def cat_query(self, code, timeout=0.6):
        """ask Thetis a CAT value (e.g. ZZMA -> '1'); None if no answer"""
        ev = threading.Event()
        self.cat_events[code] = ev
        t0 = time.time()
        try:
            if not self.tci_cat(code):
                return None
            ev.wait(timeout)
        finally:
            self.cat_events.pop(code, None)
        v = self.cat_replies.get(code)
        return v[0] if v and v[1] >= t0 else None

    def agc_query(self, timeout=0.6):
        ev = threading.Event()
        self.cat_events["agc_gain"] = ev
        t0 = time.time()
        try:
            if not self.tci_send("agc_gain:%d;" % self.a.rx):
                return None
            ev.wait(timeout)
        finally:
            self.cat_events.pop("agc_gain", None)
        v = self.agc_val.get(self.a.rx)
        return v[0] if v and v[1] >= t0 else None

    def check_tci_cat(self):
        """ask Thetis its version through run_cat_ex: tells whether CAT-over-TCI works"""
        time.sleep(0.5)
        for _ in range(2):
            v = self.cat_query("ZZVN", 1.5)
            if v is not None:
                if self.tci_cat_ok is not True:
                    self.log("Thetis runs CAT commands over TCI (version %s) - all knob functions available" % v,
                             verbose=True)
                self.tci_cat_ok = True
                return
        if self.tci_cat_ok is not False:
            self.log("Thetis did not answer a CAT command over TCI (run_cat_ex). The knob's CAT functions "
                     "(VFO steps, VOX, mute, AF volume ...) need a newer Thetis.")
        self.tci_cat_ok = False

    # ---- the knob ---------------------------------------------------------------
    def knob_set_mode(self, mode, why=""):
        if mode not in KNOB_MODES:
            return
        if mode != self.knob_mode:
            self.knob_mode = mode
            self.log("Knob: %s%s" % (KNOB_MODES[mode][0], why), verbose=True)
        if self.knob:
            self.knob.send("I%s;" % KNOB_MODES[mode][1])

    def knob_code(self, code):
        """one message from the knob"""
        now = time.time()
        if code == "__connected__":
            self.knob_set_mode(self.knob_mode)
            return
        kind, val = parse_knob_code(code)
        if kind is None:
            return
        self.knob_t = now
        if kind == "turn":
            self.knob_last = (code, "turn %s %d" % ("up" if val > 0 else "down", abs(val)), now)
            self.knob_turn(val)
        else:
            act = self.knob_cfg["table"].get(val, "none")
            self.knob_last = (code, dict(KNOB_EVENTS).get(val, val), now)
            ok, msg = self.knob_action(val, act)
            if act != "none":
                self.log("Knob %s -> %s%s" % (dict(KNOB_EVENTS).get(val, val), "" if ok else "REFUSED: ", msg))

    def knob_turn(self, n):
        if not self.tci_ok:
            return
        name, _led, kind, det = KNOB_MODES[self.knob_mode]
        if kind == "step":
            up, down = det
            steps = abs(n) if abs(n) < 3 else abs(n) * self.knob_cfg["speed"]
            for _ in range(min(steps, 40)):
                self.tci_cat(up if n > 0 else down)
            return
        rd, wr, lo, hi = det
        now = time.time()
        cur = self.knob_vals.get(self.knob_mode)
        if cur is None or now - cur[1] > 3.0:        # not turned lately: read the value now
            v = self.agc_query() if rd.startswith("tci:") else self.cat_query(rd[4:])
            try:
                v = int(str(v).replace("+", "")) if v is not None else None
            except ValueError:
                v = None
            if v is None:
                if cur is None:
                    self.log("Knob: Thetis did not tell the %s - try again" % name)
                    return
                v = cur[0]
            cur = [v, now]
        stepv = self.knob_cfg["af_step"] if self.knob_mode == "af" else 1
        v = max(lo, min(hi, cur[0] + (1 if n > 0 else -1) * min(abs(n), 10) * stepv))
        self.knob_vals[self.knob_mode] = [v, now]
        fmt = wr[4:]
        if wr.startswith("tci:"):
            self.tci_send(fmt % v + ";")
        else:
            self.tci_cat(fmt % v)

    def knob_action(self, event, act):
        """run the function assigned to a knob event (also used by the panel's Try button)"""
        spec = KNOB_ACTION_MAP.get(act)
        if not spec or act == "none":
            return True, "nothing assigned"
        how = spec[3]
        if how.startswith("toggle_mode:"):
            m = how.split(":", 1)[1]
            self.knob_set_mode("vfoa" if self.knob_mode == m else m)
            return True, "knob now: %s" % KNOB_MODES[self.knob_mode][0]
        if how.startswith("mode:"):
            self.knob_set_mode(how.split(":", 1)[1])
            return True, "knob now: %s" % KNOB_MODES[self.knob_mode][0]
        if how == "cycle":
            i = KNOB_CYCLE.index(self.knob_mode) if self.knob_mode in KNOB_CYCLE else -1
            self.knob_set_mode(KNOB_CYCLE[(i + 1) % len(KNOB_CYCLE)])
            return True, "knob now: %s" % KNOB_MODES[self.knob_mode][0]
        if how.startswith("own:"):
            return self.do_action(how.split(":", 1)[1])
        if not self.tci_ok:
            return False, "Thetis is not connected (TCI)"
        if how.startswith("cat_toggle:"):
            code = how.split(":", 1)[1]
            cur = self.cat_query(code)
            if cur not in ("0", "1"):
                return False, "Thetis did not answer %s" % code
            new = "0" if cur == "1" else "1"
            self.tci_cat(code + new)
            return True, "%s %s" % (spec[1].split(" on / off")[0], "ON" if new == "1" else "OFF")
        if how.startswith("cat:"):
            self.tci_cat(how.split(":", 1)[1])
            return True, spec[1]
        if how == "custom":
            c = self.knob_cfg["custom"].get(event, "")
            if not c:
                return False, "no custom command typed for this event"
            if c.upper().startswith("ZZ"):
                self.tci_cat(c)
            else:
                self.tci_send(c if c.endswith(";") else c + ";")
            return True, "custom: %s" % c
        return False, "unknown function"

    def knob_short(self, event):
        """what a press does, in a few characters (for the Thetis window)"""
        act = self.knob_cfg["table"].get(event, "none")
        how = KNOB_ACTION_MAP.get(act, ("", "", "", ""))[3]
        if how.startswith("toggle_mode:"):
            m = how.split(":", 1)[1]
            return ">" + KNOB_MODE_SHORT["vfoa" if self.knob_mode == m else m]
        if how.startswith("mode:"):
            return ">" + KNOB_MODE_SHORT.get(how.split(":", 1)[1], "?")
        if how == "cycle":
            i = KNOB_CYCLE.index(self.knob_mode) if self.knob_mode in KNOB_CYCLE else -1
            return ">" + KNOB_MODE_SHORT[KNOB_CYCLE[(i + 1) % len(KNOB_CYCLE)]]
        if act == "custom":
            c = self.knob_cfg["custom"].get(event, "")
            return ("C:" + c.rstrip(";")[:9]) if c else "C:?"
        return KNOB_SHORT.get(act, act)

    def knob_line(self, prefix):
        return "tap %s   2x %s   hold %s" % (self.knob_short(prefix + "_tap"), self.knob_short(prefix + "_double"),
                                             self.knob_short(prefix + "_long"))

    def knob_watchdog(self):
        r = self.knob_cfg["return_s"]
        if r and self.knob_mode != "vfoa" and time.time() - self.knob_t > r:
            self.knob_set_mode("vfoa", " (back after %d s)" % r)

    # ---- TUNE (plain Thetis TUNE, stops by itself) -----------------------------
    def tune_start(self):
        if not (self.tci_ok and self.tci_ws):
            return False, "Refused: Thetis is not connected (TCI)"
        if self.tune_active:
            return False, "A tune is already running - press again to stop it"
        if self.tx:
            return False, "Refused: the radio is already transmitting"
        self.tune_active, self.tune_t, self.bridge_tune = True, time.time(), True
        if not self.tci_send("tune:%d,true;" % self.a.rx):
            self.tune_active, self.bridge_tune = False, False
            return False, "Could not reach Thetis - tune not started"
        s = self.knob_cfg["tune_s"]
        msg = "TUNE started%s" % ((", stops by itself after %d s" % s) if s else " (no automatic stop - press again to stop)")
        self.log(msg)
        return True, msg

    def tune_stop(self, why="TUNE stopped"):
        if not self.tune_active:
            return False, "No tune is running"
        sent = self.tci_send("tune:%d,false;" % self.a.rx)
        self.log(why)

        def fallback():           # Thetis normally answers tune:false; if not, finish anyway
            if self.tune_active and not self.tx:
                self.tune_active, self.bridge_tune = False, False
        threading.Timer(1.5, fallback).start()
        return True, why + ("" if sent else " (Thetis not reachable)")

    def tune_watchdog(self):
        s = self.knob_cfg["tune_s"]
        if self.tune_active and self.bridge_tune and s and time.time() - self.tune_t > s:
            self.bridge_tune = False
            self.tune_stop("TUNE stopped by itself after %d s" % s)

    def watchdog_loop(self):
        while not self.stop.is_set():
            try:
                self.knob_watchdog()
                self.tune_watchdog()
            except Exception as e:
                self.log("watchdog: %s" % e, verbose=True)
            self.stop.wait(0.25)

    # ---- actions from the panel ---------------------------------------------------
    def do_action(self, name, params=None):
        params = params if isinstance(params, dict) else {}
        if name == "tune_toggle":
            return self.tune_stop("TUNE stopped") if self.tune_active else self.tune_start()
        if name == "tune_stop":
            return self.tune_stop("TUNE stopped (STOP button)") if self.tune_active else (True, "No tune is running")
        if name in ("knob_set", "knob_defaults"):
            old = self.knob_cfg
            if name == "knob_defaults":
                new = clean_knob({"port": old["port"]})
            else:
                merged = {k: (dict(v) if isinstance(v, dict) else v) for k, v in old.items()}
                for key in ("port", "speed", "af_step", "return_s", "tune_s"):
                    if key in params:
                        if key == "port":
                            p = params["port"]
                            if not isinstance(p, str) or not (p in ("", "auto") or PORT_RE.fullmatch(p.strip())):
                                return False, "That is not a COM port name (like COM7) or 'auto'"
                            merged["port"] = p.strip()
                        else:
                            try:
                                merged[key] = int(params[key])
                            except (TypeError, ValueError):
                                return False, "Please give a whole number"
                if isinstance(params.get("table"), dict):
                    for e, act in params["table"].items():
                        if e not in KNOB_EVENT_IDS or act not in KNOB_ACTION_MAP:
                            return False, "Unknown press or function"
                        merged["table"][e] = act
                if isinstance(params.get("custom"), dict):
                    for e, c in params["custom"].items():
                        if e not in KNOB_EVENT_IDS or not isinstance(c, str):
                            return False, "Unknown press"
                        c = c.strip()
                        if c and not CUSTOM_RE.match(c):
                            return False, ("A custom command looks like ZZMA1;  (Thetis CAT) or mute:true;  (TCI). "
                                           "No spaces or extra ; characters.")
                        if c:
                            merged["custom"][e] = c
                        else:
                            merged["custom"].pop(e, None)
                new = clean_knob(merged)
            self.knob_cfg = new
            self.save_setting("knob", new)
            if self.knob and new["port"] != old["port"]:
                self.knob.set_port(new["port"])
            return True, "FlexControl knob settings saved" + ("" if name == "knob_set" else " (functions back to the defaults)")
        if name == "knob_try":
            ev = params.get("event")
            if ev not in KNOB_EVENT_IDS:
                return False, "Unknown knob event"
            ok, msg = self.knob_action(ev, self.knob_cfg["table"][ev])
            return ok, "Try %s: %s" % (dict(KNOB_EVENTS)[ev], msg)
        return False, "Unknown action"

    # ---- state for the panel and for the Thetis window ----------------------------
    def knob_status_text(self):
        k = self.knob
        if k and k.connected:
            return "FlexControl on %s%s" % (k.device, "" if self.tci_ok else " - waiting for Thetis (TCI)")
        if not self.knob_cfg["port"]:
            return "FlexControl: off"
        return "FlexControl: " + ((k.error if k else "") or "starting")

    def state(self):
        k = self.knob
        last = self.knob_last
        return {
            "version": VERSION, "name": PROGRAM, "tci_ok": self.tci_ok, "tci_cat_ok": self.tci_cat_ok,
            "tune_active": self.tune_active, "transmitting": self.tx,
            "knob": dict(self.knob_cfg, connected=bool(k and k.connected), device=k.device if k else "",
                         error=k.error if k else "", mode=self.knob_mode, mode_name=KNOB_MODES[self.knob_mode][0],
                         leds=KNOB_MODES[self.knob_mode][1], last=last[0], last_text=last[1],
                         last_age=round(time.time() - last[2], 1) if last[2] else None),
            "status": self.knob_status_text(), "log": list(self.recent)[-14:],
        }

    def mmio_vars(self):
        k = self.knob
        return {
            "knob_version": "v" + VERSION,
            "knob_time": int(time.time()),
            "knob_connected": int(bool(k and k.connected)),
            "knob_thetis": int(self.tci_ok),
            "knob_now": KNOB_MODES[self.knob_mode][0],
            "knob_mode": KNOB_MODES[self.knob_mode][0] if (k and k.connected) else "--",
            "knob_k": self.knob_line("knob"), "knob_b1": self.knob_line("b1"),
            "knob_b2": self.knob_line("b2"), "knob_b3": self.knob_line("b3"),
            "knob_status": self.knob_status_text(),
            "knob_tune": int(self.tune_active),
        }

    def mmio_send_loop(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        dest = (self.a.mmio_host, self.a.mmio_port)
        period = 1.0 / max(1.0, min(50.0, self.a.mmio_rate))
        while not self.stop.is_set():
            try:
                sock.sendto(mmio_xml(self.mmio_vars()), dest)
            except OSError:
                pass
            self.stop.wait(period)

    # ---- browser panel ---------------------------------------------------------------
    def start_web(self):
        app = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def _send(self, code, body, ctype="application/json"):
                data = body if isinstance(body, bytes) else body.encode("utf-8")
                self.send_response(code)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(data)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(data)

            def _host_ok(self):
                # only this computer's own name: blocks other web pages from talking to the panel
                host = (self.headers.get("Host") or "").lower().rsplit(":", 1)[0]
                return host in ("127.0.0.1", "localhost", "[::1]")

            def do_GET(self):
                if not self._host_ok():
                    return self._send(403, '{"error":"wrong host"}')
                path = urlparse(self.path).path
                if path == "/":
                    cat = {"events": KNOB_EVENTS, "actions": [a[:3] for a in KNOB_ACTIONS],
                           "modes": {k: v[0] for k, v in KNOB_MODES.items()}, "defaults": KNOB_DEFAULT_TABLE,
                           "transmit": list(TRANSMIT_ACTIONS)}
                    self._send(200, PAGE_HTML.replace("__VERSION__", VERSION).replace("__CATALOG__", json.dumps(cat)),
                               "text/html; charset=utf-8")
                elif path == "/api/state":
                    self._send(200, json.dumps(app.state()))
                elif path == "/api/ports":
                    ports, note = list_serial_ports()
                    self._send(200, json.dumps({"ports": ports, "note": note, "found": find_knob_port()}))
                elif path == "/help":
                    hp = os.path.join(HERE, "FlexKnob_Help.html")
                    try:
                        with open(hp, "rb") as f:
                            self._send(200, f.read(), "text/html; charset=utf-8")
                    except OSError:
                        self._send(404, "The help file FlexKnob_Help.html was not found next to the program.",
                                   "text/plain; charset=utf-8")
                else:
                    self._send(404, '{"error":"not found"}')

            def do_POST(self):
                # Always read the request body first. Answering (e.g. 403) while the body is
                # still unread makes Windows reset the connection (WinError 10053/10054).
                try:
                    n = max(0, min(int(self.headers.get("Content-Length", "0")), 65536))
                    raw = self.rfile.read(n) if n else b""
                except (ValueError, OSError):
                    raw = b""
                if not self._host_ok():
                    return self._send(403, '{"error":"wrong host"}')
                if urlparse(self.path).path != "/api/cmd":
                    return self._send(404, '{"error":"not found"}')
                if self.headers.get("X-FlexKnob") != "1":       # blocks cross-site posts
                    return self._send(403, '{"error":"missing header"}')
                try:
                    body = json.loads(raw or b"{}")
                    action = body.get("action", "")
                    params = body.get("params")
                except (ValueError, AttributeError):
                    return self._send(400, '{"error":"bad request"}')
                ok, msg = app.do_action(str(action), params)
                self._send(200, json.dumps({"ok": ok, "message": msg}))

        class QuietServer(ThreadingHTTPServer):
            daemon_threads = True

            def handle_error(self, request, client_address):
                # A browser that closes a page mid-reply (common on Windows) is normal.
                if isinstance(sys.exc_info()[1], (ConnectionError, TimeoutError, BrokenPipeError)):
                    return
                super().handle_error(request, client_address)

        self.web = QuietServer(("127.0.0.1", self.a.web_port), Handler)
        threading.Thread(target=self.web.serve_forever, daemon=True).start()
        return self.web.server_address[1]

    # ---- run -------------------------------------------------------------------------
    def start(self):
        """start every part (also used by the self-test)"""
        self.knob = FlexKnob(self.knob_cfg["port"], default_serial_opener, self.knob_code, self.log)
        self.knob.start()
        threading.Thread(target=self.tci_loop, daemon=True).start()
        threading.Thread(target=self.watchdog_loop, daemon=True).start()
        if self.a.mmio_port:
            threading.Thread(target=self.mmio_send_loop, daemon=True).start()
        if not self.a.no_web:
            return self.start_web()
        return None

    def shutdown(self):
        self.stop.set()
        if self.knob:
            self.knob.stop.set()
        if self.web:
            try:
                self.web.shutdown()
            except Exception:
                pass

    def run(self):
        try:
            port = self.start()
        except OSError as e:
            print("Could not start the browser panel on port %d (%s)." % (self.a.web_port, e))
            print("Another program may be using that port. Start this program with  --web-port 8091  to use another.")
            return 1
        print("=" * 66)
        print(" %s  v%s  (KW4EX)" % (PROGRAM, VERSION))
        print("=" * 66)
        print(" Thetis (TCI):   %s:%d" % (self.a.tci_host, self.a.tci_port))
        if port:
            print(" Browser panel:  http://127.0.0.1:%d     (keys in this window: W = open it, H = help, Q = quit)" % port)
        print(" Log file:       %s" % ("off" if self.a.no_log else self.a.logfile))
        print(" No warranty - use at your own risk (see LICENSE.txt).")
        print("-" * 66)
        if self.a.open_panel and port:
            try:
                webbrowser.open("http://127.0.0.1:%d" % port)
            except Exception:
                pass
        keys = ConsoleKeys(self, port)
        keys.start()
        try:
            while not self.stop.is_set():
                time.sleep(0.3)
        except KeyboardInterrupt:
            pass
        print("Stopping ...")
        self.shutdown()
        return 0


class ConsoleKeys(threading.Thread):
    """W = open the panel, H = help, Q = quit (Windows console)"""
    def __init__(self, app, port):
        super().__init__(daemon=True)
        self.app, self.port = app, port

    def run(self):
        try:
            import msvcrt
        except ImportError:
            return
        while not self.app.stop.is_set():
            try:
                if not msvcrt.kbhit():
                    time.sleep(0.1)
                    continue
                c = msvcrt.getwch().lower()
            except Exception:
                return
            if c == "q":
                self.app.log("Quit key pressed")
                self.app.stop.set()
            elif c == "w" and self.port:
                webbrowser.open("http://127.0.0.1:%d" % self.port)
            elif c == "h" and self.port:
                webbrowser.open("http://127.0.0.1:%d/help" % self.port)
            elif c in ("?", "\r"):
                print(" Keys: W = open the panel, H = help, Q = quit")


PAGE_HTML = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>FlexControl Knob for Thetis</title>
<style>
:root{--bg:#101418;--card:#1a2027;--line:#2e3742;--txt:#e8edf2;--dim:#9aa7b5;--ok:#37d67a;--warn:#ffb020;--bad:#ff5a5a;--acc:#4aa8ff}
@media (prefers-color-scheme: light){:root{--bg:#f2f4f7;--card:#fff;--line:#cfd6de;--txt:#16202a;--dim:#5a6877;--ok:#0a8f3f;--warn:#b86e00;--bad:#c62828;--acc:#0b63c5}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--txt);font:16px/1.45 Segoe UI,Arial,sans-serif}
.wrap{max-width:900px;margin:0 auto;padding:16px}
h1{font-size:22px;margin:0 0 2px} h2{font-size:17px;margin:0 0 8px}
.sub{color:var(--dim);margin-bottom:12px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px;margin:12px 0}
.chips{display:flex;flex-wrap:wrap;gap:8px}
.chip{border:1px solid var(--line);border-radius:999px;padding:4px 12px;font-size:14px}
.chip.ok{border-color:var(--ok);color:var(--ok)} .chip.bad{border-color:var(--bad);color:var(--bad)} .chip.warn{border-color:var(--warn);color:var(--warn)}
.now{font-size:26px;font-weight:600;margin:4px 0}
.leds{display:flex;gap:10px;align-items:center;margin:6px 0}
.led{width:22px;height:22px;border-radius:50%;border:2px solid var(--dim);background:transparent}
.led.on{background:var(--ok);border-color:var(--ok);box-shadow:0 0 8px var(--ok)}
table{border-collapse:collapse;width:100%} td,th{padding:6px 6px;border-bottom:1px solid var(--line);text-align:left;vertical-align:middle}
tr.hit td{background:rgba(74,168,255,.22)}
select,input[type=text]{background:var(--bg);color:var(--txt);border:1px solid var(--line);border-radius:6px;padding:5px 7px;font:inherit;max-width:100%}
button{background:var(--acc);color:#fff;border:0;border-radius:6px;padding:6px 12px;font:inherit;cursor:pointer}
button.alt{background:transparent;color:var(--txt);border:1px solid var(--line)}
button.stop{background:var(--bad);font-weight:700;font-size:18px;padding:10px 18px}
.row{display:flex;flex-wrap:wrap;gap:14px;align-items:center;margin:6px 0}
.small{color:var(--dim);font-size:14px}
#msg{min-height:24px;font-weight:600} #msg.err{color:var(--bad)} #msg.good{color:var(--ok)}
pre{background:var(--bg);border:1px solid var(--line);border-radius:6px;padding:8px;overflow:auto;max-height:230px;font-size:13px;margin:0}
a{color:var(--acc)}
</style></head><body><div class="wrap">
<h1>FlexControl Knob for Thetis <span class="small">v__VERSION__</span></h1>
<div class="sub">Use the FlexRadio FlexControl tuning knob with Thetis, Thetis HL2 or SDR-VST3. No amplifier needed. &nbsp;<a href="/help" target="_blank">Help</a></div>

<div class="card"><div class="chips"><span class="chip" id="c_knob">Knob: ...</span><span class="chip" id="c_tci">Thetis: ...</span><span class="chip" id="c_tune" style="display:none">TUNE is ON</span></div>
<div id="stopbox" style="display:none;margin-top:10px"><button class="stop" id="stopbtn">STOP TUNE</button></div>
<div id="msg" role="status" aria-live="polite"></div></div>

<div class="card"><h2>What turning the knob does right now</h2>
<div class="now" id="now">--</div>
<div class="leds" aria-label="Knob button lights"><span class="small">Lights on the knob:</span><span class="led" id="l1"></span><span class="led" id="l2"></span><span class="led" id="l3"></span><span class="small" id="ltxt"></span></div>
<div class="small" id="last">Last message from the knob: (none yet)</div></div>

<div class="card"><h2>What each press does</h2>
<div class="small" style="margin-bottom:6px">Pick a function for each press. <b>Try</b> runs it as if you had pressed it. The row lights up when you press the knob. Functions marked <b>TRANSMITS</b> make Thetis transmit.</div>
<table id="tbl"><thead><tr><th>Press</th><th>Does this</th><th></th></tr></thead><tbody></tbody></table>
<div class="row"><button class="alt" id="defbtn">Put all functions back to the defaults</button></div></div>

<div class="card"><h2>Knob settings</h2>
<div class="row"><label>Knob <select id="s_port"></select></label>
<span><input type="text" id="s_man" size="8" placeholder="COM7"> <button class="alt" id="s_use">Use this port</button></span>
<button class="alt" id="s_ref">Look again</button></div>
<div class="small" id="s_note"></div>
<div class="row"><label title="How far the VFO moves when the knob is spun fast">Fast spin <select id="s_speed"></select></label>
<label title="AF volume change per click">AF volume per click <select id="s_af"></select></label>
<label title="After this many seconds without touching the knob it goes back to VFO A. 0 = never">Back to VFO A after <input type="text" id="s_ret" size="3"> s</label>
<label title="TUNE stops by itself after this many seconds. 0 = never (not recommended)">TUNE stops after <input type="text" id="s_tune" size="3"> s</label></div></div>

<div class="card"><h2>Recent activity</h2><pre id="log"></pre></div>

<div class="small">No warranty &mdash; use at your own risk. This program is shared by one radio operator, <b>as is</b>. There is <b>no warranty of any kind</b>. TUNE and MOX really transmit: you are responsible for your station and for operating within your license. Not made, approved or supported by FlexRadio or Thetis. MIT License. 73 de KW4EX</div>
</div>
<script type="application/json" id="cat">__CATALOG__</script>
<script>
const $=id=>document.getElementById(id);
const CAT=JSON.parse($('cat').textContent);
let msgT=null;
function say(t,good){const m=$('msg');m.textContent=t;m.className=good?'good':'err';clearTimeout(msgT);msgT=setTimeout(()=>{m.textContent='';m.className='';},9000);}
function api(action,params){return fetch('/api/cmd',{method:'POST',headers:{'Content-Type':'application/json','X-FlexKnob':'1'},body:JSON.stringify({action:action,params:params||{}})}).then(r=>r.json()).then(j=>{say(j.message||'',j.ok);return j;}).catch(e=>say('Could not reach the program: '+e));}
// press table
const groups=[];CAT.actions.forEach(a=>{if(a[2]&&groups.indexOf(a[2])<0)groups.push(a[2]);});
CAT.events.forEach(ev=>{
 const id=ev[0],tr=document.createElement('tr');tr.id='r_'+id;
 const c1=document.createElement('td');c1.textContent=ev[1];
 const c2=document.createElement('td');
 const sel=document.createElement('select');sel.id='a_'+id;sel.setAttribute('aria-label',ev[1]);
 const none=CAT.actions.find(a=>a[0]==='none');const o0=document.createElement('option');o0.value='none';o0.textContent=none[1];sel.appendChild(o0);
 groups.forEach(g=>{const og=document.createElement('optgroup');og.label=g;CAT.actions.filter(a=>a[2]===g).forEach(a=>{const o=document.createElement('option');o.value=a[0];o.textContent=a[1];og.appendChild(o);});sel.appendChild(og);});
 sel.addEventListener('change',()=>{const t={};t[id]=sel.value;api('knob_set',{table:t});showCustom(id);});
 const cu=document.createElement('input');cu.type='text';cu.size=14;cu.id='c_'+id;cu.placeholder='e.g. ZZMA1;';cu.style.display='none';cu.style.marginLeft='6px';
 cu.addEventListener('change',()=>{const t={};t[id]=cu.value.trim();api('knob_set',{custom:t});});
 c2.appendChild(sel);c2.appendChild(cu);
 const c3=document.createElement('td');const b=document.createElement('button');b.className='alt';b.textContent='Try';
 b.addEventListener('click',()=>{const a=$('a_'+id).value;if(CAT.transmit.indexOf(a)>=0&&!confirm('This makes Thetis TRANSMIT. Continue?'))return;api('knob_try',{event:id});});
 c3.appendChild(b);tr.appendChild(c1);tr.appendChild(c2);tr.appendChild(c3);$('tbl').tBodies[0].appendChild(tr);
});
function showCustom(id){$('c_'+id).style.display=$('a_'+id).value==='custom'?'':'none';}
$('defbtn').addEventListener('click',()=>{if(confirm('Put all the press functions back to the defaults?'))api('knob_defaults');});
$('stopbtn').addEventListener('click',()=>api('tune_stop'));
// settings
for(let i=1;i<=8;i++){const o=document.createElement('option');o.value=i;o.textContent='x'+i;$('s_speed').appendChild(o);}
for(let i=1;i<=10;i++){const o=document.createElement('option');o.value=i;o.textContent=i;$('s_af').appendChild(o);}
$('s_speed').addEventListener('change',e=>api('knob_set',{speed:+e.target.value}));
$('s_af').addEventListener('change',e=>api('knob_set',{af_step:+e.target.value}));
$('s_ret').addEventListener('change',e=>api('knob_set',{return_s:+e.target.value||0}));
$('s_tune').addEventListener('change',e=>api('knob_set',{tune_s:+e.target.value||0}));
$('s_port').addEventListener('change',e=>{const v=e.target.value;if(v==='__manual'){$('s_man').focus();return;}api('knob_set',{port:v});});
$('s_use').addEventListener('click',()=>{const v=$('s_man').value.trim().replace(/^com/i,'COM');if(v)api('knob_set',{port:v});});
let curPort=null;
function loadPorts(){fetch('/api/ports').then(r=>r.json()).then(p=>{const s=$('s_port');s.innerHTML='';
 const add=(v,t)=>{const o=document.createElement('option');o.value=v;o.textContent=t;s.appendChild(o);};
 add('auto','Find it automatically'+(p.found?' (found on '+p.found+')':''));add('','Off (not used)');
 (p.ports||[]).forEach(x=>add(x.device,x.device+(x.desc?' - '+x.desc:'')));add('__manual','Type a COM port below...');
 if(curPort!==null){const known=[...s.options].some(o=>o.value===curPort);if(!known&&curPort)add(curPort,curPort);s.value=curPort;}
 $('s_note').textContent=p.note||'';});}
$('s_ref').addEventListener('click',loadPorts);
// live state
let first=true;
function poll(){fetch('/api/state').then(r=>r.json()).then(s=>{
 const k=s.knob;
 const ck=$('c_knob');ck.textContent=k.port===''?'Knob: off':(k.connected?'Knob connected on '+k.device:'Knob: '+(k.error||'starting...'));ck.className='chip '+(k.connected?'ok':(k.port===''?'':'bad'));
 const ct=$('c_tci');ct.textContent=s.tci_ok?'Thetis connected (TCI)'+(s.tci_cat_ok===false?' - needs a newer Thetis for the knob functions':''):'Thetis: waiting (start Thetis, TCI server on)';ct.className='chip '+(s.tci_ok?(s.tci_cat_ok===false?'warn':'ok'):'warn');
 $('c_tune').style.display=s.tune_active?'':'none';$('c_tune').className='chip bad';$('stopbox').style.display=s.tune_active?'':'none';
 $('now').textContent=k.mode_name;
 ['l1','l2','l3'].forEach((id,i)=>$(id).className='led'+(k.leds[i]==='1'?' on':''));
 $('ltxt').textContent='('+k.leds.split('').map(x=>x==='1'?'on':'off').join(' / ')+')';
 $('last').textContent=k.last?('Last message from the knob: '+k.last_text+'  ('+k.last+', '+k.last_age+' s ago)'):'Last message from the knob: (none yet)';
 CAT.events.forEach(ev=>{const id=ev[0];const sel=$('a_'+id);if(document.activeElement!==sel){sel.value=k.table[id];}showCustom(id);const cu=$('c_'+id);if(document.activeElement!==cu)cu.value=k.custom[id]||'';
  $('r_'+id).className=(k.last===eventCode(id)&&k.last_age!==null&&k.last_age<2.5)?'hit':'';});
 if(document.activeElement!==$('s_speed'))$('s_speed').value=k.speed;
 if(document.activeElement!==$('s_af'))$('s_af').value=k.af_step;
 if(document.activeElement!==$('s_ret'))$('s_ret').value=k.return_s;
 if(document.activeElement!==$('s_tune'))$('s_tune').value=k.tune_s;
 if(curPort!==k.port){curPort=k.port;if(first)loadPorts();else{const s=$('s_port');if([...s.options].some(o=>o.value===k.port))s.value=k.port;}}
 first=false;
 $('log').textContent=s.log.join('\n');
}).catch(()=>{$('c_tci').textContent='The program is not running';$('c_tci').className='chip bad';});}
function eventCode(id){const m={knob:'',b1:'X1',b2:'X2',b3:'X3'};const p=id.split('_')[0],t=id.split('_')[1];const l={tap:'S',double:'C',long:'L'}[t];return p==='knob'?l:m[p]+l;}
poll();setInterval(poll,600);
</script></body></html>
"""


# --------------------------------------------------------------------------
# self-test: a pretend knob and a pretend Thetis (no hardware needed)
# --------------------------------------------------------------------------
def selftest():
    import tempfile
    import urllib.request
    import urllib.error
    print("%s v%s self-test (pretend knob + pretend Thetis, nothing real is touched)" % (PROGRAM, VERSION))
    results = []

    def check(name, cond):
        results.append(bool(cond))
        print("  [%s] %s" % ("PASS" if cond else "FAIL", name))

    def wait_for(fn, t=3.0):
        end = time.time() + t
        while time.time() < end:
            if fn():
                return True
            time.sleep(0.02)
        return False

    tmpdir = tempfile.mkdtemp(prefix="flexknob_test_")
    # pretend Thetis: a tiny TCI WebSocket server
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)
    tci_port = srv.getsockname()[1]
    box = {}

    def accept():
        conn, _ = srv.accept()
        data = b""
        while b"\r\n\r\n" not in data:
            data += conn.recv(4096)
        key = re.search(rb"Sec-WebSocket-Key: (\S+)", data).group(1)
        acc = base64.b64encode(hashlib.sha1(key + WS_GUID.encode()).digest())
        conn.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                     b"Sec-WebSocket-Accept: " + acc + b"\r\n\r\n")
        box["ws"] = WebSocket(conn, client=False)
    threading.Thread(target=accept, daemon=True).start()
    # a UDP socket standing in for the Thetis window feed
    usock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    usock.bind(("127.0.0.1", 0))
    usock.settimeout(2.0)
    udp_port = usock.getsockname()[1]
    # find a free port for the panel
    t = socket.socket()
    t.bind(("127.0.0.1", 0))
    web_port = t.getsockname()[1]
    t.close()

    args = build_parser().parse_args(["--tci-port", str(tci_port), "--web-port", str(web_port),
                                      "--mmio-port", str(udp_port), "--mmio-rate", "20",
                                      "--settings-file", os.path.join(tmpdir, "s.json"), "--no-log", "--lock-port", "0"])
    app = App(args, quiet=True)
    fk = FakeKnobSerial()
    app.knob = FlexKnob("FAKE", lambda p_, b_: fk, app.knob_code, app.log)
    app.knob.start()
    threading.Thread(target=app.tci_loop, daemon=True).start()
    threading.Thread(target=app.watchdog_loop, daemon=True).start()
    threading.Thread(target=app.mmio_send_loop, daemon=True).start()
    app.start_web()
    base = "http://127.0.0.1:%d" % web_port

    print("-- link to Thetis --")
    check("connects to the pretend Thetis over TCI", wait_for(lambda: app.tci_ok and "ws" in box))
    thetis = box["ws"]

    def tci_got(text, t_=3.0):
        end = time.time() + t_
        thetis.sock.settimeout(0.3)
        while time.time() < end:
            try:
                m = thetis.recv_message()
            except socket.timeout:
                continue
            except Exception:
                return False
            if text in (m or ""):
                return True
        return False

    def drain(t_=0.4):
        got = []
        end = time.time() + t_
        thetis.sock.settimeout(0.1)
        while time.time() < end:
            try:
                got.append(thetis.recv_message())
            except socket.timeout:
                continue
            except Exception:
                break
        return got

    ok1 = tci_got("run_cat_ex:ZZVN;")
    thetis.send_text("run_cat_ex:ZZVN;,ZZVN2.10.3.15;")
    check("asks Thetis for its version; CAT-over-TCI recognised", ok1 and wait_for(lambda: app.tci_cat_ok is True))

    print("-- the knob --")
    check("knob messages decoded (U, D05, S, X2C, X3L)",
          parse_knob_code("U") == ("turn", 1) and parse_knob_code("D05") == ("turn", -5)
          and parse_knob_code("S") == ("event", "knob_tap") and parse_knob_code("X2C") == ("event", "b2_double")
          and parse_knob_code("X3L") == ("event", "b3_long") and parse_knob_code("F0304") == (None, None))
    check("knob connects; LEDs set for VFO A (I000;)",
          wait_for(lambda: app.knob.connected) and wait_for(lambda: b"I000;" in fk.written))
    drain()
    fk.feed("U;")
    check("one click up -> VFO A up one step (run_cat_ex:ZZSB;)", tci_got("run_cat_ex:ZZSB;"))
    drain()
    fk.feed("D03;")
    time.sleep(0.5)
    got = drain()
    check("fast spin down (D03, x2) -> 6 steps down (ZZSA x6)", sum(m.count("run_cat_ex:ZZSA;") for m in got) == 6)
    fk.feed("X1S;")
    check("button 1 tap -> knob now AF volume, LED 1 on (I100;)",
          wait_for(lambda: app.knob_mode == "af") and wait_for(lambda: b"I100;" in fk.written))
    drain()
    fk.feed("U;")
    ok1 = tci_got("run_cat_ex:ZZAG;")
    thetis.send_text("run_cat_ex:ZZAG;,ZZAG040;")
    check("AF mode: reads Thetis AF (40) and sets 41 (run_cat_ex:ZZAG041;)", ok1 and tci_got("run_cat_ex:ZZAG041;"))
    fk.feed("U;")
    check("... next click uses the known value: 42", tci_got("run_cat_ex:ZZAG042;"))
    fk.feed("S;")
    check("knob press tap (AF <-> VFO A) -> back to VFO A", wait_for(lambda: app.knob_mode == "vfoa"))
    drain()
    fk.feed("X2S;")
    ok1 = tci_got("run_cat_ex:ZZVE;")
    thetis.send_text("run_cat_ex:ZZVE;,ZZVE0;")
    check("button 2 tap -> VOX: reads OFF, switches ON (ZZVE1)", ok1 and tci_got("run_cat_ex:ZZVE1;"))
    drain()
    ok_, msg_ = app.do_action("knob_try", {"event": "b3_double"})
    check("Try button (button 3 double = band up) -> ZZBU", ok_ and tci_got("run_cat_ex:ZZBU;"))
    ok_, msg_ = app.do_action("knob_set", {"table": {"b3_long": "custom"}, "custom": {"b3_long": "ZZMA1;"}})
    drain()
    app.do_action("knob_try", {"event": "b3_long"})
    check("custom command ZZMA1; saved and sent", ok_ and tci_got("run_cat_ex:ZZMA1;")
          and app.settings["knob"]["custom"]["b3_long"] == "ZZMA1;")
    check("bad custom command / bad port refused",
          not app.do_action("knob_set", {"custom": {"b3_long": "rm -rf; x"}})[0]
          and not app.do_action("knob_set", {"port": "http://x"})[0]
          and not app.do_action("knob_set", {"table": {"b3_long": "no_such_function"}})[0])
    app.do_action("knob_set", {"return_s": 1})
    fk.feed("X1S;")
    wait_for(lambda: app.knob_mode == "af")
    check("'back to VFO A after 1 s' works", wait_for(lambda: app.knob_mode == "vfoa", 4))
    app.do_action("knob_set", {"return_s": 0})
    app.do_action("knob_defaults")
    check("default functions restored (port kept)", app.knob_cfg["table"] == KNOB_DEFAULT_TABLE
          and app.knob_cfg["port"] == "auto" and clean_knob(None)["table"] == KNOB_DEFAULT_TABLE)
    check("no amplifier functions anywhere in the list",
          not [a for a in KNOB_ACTIONS if any(w in (a[0] + a[1]).lower() for w in ("amp ", "atu", "antenna", "dummy", "standby"))])

    print("-- TUNE and MOX --")
    drain()
    fk.feed("X3S;")
    check("button 3 tap -> TUNE: Thetis told tune:0,true;", tci_got("tune:0,true;") and app.tune_active)
    thetis.send_text("tune:0,true;trx:0,true;")
    time.sleep(0.2)
    fk.feed("X3S;")
    check("press again -> TUNE stopped (tune:0,false;)", tci_got("tune:0,false;"))
    thetis.send_text("trx:0,false;tune:0,false;")
    check("... and Thetis' answer ends the tune", wait_for(lambda: not app.tune_active))
    app.do_action("knob_set", {"tune_s": 1})
    drain()
    ok_, _m = app.do_action("tune_toggle")
    check("TUNE starts again", ok_ and tci_got("tune:0,true;"))
    thetis.send_text("tune:0,true;trx:0,true;")
    check("TUNE stops by itself after 1 s (tune:0,false;)", tci_got("tune:0,false;", 4))
    thetis.send_text("trx:0,false;tune:0,false;")
    wait_for(lambda: not app.tune_active)
    thetis.send_text("trx:0,true;")
    wait_for(lambda: app.tx)
    ok_, msg_ = app.do_action("tune_toggle")
    check("TUNE refused while the radio is already transmitting", not ok_ and "transmitting" in msg_)
    thetis.send_text("trx:0,false;")
    wait_for(lambda: not app.tx)
    app.do_action("knob_set", {"tune_s": 20})

    print("-- the browser panel and the Thetis window feed --")

    def get(path):
        with urllib.request.urlopen(base + path, timeout=3) as r:
            return r.status, r.read()

    def post(action, params=None, header=True, host=None):
        h = {"Content-Type": "application/json"}
        if header:
            h["X-FlexKnob"] = "1"
        if host:
            h["Host"] = host
        rq = urllib.request.Request(base + "/api/cmd", json.dumps({"action": action, "params": params or {}}).encode(),
                                    h, method="POST")
        try:
            with urllib.request.urlopen(rq, timeout=3) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, {}

    code, body = get("/")
    check("panel page opens and has the press table", code == 200 and b"FlexControl Knob for Thetis" in body
          and b"What each press does" in body and b"No warranty" in body)
    code, body = get("/api/state")
    st = json.loads(body)
    check("panel state shows the knob, Thetis and the mode", st["tci_ok"] and st["knob"]["connected"]
          and st["knob"]["mode"] == "vfoa" and st["knob"]["last"] == "X3S")
    check("panel change without the safety header is refused (403)", post("knob_defaults", header=False)[0] == 403)
    check("panel change from another host name is refused (403)", post("knob_defaults", host="evil.example")[0] == 403)
    code, j = post("knob_set", {"speed": 3})
    check("panel change with the header works and is saved to the settings file",
          code == 200 and j["ok"] and load_settings(args.settings_file)["knob"]["speed"] == 3)
    app.do_action("knob_set", {"speed": 2})
    mv = app.mmio_vars()
    check("Thetis window lines follow the mode: in VFO A, button 1 shows 'tap >AF'",
          mv["knob_b1"] == "tap >AF   2x >AGC   hold Mute" and mv["knob_now"] == "VFO A tuning"
          and mv["knob_status"] == "FlexControl on FAKE")
    app.knob_set_mode("af")
    mv = app.mmio_vars()
    check("... and in AF volume it shows 'tap >VFO A'", mv["knob_b1"].startswith("tap >VFO A")
          and mv["knob_k"] == "tap >VFO A   2x Mute   hold >VFO A" and mv["knob_b3"] == "tap TUNE!   2x Band +   hold Band -")
    app.knob_set_mode("vfoa")
    try:
        data, _ = usock.recvfrom(4096)
        txt = data.decode()
    except socket.timeout:
        txt = ""
    check("status feed for Thetis arrives by UDP as XML with the heartbeat",
          txt.startswith("<flexknob>") and "<knob_time>" in txt and "<knob_now>" in txt and "<knob_version>v" + VERSION in txt)

    print("-- settings and safety --")
    a2 = App(args, quiet=True)
    check("settings are read back at start (speed, functions)", a2.knob_cfg["speed"] == 2
          and a2.knob_cfg["table"] == KNOB_DEFAULT_TABLE)
    bad = clean_knob({"port": "evil", "speed": 99, "table": {"b1_tap": "zzz", "nope": "mute"}, "custom": {"b1_tap": "x y"}})
    check("damaged settings are cleaned (port, speed, unknown names)",
          bad["port"] == "auto" and bad["speed"] == 8 and bad["table"] == KNOB_DEFAULT_TABLE and bad["custom"] == {})

    print("-- the knob in the KPA1500 Thetis Bridge (only one program can use the knob) --")
    bs = os.path.join(tmpdir, "kpa1500_settings.json")
    check("no bridge settings file -> NOFILE", bridge_knob_status(bs) == "NOFILE")
    with open(bs, "w", encoding="utf-8") as f:
        json.dump({"amp_ip": "192.168.0.175", "noant": {"limits": {"40": -100, "6": None}}}, f)
    check("bridge settings without a knob entry -> its knob is ON (the default)", bridge_knob_status(bs) == "ON")
    ok_, msg_ = bridge_knob_off(bs)
    d_ = load_settings(bs)
    check("switching the bridge's knob off keeps every other setting and saves a .bak copy",
          ok_ and bridge_knob_status(bs) == "OFF" and d_["amp_ip"] == "192.168.0.175"
          and d_["noant"]["limits"] == {"40": -100, "6": None}
          and [f_ for f_ in os.listdir(tmpdir) if f_.startswith("kpa1500_settings.json.") and f_.endswith(".bak")])
    with open(bs, "w", encoding="utf-8") as f:
        json.dump({"knob": {"port": "COM7", "speed": 5, "table": {"b3_tap": "mute"}}}, f)
    bridge_knob_off(bs)
    d_ = load_settings(bs)
    check("a bridge knob with its own functions: only the port changes (functions kept)",
          d_["knob"]["port"] == "" and d_["knob"]["speed"] == 5 and d_["knob"]["table"] == {"b3_tap": "mute"})
    with open(bs, "w", encoding="utf-8") as f:
        f.write("this is not json")
    check("a damaged bridge settings file is left alone", not bridge_knob_off(bs)[0])
    s1 = acquire_lock(50198 + 1000)
    s2 = acquire_lock(50198 + 1000)
    check("single-copy guard: a second copy cannot take the lock", s1 is not None and s2 is None)
    s1.close()
    app.shutdown()
    app.stop.set()

    bad_n = results.count(False)
    print("")
    if bad_n:
        print("%d of %d checks FAILED" % (bad_n, len(results)))
        return 1
    print("ALL TESTS PASSED (%d checks)" % len(results))
    return 0


# --------------------------------------------------------------------------
# the KPA1500 Thetis Bridge also has a knob feature; only one program can open the knob.
# These two helpers are used by the installer (and can be run by hand) to look at,
# and switch off, the knob in the bridge's own settings file (kpa1500_settings.json).
# --------------------------------------------------------------------------
def bridge_knob_status(path):
    """'ON', 'OFF' or 'NOFILE' for the knob feature of the bridge whose settings file is `path`.
    The bridge's knob is ON by default, so a missing 'knob' entry means ON."""
    if not os.path.isfile(path):
        return "NOFILE"
    k = load_settings(path).get("knob")
    port = k.get("port", "auto") if isinstance(k, dict) else "auto"
    return "OFF" if port == "" else "ON"


def bridge_knob_off(path):
    """switch the bridge's knob off in its settings file (a .bak copy is saved first). (ok, message)"""
    try:
        d = {}
        if os.path.isfile(path):
            with open(path, encoding="utf-8") as f:
                d = json.load(f)
            if not isinstance(d, dict):
                return False, "the bridge settings file is not in the expected form - left alone"
            stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
            with open(path + "." + stamp + ".bak", "w", encoding="utf-8") as f:
                json.dump(d, f, indent=1)
        k = d.get("knob") if isinstance(d.get("knob"), dict) else {}
        k["port"] = ""
        d["knob"] = k
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(d, f, indent=1)
        os.replace(tmp, path)
        return True, "the bridge's knob is now OFF (it takes effect when the bridge is started again)"
    except (OSError, ValueError) as e:
        return False, "could not change the bridge settings: %s" % e


# --------------------------------------------------------------------------
# command line
# --------------------------------------------------------------------------
def build_parser():
    p = argparse.ArgumentParser(description="%s v%s" % (PROGRAM, VERSION))
    p.add_argument("--tci-host", default="127.0.0.1", help="Thetis TCI host")
    p.add_argument("--tci-port", type=int, default=50001, help="Thetis TCI port")
    p.add_argument("--tci-path", default="/", help="TCI WebSocket path")
    p.add_argument("--rx", type=int, default=0, help="receiver index (0 = RX1)")
    p.add_argument("--web-port", type=int, default=8090, help="browser panel port")
    p.add_argument("--no-web", action="store_true", help="no browser panel")
    p.add_argument("--open-panel", dest="open_panel", action="store_true", help="open the panel in the browser at start")
    p.add_argument("--settings-file", default=os.path.join(HERE, "flexknob_settings.json"),
                   help="where the choices made in the panel are kept")
    p.add_argument("--mmio-port", type=int, default=50120,
                   help="UDP port for the Thetis 'FlexControl Knob' window (0 = do not send)")
    p.add_argument("--mmio-host", default="127.0.0.1", help="where that window's Thetis is (this computer)")
    p.add_argument("--mmio-rate", type=float, default=5.0, help="updates per second for the Thetis window")
    p.add_argument("--lock-port", type=int, default=50198, help="single-copy guard port (0 = off)")
    p.add_argument("--check-running", action="store_true", help="exit code 3 if a copy is already running (used by the installer)")
    p.add_argument("--find-knob", action="store_true", help="show whether the knob is seen, then exit")
    p.add_argument("--bridge-knob-status", metavar="FILE", help=argparse.SUPPRESS)   # used by the installer
    p.add_argument("--bridge-knob-off", metavar="FILE", help=argparse.SUPPRESS)      # used by the installer
    p.add_argument("--verbose", action="store_true", help="show every message")
    p.add_argument("--logfile", default="flexknob.log", help="log file (next to the program)")
    p.add_argument("--no-log", action="store_true", help="do not write a log file")
    p.add_argument("--selftest", action="store_true", help="run the built-in test (no hardware needed)")
    p.add_argument("--version", action="version", version="%s v%s" % (PROGRAM, VERSION))
    return p


def find_knob_report():
    print("%s v%s - looking for the FlexControl knob ..." % (PROGRAM, VERSION))
    ports, note = list_serial_ports()
    if note:
        print("Problem: " + note)
        return 1
    print("Serial ports on this computer: " + (", ".join("%s (%s)" % (p["device"], p["desc"]) for p in ports) or "none"))
    dev = find_knob_port()
    if dev:
        print("FOUND the FlexControl on %s." % dev)
        return 0
    print("The FlexControl was not found. Is it plugged in? (USB id 2192:0010)")
    print("If you know its COM port, you can choose it in the browser panel instead of 'Find it automatically'.")
    return 2


def main():
    a = build_parser().parse_args()
    if a.selftest:
        return selftest()
    if a.find_knob:
        return find_knob_report()
    if a.bridge_knob_status:
        print(bridge_knob_status(a.bridge_knob_status))
        return 0
    if a.bridge_knob_off:
        ok, msg = bridge_knob_off(a.bridge_knob_off)
        print(msg)
        return 0 if ok else 1
    if a.check_running:
        s = acquire_lock(a.lock_port)
        if s is None:
            return 3
        s.close()
        return 0
    lock = acquire_lock(a.lock_port)
    if lock is None:
        print("%s is already running (look for its window, or press Q in it)." % PROGRAM)
        return 2
    return App(a).run()


if __name__ == "__main__":
    sys.exit(main())
