# Linux capture tools

Headless WHOOP BLE **capture + decode** for reverse-engineering the strap protocol on Linux — no Mac,
no GUI. This is the workbench for mapping the WHOOP 5.0 ("puffin") biometric layout (and extending
4.0), using a strap **you own**.

```
  whoop_capture.py ──► capture.json ──► whoop-decode (Swift)  ──► mapped fields
   (bleak / BlueZ)     (shared format)   (WhoopProtocol decoder)
```

The capture file format is **identical** to the macOS app's frame-export hook, so frames captured
here and on a Mac are interchangeable, and both feed the one decoder of record (`WhoopProtocol`) —
no second decoder to drift.

## Status

| Path | State |
|---|---|
| WHOOP 4.0 — capture + decode | ✅ verified on real hardware (frames decode CRC-valid) |
| WHOOP 4.0 — **historical offload** + decode (HR/RR/resp/SpO₂/accel) | ✅ verified on real hardware (`whoop_sync.py` — durable ack-loop drain, thousands of type-47 records) |
| WHOOP 5.0 — bond + `CLIENT_HELLO` session + command set | ✅ verified on real hardware |
| WHOOP 5.0 — historical offload trigger (`SEND_HISTORICAL_DATA`) | ✅ verified (full burst, same trim-cursor mechanism as 4.0) |
| WHOOP 5.0 — historical **biometrics** (type-47 v18) | ✅ unix + HR + R-R + gravity decoded (`parseFrameWhoop5`); cross-validated vs a 4C on the same person/window (HR corr 0.96, ±1 bpm at rest) |
| WHOOP 5.0 — optical channels (PPG/SpO₂/skin-temp) + v26 layout | ⬜ open — kept raw (no on-device ground truth yet) |

See [`../../docs/BLE_REVERSE_ENGINEERING.md`](../../docs/BLE_REVERSE_ENGINEERING.md) §3 for the
protocol details these tools exercise.

## Why this split

| Job | Tool | Why |
|---|---|---|
| BLE transport (scan / bond / subscribe) | **Python + bleak** | Best cross-platform BLE story on Linux/BlueZ; the upstream RE projects are Python too. |
| Decode frames | **Swift `whoop-decode`** | Reuses the *exact* `WhoopProtocol` decoder the app ships — guaranteed parity, zero reimplementation. |

## Requirements

- **Linux with BlueZ** and a BLE adapter (the capture side talks to BlueZ over D-Bus via bleak).
- **Python 3.10+** and `bleak` (`pip install -r requirements.txt`). The framing module and its tests
  are stdlib-only — `bleak` is needed only to actually talk to a strap.
- **A Swift toolchain** (5.9+, any 6.x works) to build `whoop-decode`. `WhoopProtocol` is
  Foundation-only, so it builds on Linux unchanged — no Apple frameworks required.
- A **WHOOP strap you own**, and (for WHOOP 5) the phone's Bluetooth off during capture.

> Tested on **Pop!_OS 24.04** (Ubuntu 24.04 base). Any modern BlueZ-based distro should work; the
> `apt` commands below are for Debian/Ubuntu/Pop!_OS — use your distro's package manager otherwise.

## Setup (first time)

Step by step from a fresh machine. Run these from inside this directory (`tools/linux-capture/`).

```bash
# 1. System packages: Python venv support + BlueZ (Debian/Ubuntu/Pop!_OS)
sudo apt update
sudo apt install -y python3 python3-venv python3-pip bluez

# 2. Create a virtual environment (keeps bleak out of your system Python)
python3 -m venv .venv

# 3. Activate it (do this in every new terminal you use the tool from)
source .venv/bin/activate
#    your prompt now shows (.venv); to leave later, run: deactivate

# 4. Install the Python dependency (bleak)
pip install -r requirements.txt

# 5. Check it imported OK
python3 -c "import bleak; print('bleak ready')"
```

That's it for capturing. To also **decode** captures you need a Swift toolchain (see *Decode* below);
the Python capture side does not require Swift.

> The framing unit tests (`python3 -m unittest`) are stdlib-only and need neither the venv nor `bleak`
> — only live capture from a strap needs the steps above.

## Files

| File | Role |
|---|---|
| `whoop_capture.py` | Scan → connect → bond → subscribe → reassemble → write `capture.json`. `--probe` drives the post-hello command sequence. The RE workbench (whoop5-focused). |
| `whoop_sync.py` | **WHOOP 4.0 durable historical offload.** Connect → drain the on-device store (cmd 22 + `HISTORY_END` ack loop) into a device-scoped SQLite DB with **persist-before-ack** + auto-reconnect/resume. Subcommands: `sync` / `status` / `devices` / `export` / `label`. See [Historical sync](#historical-sync-whoop_syncpy). |
| `whoop_frame.py` | CRC8 / CRC16-Modbus / CRC32, frame builders (`build_command_frame`, `build_puffin_command`), the family-aware `Reassembler`, and the standard-HR parser. Stdlib only. |
| `pair_probe.py` | One-shot WHOOP 5 bonding probe: scan → connect → `pair()` → test `fd4b` access. `python3 pair_probe.py <MAC>`. |
| `test_whoop_frame.py` | Unit tests for framing / reassembly / HR parsing (no `bleak` needed). |
| `requirements.txt` | `bleak` (runtime dep for capture only). |

## Capture (`whoop_capture.py`)

With the venv active (`source .venv/bin/activate` — see [Setup](#setup-first-time)):

```bash
# WHOOP 4.0: scan, connect, bond, record every frame, stop after 2 minutes
python3 whoop_capture.py --model whoop4 --address AA:BB:CC:DD:EE:FF --duration 120
```

It scans for the strap's custom GATT service, performs the bond, subscribes to the custom notify
channels **and** the standard Heart Rate profile (`0x2A37`, works unbonded), reassembles complete
frames, and appends each to `capture.json` as:

```json
{ "hex": "aa01…", "char": "fd4b0005-…", "ts_ms": 1700000000123, "hr": 61 }
```

The live `hr` (from the standard profile) is the **ground-truth cross-check**: find the byte in the
puffin payload that tracks it to locate the 5.0 HR field. `ts_ms` lets you line frames up against
known events.

### WHOOP 5: bonding (do this once)

The WHOOP 5 `fd4b…` characteristics require an **encrypted/bonded** link — without a bond, subscribing
or writing just stalls. The bond is plain just-works, but BlueZ needs a clean slate and the strap's
pairing window. With the **phone's Bluetooth off** (the strap accepts one central at a time):

```bash
export WHOOP_MAC=AA:BB:CC:DD:EE:FF
bluetoothctl remove $WHOOP_MAC     # clear any stale/half bond first — this is the usual fix
# put the strap into pairing mode, then:
bluetoothctl --timeout 8 scan on   # rediscover it
python3 pair_probe.py $WHOOP_MAC   # one just-works pair; the bond then persists
```

A stale bond left from a failed attempt shows up as `pair() → AuthenticationFailed`; `remove` + a
fresh pairing window clears it. Once bonded, the capture below needs no further pairing.

WHOOP's own guidance is to pair only through their app, not the OS Bluetooth menu. For interoperability
with a strap **you own**, the OS-level just-works bond above is sufficient — there is no app-side step.

### WHOOP 5: capture + start the stream

```bash
# bonded already → just capture; --probe sends post-hello commands to start streaming
python3 whoop_capture.py --model whoop5 --address $WHOOP_MAC --probe --duration 60 --out capture.json
```

`--probe` sends the (4.0) command numbers re-framed for puffin after `CLIENT_HELLO`;
`SEND_HISTORICAL_DATA` triggers a full historical offload. Without it you get only the hello response.

## Historical sync (`whoop_sync.py`)

`whoop_capture.py` is the RE workbench (records raw frames; whoop5-focused). `whoop_sync.py` is the
**production offload path** (`--model whoop4|whoop5`): it drives the on-device **historical offload**
to completion and stores the frames durably, so you can pull a day — or a night — of **second-by-second**
biometrics off a strap you own: HR, RR intervals, respiration, SpO₂, skin temperature, and a 3-axis
accelerometer/gravity vector.

- **WHOOP 4.0** — fully working: offload + ack + decode (`whoop-decode` parses the type-47 fields).
- **WHOOP 5.0** — offload transport + ack + durable storage work (puffin framing, `CLIENT_HELLO`).
  The type-47 **v18** record decodes: `unix` @ 15, `heart_rate` @ 22 (stored by the sync), plus R-R
  and gravity via `whoop-decode`. Validated against a 4C worn by the same person in the same window
  (HR corr 0.96, ±1 bpm at rest). The optical channels (PPG/SpO₂/skin-temp) and a less-common **v26**
  record layout are kept raw (`unix`/`hr` = NULL) pending ground truth.

```
  whoop_sync.py sync ─► whoop.db (SQLite, device-scoped) ─► export ─► capture.json ─► whoop-decode
   (bleak / BlueZ)        persist-before-ack + trim cursor     (per device)               (HR/RR/resp/accel)
```

### The offload handshake (verified on real hardware)

1. Connect, subscribe the three `6108` notify channels, and silence the live type-43 raw flood
   (`TOGGLE_REALTIME_HR` / `SEND_R10_R11_REALTIME` off) so it doesn't starve the offload of airtime.
2. Write `SEND_HISTORICAL_DATA` (cmd 22, payload `[0x00]`, confirmed). The strap streams
   `METADATA HISTORY_START` → `HISTORICAL_DATA` (type-47) chunks → `METADATA HISTORY_END`.
3. On each `HISTORY_END`, **persist the chunk, then** ack with `HISTORICAL_DATA_RESULT` (cmd 23,
   payload `[0x01] + end_data`, confirmed), where `end_data` is the 8-byte trim cursor at
   `frame[17:25]`. The ack advances the strap's cursor to the next chunk — **without it the strap
   re-serves the same early chunk forever** and the type-47 records past it never arrive.
4. Loop until `METADATA HISTORY_COMPLETE`.

> WHOOP-4 frame offsets are the verified whoop5 offsets minus 4 (inner record starts at byte 4, not 8):
> inner type `@ frame[4]`, meta_type `@ frame[6]`, record unix `@ frame[11]`, trim cursor `@ frame[17:25]`.

### Durability — persist-before-ack

The ack tells the strap it may **trim (delete)** the acked chunk, so each chunk is committed to SQLite
(`journal_mode=WAL`, `synchronous=FULL` → fsync) **before** its ack is sent: a dropped BLE frame can
never be lost to a trim. The trim cursor is persisted too, so a reconnect **resumes where you left off**
(the strap also remembers; the stored cursor is for the client's own bookkeeping + gap reporting).

### Device scoping

Every frame, label, and cursor is tied to a `devices` row (MAC + advertised name + optional subject).
Multiple straps — or a partner as a test subject — never mix; dedup is **per device**
(`UNIQUE(device_id, hex)`).

### Usage

```bash
# bond once (see "WHOOP 5: bonding" above — the same bluetoothctl pair/trust works for 4.0), then:
python3 whoop_sync.py sync   --model whoop4 --address AA:BB:CC:DD:EE:FF --subject me  --db captures/whoop.db   # drain (resumable)
python3 whoop_sync.py sync   --model whoop5 --address 11:22:33:44:55:66 --subject partner --db captures/whoop.db
python3 whoop_sync.py status  --db captures/whoop.db [--address ..]     # cursor, coverage, counts, labels
python3 whoop_sync.py devices --db captures/whoop.db                    # every strap/subject in the store
python3 whoop_sync.py export  --db captures/whoop.db --address .. --out all.json [--only-type 47]
python3 whoop_sync.py label   --db .. --address .. --activity walking --start 19:58 --end 20:43
python3 whoop_sync.py decode  --db .. --address .. [--full]             # raw frames → the decoded values
```

`sync` auto-reconnects and resumes on a mid-session drop (up to `--max` seconds); it stops on
`HISTORY_COMPLETE`, on `--idle` seconds with no offload frame, or after two dry reconnects (store
drained / strap asleep). Re-run any time to continue — the cursor is durable. Times for `label`
accept epoch seconds, ISO-8601, or `HH:MM` (today).

> **The strap must be advertising to connect.** A bonded strap that BlueZ already auto-connected is
> *not* advertising, so `sync` force-disconnects and scans for the device object before connecting
> (and retries). If the strap has been idle a while it sleeps — nudge it (move it / pull it off the
> charger) so it advertises again; a central cannot wake a sleeping peripheral.

### SQLite schema

| Table | Columns | Purpose |
|---|---|---|
| `devices` | `id, address, name, subject, model` | one row per strap / subject |
| `frames` | `device_id, recv_ms, char, inner_type, unix, hr, hex` | every frame; deduped `UNIQUE(device_id, hex)` |
| `sync_state` | `(device_id, k) → v` | per-device `last_trim` cursor, coverage range, `history_complete` |
| `labels` | `device_id, start_unix, end_unix, activity, note` | activity labels for analysis |

Feed `export`'s `capture.json` to `whoop-decode` (below) to turn the synced frames into decoded
HR / R-R / respiration / accelerometer fields for downstream analysis.

### Decoded values (`decode_features.py`) — raw frames → the actual readings

`sync` stores raw frames (hex) durably, but hex isn't usable directly. The decode stage turns those
frames into **per-second value tables in the same DB**, so you have the actual readings — HR, R-R,
gravity, skin-temperature, PPG, events — pulled straight out of the raw WHOOP data. It runs
automatically as the **last stage of `sync`**, and standalone:

```bash
python3 whoop_sync.py decode --db captures/whoop.db --address AA:BB:..          # decode new frames since last run
python3 whoop_sync.py decode --db captures/whoop.db --address AA:BB:.. --full   # re-decode everything
```

**It reuses the Swift `whoop-decode` as the one decoder of record — it does _not_ re-implement
decoding in Python.** The bridge shells out to `whoop-decode --json`, maps the decoded fields into the
tables below, and stores nothing the decoder didn't produce. So the iOS/macOS/Android apps, the CLI,
and this decode step can never drift on frame offsets: there is exactly one decoder, verified against
real hardware. The decode cursor lives in `sync_state` (`last_decoded_frame_id`), so a run only decodes
**new** frames; re-runs are **idempotent**.

**Why this development matters for the synced data.** The raw offload is the *irreplaceable* part —
once the strap acks a chunk it may **trim (delete) it** — so capture must never be blocked or risked.
Decoding is the *rebuildable* part (features can always be re-derived from `frames`). The bridge
respects that split: decode runs **after** the offload fully drains, never inside the persist-before-ack
loop, and is **best-effort** — if `whoop-decode` isn't built or errors, the raw frames are already safe
and `sync` still succeeds; just re-run `decode`. The payoff: one `sync` leaves the DB with **both** the
durable raw frames **and** a complete, query-ready decoded view — the bridge between "we captured it"
and "we can learn from it". Without it, every consumer would have to re-export and re-decode the hex
themselves and risk diverging on the offsets.

#### Tables

| Table | Key | One row per |
|---|---|---|
| `feat_second` | `(device_id, unix)` | second — the wide design matrix |
| `feat_rr` | `(device_id, unix, idx)` | R-R interval within a second |
| `feat_ppg` | `(device_id, unix, sample_idx, channel)` | optical sample (WHOOP 5 v26, 24/sec) |
| `feat_event` | `(device_id, unix, kind)` | strap event |

#### Column reference (what each value means, as far as verified)

`feat_second` — one row per second; the decoded values for that second:

| Column | Unit / type | Meaning & caveats |
|---|---|---|
| `device_id` | int (FK `devices.id`) | which strap / subject this second belongs to |
| `unix` | UTC seconds | timestamp, from the **decoder's** `unix` field (authoritative across record versions; v26 frames carry NULL `frames.unix`, so we never rely on the row's column) |
| `hr` | bpm (u8) | heart rate. Sensor-startup/no-contact `hr==0` is stored as **NULL**, not 0, so it can't drag down averages |
| `gx`, `gy`, `gz` | g (float) | accelerometer / gravity vector; magnitude ≈ 1.0 at rest. The dominant **motion** signal for activity recognition |
| `rr_count` | int | number of beat-to-beat (R-R) intervals decoded in this second; NULL when none |
| `rr_mean_ms` | ms | mean R-R interval (≈ 60000/`hr`) |
| `rmssd` | ms | root-mean-square of successive R-R differences — standard short-window **HRV**; NULL when `rr_count` < 2 |
| `spo2_red`, `spo2_ir` | raw ADC counts | red & IR optical channel intensities. **Not a blood-oxygen %** — the red/IR ratio underlies SpO₂, but we store raw counts (no calibration invented). WHOOP 4 (v24) only |
| `skin_temp_raw` | raw ADC | skin-temperature sensor reading. **Not °C** — absolute raw count (the app derives a personal-baseline deviation; we keep the raw value). WHOOP 4 (v24) only |
| `resp_raw` | raw ADC | respiration-related raw reading. WHOOP 4 (v24) only |
| `record_version` | int | source record layout: **24** = WHOOP 4; **18 / 26** = WHOOP 5. Tells the consumer which columns are real vs NULL for this row |

> **Provenance via NULLs.** WHOOP 5 **v18** leaves the optical region unmapped (no verified offsets), so
> `spo2_*` / `skin_temp_raw` / `resp_raw` are **NULL** there; WHOOP 4 **v24** fills them. Per project rule
> we never invent offsets — an honest NULL beats a fabricated number.

`feat_rr` — individual beat-to-beat intervals (for HRV beyond the per-second summary):

| Column | Unit | Meaning |
|---|---|---|
| `idx` | int | position of the interval within its second (0 … `rr_count`-1) |
| `rr_ms` | ms | one R-R (inter-beat) interval |

`feat_ppg` — the WHOOP 5 **v26** optical photoplethysmography waveform (the raw pulse signal):

| Column | Unit | Meaning |
|---|---|---|
| `sample_idx` | int 0–23 | position within the 24-sample (≈ 24 Hz) burst for that second |
| `channel` | int | raw optical channel id as the decoder reports it. **No colour claim** — which physical LED (green/red/IR) each id maps to is unverified, so the raw id is surfaced as-is |
| `value` | relative ADC (signed) | one waveform sample. A **relative** optical intensity (AC+DC, uncalibrated) — useful for pulse shape / HR / perfusion features, **not** an absolute measurement |

`feat_event` — strap lifecycle events (useful for non-wear masking and context):

| Column | Type | Meaning |
|---|---|---|
| `kind` | text | event label as the decoder names it, e.g. `BLE_CONNECTION_UP(11)`, `BATTERY_LEVEL(3)`; events this firmware emits that the schema doesn't name stay raw, e.g. `0x7B(123)` (never cross-borrowed from another enum) |
| `event_num` | int / NULL | numeric event id when the decoder emits a number; NULL when `kind` is a named string |
| `payload_json` | text (JSON) | the event's remaining decoded fields (e.g. battery `soc`/`mv`), keys sorted |

> The decoded-value tables are **derived state** — delete them any time and rebuild with `decode --full`; the
> raw `frames` are the source of truth. Join `feat_second` to `labels` on `unix` for a labelled training set.

## Decode (`whoop-decode`)

Built from the `WhoopProtocol` Swift package (builds on Linux — Foundation only):

```bash
cd ../../Packages/WhoopProtocol
swift build --product whoop-decode
BIN=.build/debug/whoop-decode

$BIN capture.json                  # decode (family auto-detected per frame from `char`)
$BIN --raw-only capture.json       # only frames that did NOT fully decode — your RE worklist
$BIN --json capture.json           # machine-readable, for piping into your own analysis
$BIN --family whoop5 --hex aa0108000001e67123019101363e5c8d   # one frame ad hoc
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `pair() → AuthenticationFailed` | Stale/half bond in BlueZ, or strap not in its pairing window | `bluetoothctl remove <MAC>`, re-enter pairing mode, retry |
| Connect hangs (no `connected: True`) | Phone holds the strap (one central at a time) | Turn the **phone's Bluetooth off** / move it away |
| `start_notify` / write to `fd4b…` hangs | Not bonded — those chars need an encrypted link | Bond first (see *WHOOP 5: bonding*) |
| Bonded but only the hello response, no stream | No post-hello command sent | Add `--probe` |
| Not found in scan | Strap asleep / advertising window closed | Wake/charge-tap the strap; for WHOOP 5 re-enter pairing mode |
| `BleakClient(addr)` hangs right after `bluetoothctl remove` | BlueZ forgot the device | Scan first so it's rediscovered (the tools do this) |

## Safety & scope

- **Read-only with respect to your strap**, apart from the bonding handshake every BLE client must
  perform. These tools record data the strap already broadcasts.
- The only frames written are the **session/bond handshake** and, under `--probe`, a small set of
  **non-destructive** read/toggle commands (`GET_CLOCK`, `TOGGLE_REALTIME_HR`, `SEND_R10_R11_REALTIME`,
  `SEND_HISTORICAL_DATA`) — all part of the curated command set described in the project's BLE safety
  contract. No firmware/reboot/ship-mode/DFU commands are sent.
- **`whoop_sync.py` additionally sends `HISTORICAL_DATA_RESULT` (cmd 23), the offload ack.** This
  advances the strap's trim cursor, which causes the strap to **trim (delete) historical chunks it has
  already served** — exactly the same housekeeping WHOOP's own app performs on every sync, not a wipe
  of device function. Because the ack is destructive *to the on-strap copy*, the tool commits each
  chunk to disk **before** acking it (persist-before-ack), and the data lives on in the local DB.
- Use only on **hardware you own**. Capture files contain your strap's serial / a session token /
  its MAC — they are git-ignored and should not be shared.
- "WHOOP" is used **nominatively** to name the hardware. These tools contain no WHOOP code or assets.

## Contributing captures back

A `capture.json`'s `hex` values are a drop-in for the parity fixtures in
`Packages/WhoopProtocol/Tests/WhoopProtocolTests/Resources/frames.json`. When you map a new WHOOP 5.0
field, add the offset to `parseFrameWhoop5` / `whoop_protocol.json` and back it with a real capture —
the project rule is *real captures, never invented offsets*.

## Tests

```bash
python3 -m unittest -v          # framing / reassembly / HR parse (stdlib only, no bleak needed)
```

The framing is cross-checked against the Swift decoder: a `GET_BATTERY_LEVEL` frame built by
`build_command_frame()` and a puffin frame built by `build_puffin_command()` each decode with
`ok=true` and both CRCs valid via `whoop-decode`.

## Credits

The protocol understanding these tools exercise builds on prior community reverse-engineering —
`johnmiddleton12/my-whoop` (WHOOP 4.0) and `b-nnett/goose` (WHOOP 5.0). See
[`../../ATTRIBUTION.md`](../../ATTRIBUTION.md).
