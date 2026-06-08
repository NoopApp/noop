#!/usr/bin/env python3
"""whoop_capture.py — headless WHOOP BLE frame capture for protocol RE, on Linux (BlueZ via bleak).

Scans for a WHOOP strap you own, connects, triggers just-works bonding, subscribes to the strap's
custom notify channels (and the standard Heart Rate profile for a ground-truth cross-check), and
records every complete frame to a JSON file. That file is the bridge to the rest of the workflow:

    whoop_capture.py  →  capture.json  →  whoop-decode (Swift)  /  WhoopProtocol parity tests

The capture format matches the macOS app's frame-export hook exactly: a JSON array of
    {"hex": <frame hex>, "char": <source uuid>, "ts_ms": <unix millis>, "hr": <live bpm or null>}
so frames captured here and on a Mac are interchangeable.

This tool is READ-ONLY with respect to your strap apart from the single bonding handshake every
client must perform; it records data the strap already broadcasts. Use only on a strap you own.

Usage:
    python3 whoop_capture.py --model whoop5 --out capture.json
    python3 whoop_capture.py --model whoop4 --address AA:BB:CC:DD:EE:FF --duration 120

Requires: bleak  (pip install -r requirements.txt)
"""

import argparse
import asyncio
import json
import signal
import time

from bleak import BleakClient, BleakScanner

import whoop_frame as wf

# --- GATT UUIDs (from docs/BLE_REVERSE_ENGINEERING.md) ---------------------------------------------

WHOOP4 = {
    "service": "61080001-8d6d-82b8-614a-1c8cb0f8dcc6",
    "cmd_write": "61080002-8d6d-82b8-614a-1c8cb0f8dcc6",
    "notify": [
        "61080003-8d6d-82b8-614a-1c8cb0f8dcc6",
        "61080004-8d6d-82b8-614a-1c8cb0f8dcc6",
        "61080005-8d6d-82b8-614a-1c8cb0f8dcc6",
    ],
}
WHOOP5 = {
    "service": "fd4b0001-cce1-4033-93ce-002d5875f58a",
    "cmd_write": "fd4b0002-cce1-4033-93ce-002d5875f58a",
    "notify": [
        "fd4b0003-cce1-4033-93ce-002d5875f58a",
        "fd4b0004-cce1-4033-93ce-002d5875f58a",
        "fd4b0005-cce1-4033-93ce-002d5875f58a",
        "fd4b0007-cce1-4033-93ce-002d5875f58a",
    ],
}
HR_MEASUREMENT = "00002a37-0000-1000-8000-00805f9b34fb"   # standard HR (works unbonded)

# --- Capture state --------------------------------------------------------------------------------


class Capture:
    def __init__(self, family: str, out_path: str):
        self.family = family
        self.out_path = out_path
        self.records = []
        self.latest_hr = None
        self.reassemblers = {}     # char uuid -> Reassembler
        self._dirty = 0

    def on_hr(self, _sender, data: bytearray):
        hr = wf.parse_standard_hr(bytes(data))
        if hr is not None:
            self.latest_hr = hr

    def on_frame_notify(self, sender, data: bytearray):
        char = str(getattr(sender, "uuid", sender)).lower()
        ra = self.reassemblers.get(char)
        if ra is None:
            ra = wf.Reassembler(self.family)
            self.reassemblers[char] = ra
        for frame in ra.feed(bytes(data)):
            self.records.append({
                "hex": frame.hex(),
                "char": char,
                "ts_ms": int(time.time() * 1000),
                "hr": self.latest_hr,
            })
            self._dirty += 1
        if self._dirty >= 20:
            self.flush()

    def flush(self):
        if not self.records:
            return
        tmp = self.out_path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.records, f, indent=1)
        import os
        os.replace(tmp, self.out_path)
        self._dirty = 0


# --- Connect + capture ----------------------------------------------------------------------------


async def find_address(cfg, name_filter):
    print(f"scanning for WHOOP service {cfg['service']} …")
    device = await BleakScanner.find_device_by_filter(
        lambda d, ad: (cfg["service"].lower() in [s.lower() for s in (ad.service_uuids or [])])
        or (name_filter and name_filter.lower() in (d.name or "").lower()),
        timeout=20.0,
    )
    return device


async def run(args):
    cfg = WHOOP5 if args.model == "whoop5" else WHOOP4
    cap = Capture(args.model, args.out)

    address = args.address
    if not address:
        device = await find_address(cfg, args.name_filter)
        if device is None:
            print("no WHOOP strap found. Make sure it is awake, near, and not bonded to a phone.")
            return
        address = device.address
        print(f"found {device.name or '?'} @ {address}")

    stop = asyncio.Event()

    async with BleakClient(address) as client:
        print(f"connected: {client.is_connected}")

        # Just-works bond: the protocol bonds via a single CONFIRMED WRITE (the session frame below),
        # not an explicit pairing call — that's how the app does it. An explicit BlueZ pair() actually
        # FAILS on the WHOOP 5 (AuthenticationFailed) and tears down the link, so it is opt-in only.
        if args.pair:
            try:
                await client.pair()
                print("paired")
            except Exception as e:
                print(f"pair() failed (continuing; bond comes from the confirmed write): {e}")

        # Standard HR (unbonded) → ground-truth bpm for correlation.
        try:
            await client.start_notify(HR_MEASUREMENT, cap.on_hr)
            print("subscribed: standard HR (2a37)")
        except Exception as e:
            print(f"standard HR not available: {e}")

        # Subscribe the custom notify channels first, so the post-bond flood is captured.
        for u in cfg["notify"]:
            try:
                await client.start_notify(u, cap.on_frame_notify)
                print(f"subscribed: {u}")
            except Exception as e:
                print(f"could not subscribe {u}: {e}")

        # Open the session / trigger bonding.
        if args.model == "whoop5":
            bond = wf.WHOOP5_CLIENT_HELLO
        else:
            bond = wf.build_command_frame(wf.CMD_GET_BATTERY_LEVEL)
        try:
            await client.write_gatt_char(cfg["cmd_write"], bond, response=True)
            print(f"wrote session/bond frame to {cfg['cmd_write']}: {bond.hex()}")
        except Exception as e:
            print(f"bond/session write failed: {e}")

        # EXPERIMENTAL post-hello probes (WHOOP 5 only): try to coax the strap into streaming by
        # sending candidate puffin commands. The command numbers are UNVERIFIED guesses (4.0 numbers
        # on the 5.0 transport) — all non-destructive reads/toggles. Off unless --probe.
        if args.probe and args.model == "whoop5":
            await asyncio.sleep(1.0)
            probes = [
                (wf.PUFFIN_CMD_TOGGLE_REALTIME_HR, b"\x01", "TOGGLE_REALTIME_HR"),
                (wf.PUFFIN_CMD_SEND_R10_R11_REALTIME, b"\x01", "SEND_R10_R11_REALTIME"),
                (wf.PUFFIN_CMD_GET_CLOCK, b"", "GET_CLOCK"),
                (wf.PUFFIN_CMD_SEND_HISTORICAL_DATA, b"\x00", "SEND_HISTORICAL_DATA"),
            ]
            seq = 2
            for cmd, pl, name in probes:
                frame = wf.build_puffin_command(cmd, seq=seq, payload=pl)
                try:
                    await client.write_gatt_char(cfg["cmd_write"], frame, response=False)
                    print(f"probe → {name} (cmd {cmd}): {frame.hex()}")
                except Exception as e:
                    print(f"probe {name} failed: {e}")
                seq += 1
                await asyncio.sleep(1.5)

        # Capture until Ctrl-C or the optional duration elapses.
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGINT, signal.SIGTERM):
            try:
                loop.add_signal_handler(sig, stop.set)
            except NotImplementedError:
                pass
        print("capturing… (Ctrl-C to stop)")
        try:
            if args.duration:
                await asyncio.wait_for(stop.wait(), timeout=args.duration)
            else:
                await stop.wait()
        except asyncio.TimeoutError:
            pass

        cap.flush()
        print(f"\ncaptured {len(cap.records)} frames → {args.out}")
        chans = {}
        for r in cap.records:
            chans[r["char"]] = chans.get(r["char"], 0) + 1
        for c, n in sorted(chans.items(), key=lambda kv: -kv[1]):
            print(f"  {n:6d}  {c}")


def main():
    p = argparse.ArgumentParser(description="Capture WHOOP BLE frames for protocol RE (Linux/BlueZ).")
    p.add_argument("--model", choices=["whoop4", "whoop5"], default="whoop5",
                   help="strap generation (default: whoop5)")
    p.add_argument("--address", help="BLE MAC address (skip scanning)")
    p.add_argument("--name-filter", help="substring match on advertised name when scanning")
    p.add_argument("--out", default="capture.json", help="output JSON file (default: capture.json)")
    p.add_argument("--duration", type=float, help="stop automatically after N seconds")
    p.add_argument("--probe", action="store_true",
                   help="WHOOP 5 only: after CLIENT_HELLO, send candidate puffin commands (realtime "
                        "toggles + history request) to try to start the biometric stream. Experimental.")
    p.add_argument("--pair", action="store_true",
                   help="also call BlueZ pair() (default off; the confirmed write bonds. The WHOOP 5 "
                        "rejects explicit pair() — leave this off for 5/MG)")
    args = p.parse_args()
    try:
        asyncio.run(run(args))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
