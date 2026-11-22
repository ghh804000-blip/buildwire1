"""Post-process assets/devices/index.json. Run after sync_assets.py and import_extracted.py.

usage: python -I upgrade_devices.py

- Removes the old generic_* starter devices, keeping only the AC/DC sources.
- Gives chosen raster devices the simulation the old generics had: 3-phase motor, on-delay timer, overload relay.
- Adds a `group` to every device (MCB, MCCB, Kontaktor, ...), used to group the library panel.

Safe to run repeatedly. It never overwrites an existing image, so replaced artwork is kept.
"""
import copy
import json
import re
import shutil
import sys
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS))
from import_extracted import EXTRACTED, slugify  # noqa: E402
from make_zelio import zelio_devices  # noqa: E402

DEVICES = TOOLS.parent / "assets" / "devices"
INDEX = DEVICES / "index.json"

KEEP_GENERIC = {"generic_source_ac", "generic_source_ac3", "generic_source_adjustable", "generic_source_dc24",
                "generic_source_dc_adjustable", "generic_motor_dc", "generic_junction"}

# Generic devices that belong in a group other than the sources.
GENERIC_GROUP = {"generic_motor_dc": "Motor", "generic_junction": "Titik sambung"}

FOLDER_GROUP = {
    "MCB": "MCB", "MCCB": "MCCB", "MPCB": "MPCB", "RCCB": "RCCB",
    "THERMAL OVERLOAD RELAYS": "Overload relay (TOR)",
    "PHASE PROTECTION RELAY": "Relay proteksi fasa", "PHASE MONITORING RELAYS": "Relay proteksi fasa",
    "CONTACTORS": "Kontaktor", "SIGNALING": "Lampu indikator dan buzzer",
    "ENCAPSULATED RELAY": "Relay", "TIMERS": "Timer", "SAFETY RELAY": "Relay safety",
    "PLC": "PLC", "DRIVES": "Inverter (VFD)", "SENSORS": "Sensor", "METERS & INSTRUMENTS": "Alat ukur",
    "PASSIVE COMPONENTS": "Komponen pasif", "SOCKET OUTLETS": "Stopkontak",
    "DIN RAIL": "Rel DIN", "ENCLOSURES": "Box panel",
}


def group_of(top: str, rel: str) -> str:
    text = rel.lower()
    if top == "CONTROL DEVICES":
        if "emergencia" in text:
            return "Tombol darurat"
        if re.search(r"selector|opas|np2-bd|np8|c3ss1", text):
            return "Selektor"
        if re.search(r"interr?uptor|change over", text):
            return "Saklar"
        return "Tombol tekan"
    if top == "POWER SUPPLY":
        if "borne" in text:
            return "Terminal"
        return "Trafo" if "transformador" in text else "Power supply DC"
    if top == "DISTRIBUTION":
        return "Terminal" if rel.startswith("TERMINAL") else "Busbar dan distribusi"
    if top == "ACTUATORS":
        return "Motor" if "motor" in text else "Beban"
    if top == "AUXILIARY BLOCKS":
        return "Timer" if "temporizador" in text else "Kontak bantu"
    return FOLDER_GROUP.get(top, top.title())


def extracted_groups() -> dict[str, str]:
    if not EXTRACTED.is_dir():
        return {}
    groups = {}
    for top in sorted(p for p in EXTRACTED.iterdir() if p.is_dir()):
        for comp in top.rglob("component.json"):
            raw = json.loads(comp.read_text(encoding="utf-8")).get("id") or comp.parent.name
            groups[slugify(raw)] = group_of(top.name, comp.parent.relative_to(top).as_posix())
    return groups


# --- Simulation upgrades -------------------------------------------------------------------------

def motor3(dev):
    dev["behavior"] = {
        "kind": "motor3", "pe": "PE",
        # Drawn over the shaft end of the front bell; drives inertia and the speed-following motor sound.
        "rotor": {"cx": 0.765, "cy": 0.68, "r": 0.09, "style": "motor"},
        "controls": [{"key": "power_w", "label": "Daya", "unit": "W", "min": 5, "max": 15000, "default": 2200}],
    }
    dev["ratings"] = {"rated_voltage_v": 400, "power_w": 2200}
    dev["loop_sounds"] = {"run_fwd": "motor_run_3p", "run_rev": "motor_run_3p"}
    return {"stopped": "off", "run_fwd": "on", "run_rev": "on"}, "stopped"


def overload(dev):
    rated = dev["ratings"].get("rated_current_a", 10)
    dev["behavior"] = {
        "kind": "switchgear",
        "contacts": [
            {"a": "1", "b": "2", "closed": ["normal", "tripped"]},
            {"a": "3", "b": "4", "closed": ["normal", "tripped"]},
            {"a": "5", "b": "6", "closed": ["normal", "tripped"]},
            {"a": "95", "b": "96", "closed": ["normal"]},
            {"a": "97", "b": "98", "closed": ["tripped"]},
        ],
        "operate": {"type": "click", "map": {"normal": "tripped", "tripped": "normal"}},
        "operate_hint": "Klik untuk uji trip, klik lagi untuk reset.",
        "controls": [{"key": "rated_current_a", "label": "Arus setting", "unit": "A", "min": 1, "max": 100, "default": rated}],
        "thermal": {"trip_state": "tripped", "instant_multiple": 0},
    }
    dev["sounds"] = {"normal_to_tripped": "overload_trip", "tripped_to_normal": "button_release"}
    return {"normal": "on", "tripped": "tripped"}, "normal"


def timer_on(dev):
    coil = dev["behavior"].get("coil") or {"a": "A1", "b": "A2", "volts": 230, "supply": "ac"}
    dev["behavior"] = {
        "kind": "timer_on", "coil": coil,
        "contacts": [{"a": "15", "b": "18", "closed": ["closed"]}, {"a": "15", "b": "16", "closed": ["open", "timing"]}],
        "default_time_s": 3, "controls": [],
    }
    dev["ratings"] = {**dev["ratings"], "coil_voltage_v": coil.get("volts", 230), "time_s": "0,1-999"}
    dev["sounds"] = {"open_to_closed": "relay_on", "closed_to_open": "relay_off", "timing_to_closed": "relay_on"}
    dev["loop_sounds"] = {"timing": "timer_tick"}
    return {"open": "open", "timing": "open", "closed": "closed"}, "open"


def psu(volts):
    """A 230 V AC to DC supply. Each DC level is its own net, labelled with its voltage by the solver."""
    def apply(dev):
        dev["behavior"]["outputs"] = {"DC+1": "DC+", "DC+2": "DC+", "DC-1": "DC-", "DC-2": "DC-"}
        dev["behavior"]["dc_volts"] = volts
        dev["ratings"] = {**dev["ratings"], "voltage_v": volts}
        return None, None
    return apply


def sensor_pnp(dev):
    """3-wire PNP proximity sensor: BN +, BU -, BK output. A target (toggled by clicking) switches BK to BN while the
    sensor is powered. The imported data closed BN-BK and BU-BK together, a dead short across the supply."""
    dev["behavior"] = {
        "kind": "sensor_pnp", "controls": [],
        "contacts": [{"a": "BN", "b": "BK", "closed": ["on"]}],
        "operate": {"type": "click", "map": {"idle": "target", "target": "idle", "on": "idle"}},
        "operate_hint": "Klik untuk mendekatkan atau menjauhkan benda logam. LED menyala saat terdeteksi (perlu 10-30 V DC di BN-BU).",
        "glow": {"cx": 0.27, "cy": 0.62, "r": 0.022, "color": "#ffb020"},
    }
    dev["ratings"] = {**dev["ratings"], "voltage_v": "10-30 DC", "output": "PNP NO"}
    return {"idle": "on", "target": "on", "on": "on"}, "idle"


def sensor_2wire(dev):
    """2-wire proximity sensor: switches its own circuit, AC or DC, like a contact in series with the load."""
    dev["behavior"] = {
        "kind": "switchgear", "controls": [],
        "contacts": [{"a": "BN", "b": "BU", "closed": ["on"]}],
        "operate": {"type": "click", "map": {"idle": "on", "on": "idle"}},
        "operate_hint": "Klik untuk mendekatkan atau menjauhkan benda logam.",
        "glow": {"cx": 0.27, "cy": 0.58, "r": 0.022, "color": "#ffb020"},
    }
    return {"idle": "on", "on": "on"}, "idle"


def relay_24_acdc(dev):
    # Sold as a 24 V AC/DC relay; the imported data said 230 V AC.
    dev["behavior"]["coil"] = {**dev["behavior"]["coil"], "volts": 24, "supply": "both"}
    return None, None


UPGRADES = {
    "power_supply_100_minus_240vac_12vdc_5a": psu(12),
    "power_supply_100_minus_240vac_24vdc_5a": psu(24),
    "power_supply_100_minus_240vac_48vdc_5a": psu(48),
    "sensor_de_proximidad_inductivo_3_hilos_dc": sensor_pnp,
    "sensor_de_proximidad_inductivo_2_hilos_ac_minus_dc": sensor_2wire,
    "schneider_harmony_relay_rsl1pvbu": relay_24_acdc,
    "motor_6_terminales": motor3,
    "chint_nr2_25": overload,
    "abb_tf42": overload,
    "chint_jss48a": timer_on,
    "abb_ct_c": timer_on,
    "selec_800s": timer_on,
    "multispan_dt60s": timer_on,
    "abb_ct_erc_12": timer_on,
}


PILOT = {"cx": 0.5, "cy": 0.5, "r": 0.4}
GLOW = {
    "piloto_led_amarillo": {**PILOT, "color": "#ffc53d"},
    "piloto_led_verde": {**PILOT, "color": "#52c41a"},
    "piloto_led_rojo": {**PILOT, "color": "#ff4d4f"},
    "piloto_led_azul": {**PILOT, "color": "#4dabf7"},
    "piloto_led_blanco": {**PILOT, "color": "#ffffff"},
    "foco_led": {"cx": 0.5, "cy": 0.27, "r": 0.45, "color": "#ffe08a"},
}

BREAKER_SOUNDS = {"off_to_on": "breaker_on", "on_to_off": "breaker_off", "on_to_tripped": "breaker_trip", "tripped_to_off": "breaker_off"}


def add_sounds(dev):
    """Give a silent imported device the sounds of the starter device of the same kind."""
    if dev.get("sounds") or dev.get("loop_sounds"):
        return
    behavior, states = dev["behavior"], list(dev["states"])
    kind, group = behavior.get("kind"), dev.get("group", "")
    if kind == "switchgear" and behavior.get("protective") and "tripped" in states:
        dev["sounds"] = dict(BREAKER_SOUNDS)
    elif kind == "coil" and group == "Kontaktor":
        dev["sounds"] = {"open_to_closed": "contactor_close", "closed_to_open": "contactor_open"}
        dev["loop_sounds"] = {"closed": "contactor_hum"}
    elif kind == "coil":
        dev["sounds"] = {"open_to_closed": "relay_on", "closed_to_open": "relay_off"}
    elif kind == "switchgear" and behavior.get("operate"):
        press = "estop_press" if group == "Tombol darurat" else "button_press"
        mapping = behavior["operate"].get("map", {})
        dev["sounds"] = {f"{a}_to_{b}": press if a == dev["default_state"] else "button_release" for a, b in mapping.items()}
    elif kind == "load" and "buzzer" in dev["id"]:
        dev["loop_sounds"] = {"on": "buzzer_loop"}
    elif kind == "load" and "pump" in dev["id"]:
        # Its own sound: mostly water, not the motor loop (tools/make_pump_sounds.py).
        dev["loop_sounds"] = {"on": "pump_run"}
    elif kind == "load" and group == "Motor":
        dev["loop_sounds"] = {"on": "motor_run_1p"}


# Where each meter's display sits on its photo (fractions of width/height) and what it shows.
# A line holds fields split by "|": V, A, kA, kW, kWh, Hz, or "V:L1-L2" for the voltage between two terminals.
LCD_BLUE = {"bg": "#C3D8EA", "fg": "#14202C"}
DISPLAYS = {
    "chint_ddsu666": [{"rect": [0.215, 0.305, 0.665, 0.215], "lines": ["kWh", "V|A"], **LCD_BLUE}],
    "chint_ddsu666_ct": [{"rect": [0.305, 0.315, 0.495, 0.225], "lines": ["V", "A", "kW"], **LCD_BLUE}],
    "chint_dssu666": [{"rect": [0.295, 0.175, 0.63, 0.50], "lines": ["V", "A", "kW", "kWh", "Hz"], "bg": "#D2E5F5", "fg": "#1B3F99"}],
    "chint_pd666": [{"rect": [0.245, 0.33, 0.635, 0.155], "lines": ["kWh", "V|A"], **LCD_BLUE}],
    "chint_dtsu666": [{"rect": [0.255, 0.24, 0.625, 0.34], "lines": ["V", "kW", "kWh"], **LCD_BLUE}],
    "chint_zty0_4s": [{"rect": [0.075, 0.15, 0.85, 0.515], "lines": ["V|A", "kW|Hz", "kWh"], "style": "tft", "bg": "#0F1C34", "fg": "#F2F6FA"}],
    "multifunction_power_meter_ct": [{"rect": [0.225, 0.245, 0.575, 0.48], "lines": ["V", "A", "kW", "Hz"], "bg": "#A9CDE6", "fg": "#102030"}],
    "tense_em06": [
        {"rect": [0.175, 0.155, 0.205, 0.29], "lines": ["V:L1-L2", "V:L2-L3", "V:L3-L1"], "style": "seg", "bg": "#1C0606", "fg": "#FF3B2F"},
        {"rect": [0.565, 0.155, 0.215, 0.29], "lines": ["kA", "kA", "kA"], "style": "seg", "bg": "#1C0606", "fg": "#FF3B2F"},
    ],
}

# Analog dials: a needle-free face from tools/make_meter_faces.py, the pivot, and value-to-angle points read off the scale.
GAUGES = {
    "oumik_m72_voltmeter": {
        "value": "V", "face": "oumik_m72_voltmeter__face.webp", "pivot": [0.697, 0.538], "length": 0.48, "min": 0, "max": 500,
        "scale": [[0, 180], [100, 160.9], [200, 143.8], [300, 126.1], [400, 108.2], [500, 90]],
    },
    "oumik_frequency_meter": {
        "value": "Hz", "face": "oumik_frequency_meter__face.webp", "pivot": [0.578, 0.574], "length": 0.47, "min": 45, "max": 65,
        "scale": [[45, 177.4], [50, 148.8], [55, 120.1], [60, 95.4], [65, 76.0]],
    },
}


# Devices with a working keypad: the screen and each key, as [x, y, w, h] fractions of the photo.
PANELS = {
    "logo_230rce": {
        "lcd": [0.05, 0.375, 0.43, 0.315], "bg": "#9DC08B", "fg": "#14240F", "off": "#5F7466",
        "keys": {
            "up": [0.728, 0.384, 0.094, 0.081], "left": [0.628, 0.467, 0.093, 0.081],
            "right": [0.833, 0.467, 0.094, 0.081], "down": [0.728, 0.549, 0.094, 0.079],
            "esc": [0.628, 0.630, 0.092, 0.082], "ok": [0.832, 0.630, 0.094, 0.082],
        },
    },
}


# Digital timers: the 4-digit display (shows XXX.X seconds), the status LEDs and the keys, as [x, y, w, h] fractions.
TIMER_PANELS = {
    "chint_jss48a": {
        "display": [0.222, 0.232, 0.559, 0.213], "fg": "#FF2A1F", "bg": "#160606",
        "leds": {"out": [0.136, 0.264, 0.046, 0.046, "#FF3B30"], "run": [0.136, 0.350, 0.046, 0.046, "#3DDC84"]},
        "keys": {
            "set": [0.157, 0.502, 0.103, 0.098], "up": [0.327, 0.502, 0.101, 0.098], "down": [0.462, 0.502, 0.103, 0.098],
            "left": [0.600, 0.502, 0.103, 0.098], "right": [0.735, 0.502, 0.103, 0.098],
        },
    },
}


# Thermal overload relays with working front controls: TEST trips, STOP opens 95-96 while held, RESET clears a trip,
# and the dial sets the trip current. Areas are [x, y, w, h] fractions of the photo; the dial range follows its print.
# "seat": where the relay's body starts below its pins (fraction of its height); plugged under a contactor, everything
# above that line sits behind the contactor.
TOR_PANELS = {
    "chint_nr2_25": {
        "seat": 0.22,
        "test": [0.46, 0.33, 0.24, 0.05], "stop": [0.47, 0.39, 0.21, 0.13], "reset": [0.70, 0.385, 0.22, 0.135],
        "dial": {"rect": [0.09, 0.36, 0.30, 0.21], "cx": 0.24, "cy": 0.466, "r": 0.13, "min": 17, "max": 25, "start": 180, "sweep": 215},
    },
    "abb_tf42": {
        "seat": 0.24,
        "test": [0.40, 0.345, 0.18, 0.04], "stop": [0.47, 0.395, 0.17, 0.11], "reset": [0.71, 0.40, 0.22, 0.115],
        "dial": {"rect": [0.08, 0.38, 0.29, 0.15], "cx": 0.225, "cy": 0.455, "r": 0.12, "min": 13, "max": 21, "start": 90, "sweep": 130},
    },
}

# Analog timers whose knob turns: its centre and radius (fractions of the photo width), and the time range it covers.
TIMER_KNOBS = {
    "selec_800s": {"cx": 0.50, "cy": 0.502, "r": 0.24, "min": 0.5, "max": 60},
    "multispan_dt60s": {"cx": 0.463, "cy": 0.478, "r": 0.20, "min": 0.5, "max": 60},
    "abb_ct_c": {"cx": 0.48, "cy": 0.423, "r": 0.185, "min": 0.1, "max": 600, "log": True},
    "abb_ct_erc_12": {"cx": 0.50, "cy": 0.622, "r": 0.167, "min": 0.5, "max": 10},
}


def add_controls(dev):
    behavior = dev["behavior"]
    if dev["id"] in TOR_PANELS:
        panel = TOR_PANELS[dev["id"]]
        behavior["tor_panel"] = panel
        dial = panel["dial"]
        for control in behavior.get("controls", []):
            if control["key"] == "rated_current_a":
                control.update({"min": dial["min"], "max": dial["max"], "default": dial["max"]})
        # Held STOP is its own state: the main poles stay closed, only 95-96 opens. It looks like "normal".
        states = dev["states"]
        if "stop" not in states and "normal" in states:
            stop_image = DEVICES / f'{dev["id"]}__stop.webp'
            if not stop_image.exists():
                shutil.copyfile(DEVICES / f'{dev["id"]}__normal.webp', stop_image)
            states["stop"] = "stop"
        if "stop" not in behavior.get("operate", {}).get("map", {}):
            for contact in behavior.get("contacts", []):
                if "normal" in contact["closed"] and "tripped" in contact["closed"] and "stop" not in contact["closed"]:
                    contact["closed"].append("stop")
    if dev["id"] in TIMER_KNOBS:
        behavior["knob"] = TIMER_KNOBS[dev["id"]]


def add_display(dev):
    if dev["id"] in TIMER_PANELS:
        dev["behavior"]["timer_panel"] = TIMER_PANELS[dev["id"]]
    if dev["id"] in PANELS:
        dev["behavior"]["panel"] = PANELS[dev["id"]]
        meter = dev["behavior"].get("meter")
        if meter is not None and "a" not in meter:
            del dev["behavior"]["meter"]
    meter = dev["behavior"].get("meter")
    if dev["id"] in DISPLAYS:
        meter = dev["behavior"].setdefault("meter", {})
        meter.pop("screen", None)
        meter.pop("show", None)
        meter["screens"] = DISPLAYS[dev["id"]]
    if dev["id"] in GAUGES and meter is not None:
        meter.pop("screen", None)
        meter.pop("show", None)
        meter["gauge"] = GAUGES[dev["id"]]


def upgrade(dev, fn):
    images, default = fn(dev)
    if images is None:
        return
    for state, source in images.items():
        dst = DEVICES / f'{dev["id"]}__{state}.webp'
        if not dst.exists():
            shutil.copyfile(DEVICES / f'{dev["id"]}__{source}.webp', dst)
    dev["states"] = {state: state for state in images}
    dev["default_state"] = default


# 24 V DC versions of common parts: same photos, a DC coil or lamp. (source id, new id, name)
DC_VARIANTS = [
    ("piloto_led_verde", "piloto_led_verde_24vdc", "Green LED Pilot Light 24 V DC"),
    ("piloto_led_rojo", "piloto_led_rojo_24vdc", "Red LED Pilot Light 24 V DC"),
    ("piloto_led_amarillo", "piloto_led_amarillo_24vdc", "Yellow LED Pilot Light 24 V DC"),
    ("piloto_led_azul", "piloto_led_azul_24vdc", "Blue LED Pilot Light 24 V DC"),
    ("piloto_led_blanco", "piloto_led_blanco_24vdc", "White LED Pilot Light 24 V DC"),
    ("schneider_rxm4ab2p7", "schneider_rxm4ab2bd", "Schneider Electric RXM4AB2BD + RXZE2M114 (24 V DC)"),
    ("chint_nxc32", "chint_nxc32_24vdc", "CHINT NXC-32 (koil 24 V DC)"),
    ("siren_buzzer_220v", "siren_buzzer_24vdc", "Siren buzzer 24 V DC"),
    ("logo_230rce", "logo_24rce", "LOGO! 24RCE (24 V DC)"),
]


def dc_variant(source, new_id, name):
    dev = copy.deepcopy(source)
    dev["id"], dev["name"], dev["name_id"] = new_id, name, name
    behavior = dev["behavior"]
    for key in ("coil", "load", "input"):
        if behavior.get(key):
            behavior[key] = {**behavior[key], "volts": 24, "supply": "dc"}
    if behavior.get("kind") == "plc":
        dev["note"] = "Terminal L = L+ (24 V), N = M (0 V). Input aktif bila diberi 24 V DC terhadap M."
    for state in list(dev["states"]) + ["preview"]:
        src, dst = DEVICES / f'{source["id"]}__{state}.webp', DEVICES / f'{new_id}__{state}.webp'
        if src.exists() and not dst.exists():
            shutil.copyfile(src, dst)
    dev["states"] = {state: f"{new_id}__{state}.webp" for state in dev["states"]}
    return dev


def generic_dc_devices(index):
    by_id = {dev["id"]: dev for dev in index}
    base = by_id["generic_source_dc24"]
    supply = copy.deepcopy(base)
    supply.update({
        "id": "generic_source_dc_adjustable", "name": "Adjustable DC Supply", "name_id": "Sumber DC Dapat Diatur",
        "size_mm": {"width": 50.0, "height": 62.0}, "ratings": {"voltage_v": "0-60"},
        "terminals": [{"id": "+", "x": 0.26, "y": 0.8548, "side": "bottom", "class": "power"},
                      {"id": "-", "x": 0.74, "y": 0.8548, "side": "bottom", "class": "power"}],
        "states": {"on": "on.svg"}, "default_state": "on",
        "behavior": {
            "kind": "source", "outputs": {"+": "DC+", "-": "DC-"}, "adjustable": True, "dc": True, "dc_volts": 24,
            "controls": [{"key": "voltage", "label": "Tegangan keluaran", "unit": "V", "min": 0, "max": 60, "default": 24, "live": True}],
            "meter": {"a": "+", "b": "-", "screen": [0.1, 0.09, 0.8, 0.27], "show": ["V"]},
            "wave": [0.12, 0.37, 0.76, 0.13],
        },
    })
    motor = copy.deepcopy(base)
    motor.update({
        # Photo from tools/sources/dc_motor_photo.png (supplied by the user), cropped to the motor.
        "id": "generic_motor_dc", "name": "DC Motor 24 V", "name_id": "Motor DC 24 V", "designator": "M",
        "category": "motors", "size_mm": {"width": 60.0, "height": 48.8}, "ratings": {"voltage_v": 24, "power_w": 60},
        "terminals": [{"id": "A1", "x": 0.036, "y": 0.32, "side": "left", "class": "power"},
                      {"id": "A2", "x": 0.328, "y": 0.045, "side": "top", "class": "power"}],
        "states": {"stopped": "generic_motor_dc__stopped.webp", "run_fwd": "generic_motor_dc__run_fwd.webp",
                   "run_rev": "generic_motor_dc__run_rev.webp"},
        "default_state": "stopped", "raster": True,
        "behavior": {
            "kind": "motor_dc", "load": {"a": "A1", "b": "A2", "volts": 24, "supply": "dc"},
            # A small pulley on the shaft tip, so the spin shows without hiding the motor's face.
            "rotor": {"cx": 0.934, "cy": 0.875, "r": 0.05, "style": "motor"},
            "controls": [{"key": "power_w", "label": "Daya", "unit": "W", "min": 5, "max": 2000, "default": 60}],
        },
        "loop_sounds": {"run_fwd": "motor_run_dc", "run_rev": "motor_run_dc"},
    })
    # Where a wire branches: made by clicking the middle of a wire while connecting, never from the library.
    junction = copy.deepcopy(base)
    junction.update({
        "id": "generic_junction", "name": "Junction", "name_id": "Titik sambung", "designator": "X",
        "category": "structural", "size_mm": {"width": 4.0, "height": 4.0}, "ratings": {},
        "terminals": [{"id": "J", "x": 0.5, "y": 0.5, "side": "center", "class": "power"}],
        "states": {"on": "on.svg"}, "default_state": "on",
        "behavior": {"kind": "junction", "controls": []},
        "loop_sounds": {},
    })
    return [supply, motor, junction]


def main():
    index = json.loads(INDEX.read_text(encoding="utf-8"))
    by_id = {dev["id"]: dev for dev in index}
    added = [dc_variant(by_id[src], new, name) for src, new, name in DC_VARIANTS if src in by_id] + generic_dc_devices(index) + zelio_devices()
    index = [dev for dev in index if dev["id"] not in {a["id"] for a in added}] + added
    groups = extracted_groups()
    kept, removed = [], []
    for dev in index:
        is_old = dev["id"].startswith("generic_") and dev["art"] == "device" and not dev.get("raster")
        if is_old and dev["id"] not in KEEP_GENERIC:
            removed.append(dev)
            continue
        if dev["id"] in UPGRADES:
            upgrade(dev, UPGRADES[dev["id"]])
        if dev["art"] == "device":
            if dev["id"] in KEEP_GENERIC:
                dev["group"] = GENERIC_GROUP.get(dev["id"], "Sumber AC/DC")
            else:
                source = dev["id"].removesuffix("_24vdc").replace("rxm4ab2bd", "rxm4ab2p7").replace("logo_24rce", "logo_230rce")
                dev["group"] = groups.get(dev["id"], groups.get(source, dev.get("group") or dev.get("category_label") or dev["category"]))
        if dev.get("raster"):
            add_sounds(dev)
        glow_id = dev["id"].removesuffix("_24vdc")
        if glow_id in GLOW:
            dev["behavior"]["glow"] = GLOW[glow_id]
        add_display(dev)
        add_controls(dev)
        kept.append(dev)
    for dev in removed:
        for path in DEVICES.glob(f'{dev["id"]}__*'):
            path.unlink()
    INDEX.write_text(json.dumps(kept, ensure_ascii=False), encoding="utf-8")
    counts = {}
    for dev in kept:
        if "group" in dev:
            counts[dev["group"]] = counts.get(dev["group"], 0) + 1
    print(f"removed {len(removed)} old devices, kept {len(kept)} entries")
    for name in sorted(counts):
        print(f"  {name:32s} {counts[name]:4d}")


if __name__ == "__main__":
    main()
