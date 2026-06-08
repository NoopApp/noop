# BLE Reverse Engineering

How NOOP talks to a WHOOP strap directly over Bluetooth Low Energy — no WHOOP cloud and no account.
This document explains how the strap's private GATT protocol was understood, how the
frame format and checksums work, how WHOOP 4.0 ("Harvard") and WHOOP 5.0 ("puffin") differ, what each
data stream contains, and how to extend the decoder for new packet types or sensors.

> **Interoperability, not impersonation.** NOOP is a companion app for a strap *you own*. It reads the
> data *your* device already records and stores it locally on *your* machine. Nothing here replicates,
> circumvents, or interoperates with WHOOP's servers.
>
> **Not affiliated with WHOOP. Not a medical device.** "WHOOP" is used only to identify the hardware
> this app interoperates with. The decoded values are raw or locally-computed estimates and must not be
> used for any medical purpose.

---

## Credits

The protocol understanding in this codebase builds directly on two community reverse-engineering
projects, and the Swift code ports their findings:

| Project | Generation | What it contributed |
|---|---|---|
| **`johnmiddleton12/my-whoop`** | WHOOP 4.0 | The `61080001…` GATT service, the `0xAA` CRC8/CRC32 frame envelope, the command numbers, and the type-40/43/47 stream layouts. |
| **`b-nnett/goose`** | WHOOP 5.0 | The `fd4b0001…` GATT service, the CRC16-Modbus header check, the static `CLIENT_HELLO` frame, and the "puffin" packet types. |

Where a function or constant is a direct transcription, the source file says so (e.g.
`crc16Modbus` in `Framing.swift` is noted as *"Ported verbatim from the Goose reverse-engineering"*,
and `DeviceFamily.whoop5ClientHello` is transcribed from `GooseHello.clientHelloFrameHex`). Sensor
scale factors and field offsets were additionally re-verified on a real WHOOP 4.0 strap (see the
on-device verification notes embedded in `Resources/whoop_protocol.json`).

---

## Where the code lives

The reverse-engineering logic is split between a platform-pure Swift package and the macOS app's BLE
engine:

| File | Role |
|---|---|
| `Packages/WhoopProtocol/Sources/WhoopProtocol/Framing.swift` | CRC8 / CRC32 / CRC16-Modbus, `verifyFrame`, `Reassembler`. |
| `Packages/WhoopProtocol/Sources/WhoopProtocol/DeviceFamily.swift` | WHOOP 4 vs 5 UUIDs, header-CRC kind, `CLIENT_HELLO`, puffin type aliases. |
| `Packages/WhoopProtocol/Sources/WhoopProtocol/Interpreter.swift` | `parseFrame` — envelope → annotated fields + a flat `parsed` dict. |
| `Packages/WhoopProtocol/Sources/WhoopProtocol/PostHooks.swift` | Per-type decoders for irregular layouts (raw IMU/optical, type-47 DSP record, events, metadata). |
| `Packages/WhoopProtocol/Sources/WhoopProtocol/Streams.swift` / `HistoricalStreams.swift` | Parsed frames → durable rows (`HRSample`, `SpO2Sample`, …). |
| `Packages/WhoopProtocol/Sources/WhoopProtocol/Resources/whoop_protocol.json` | The data-driven schema: packet types, enums, field offsets, sensor scales. |
| `Strand/BLE/BLEManager.swift` | CoreBluetooth engine: scan → connect → **bond** → subscribe → reassemble → route. |
| `Strand/BLE/Commands.swift` | The curated, **safe** command set (`WhoopCommand`) and the frame builder. |
| `Strand/BLE/FrameRouter.swift` | Pure decode → live UI state (HR, events, double-tap, wrist on/off). |

The `WhoopProtocol` package never imports CoreBluetooth — it exposes UUIDs as plain strings so the
protocol code runs unchanged in tests and CLI tools. Only `BLEManager` turns those strings into
`CBUUID`s.

---

## 1. The discovery approach

WHOOP straps do not expose their physiological data through any standard BLE profile. They advertise a
**hidden, vendor-specific GATT service** alongside the two standard ones, and the interesting data only
flows after a quiet bonding step.

### The GATT layout (WHOOP 4.0)

The custom service and its characteristics are the authoritative anchors of the whole protocol
(`BLEManager.swift`):

```text
Custom service  61080001-8d6d-82b8-614a-1c8cb0f8dcc6
  ├─ 61080002…  CMD write     ← app writes command frames here
  ├─ 61080003…  CMD notify    → command responses
  ├─ 61080004…  EVENT notify  → events (wrist on/off, double-tap, battery, alarms…)
  └─ 61080005…  DATA notify   → fragmented data frames (the big payloads)

Standard Heart Rate  180D / 2A37   → HR + R-R, works UNBONDED (1 Hz)
Standard Battery     180F / 2A19   → battery percent
```

The two standard services (`180D` heart rate, `180F` battery) are a useful sanity check: the standard
`2A37` Heart Rate Measurement characteristic streams HR and R-R intervals at ~1 Hz **without bonding**,
which made it the reliable baseline while the custom channels were being mapped. NOOP still treats
`2A37` as the *reliable* HR/R-R source and lets the custom streams supply everything else (see
`parseStandardHR` in `BLEManager.swift`).

### The single confirmed-write bond

The custom notify characteristics (`…0003/0004/0005`) stay silent until the link is bonded. The key
discovery is that **one "with-response" (confirmed) write is enough** to trigger iOS/macOS just-works
bonding — there is no PIN, no pairing UI. NOOP performs this with a benign `GET_BATTERY_LEVEL`
(`didDiscoverCharacteristicsFor` in `BLEManager.swift`):

```swift
// THE BONDING TRICK: one confirmed write triggers just-works bonding.
// GET_BATTERY_LEVEL is benign and what the Mac prototype uses.
let bondFrame = WhoopCommand.getBatteryLevel.frame(seq: seq, payload: [0x00])
peripheral.writeValue(Data(bondFrame), for: c, type: .withResponse)
```

When `didWriteValueFor` fires with no error, the link is bonded and the custom channels begin to flow.
A subtlety learned the hard way: `didWriteValueFor` re-fires on **every** `.withResponse` write (the
bond write, every historical request, every chunk ack), so the connect handshake is gated behind a
`connectHandshakeDone` flag — re-running `HELLO`/`SET_CLOCK` mid-offload was found to make the strap
stop serving historical data.

### The connect handshake

Once bonded, NOOP runs a WHOOP-faithful lifecycle exactly once
(`didWriteValueFor` → handshake block):

1. `GET_HELLO_HARVARD` (35) + `GET_ADVERTISING_NAME_HARVARD` (76) — greet the strap.
2. `SET_CLOCK` (10) — set the strap RTC to UTC (8-byte `[seconds u32 LE][subseconds u32 LE]`).
   A *wrong-length* SET_CLOCK is ack'd but not latched, which leaves the RTC lost and the strap
   refuses to serve history — a real bug found and fixed here.
3. `GET_CLOCK` (11) with an **empty** payload — establishes the device↔wall clock correlation.
4. `SEND_R10_R11_REALTIME` (63) with `[0x00]` — **disables** the raw realtime flood (see §4).
5. `GET_DATA_RANGE` (34) — read the strap's stored data window for the liveness watchdog.
6. After a short settle, request the historical offload (`SEND_HISTORICAL_DATA`).

---

## 2. The frame format (CRC framing)

Every custom-channel message is a length-prefixed, double-checksummed frame. The format was confirmed
against `my-whoop`'s `WhoopPacket.framed_packet` and is implemented in `Commands.swift`
(`frame(seq:payload:)`) and validated in `Framing.swift` (`verifyFrame`).

### WHOOP 4.0 envelope

```text
┌──────┬───────────┬──────┬───────┬──────┬──────┬───────────┬────────────┐
│ 0xAA │ len u16 LE │ crc8 │ type  │ seq  │ cmd  │ payload…  │ crc32 LE   │
│ [0]  │ [1..3]     │ [3]  │ [4]   │ [5]  │ [6]  │ [7..len]  │ [len..+4]  │
└──────┴───────────┴──────┴───────┴──────┴──────┴───────────┴────────────┘
        \_______ crc8 over these 2 length bytes _______/
                           \________ crc32 (zlib) over [type][seq][cmd][payload] _______/
```

- **SOF** is `0xAA`.
- **`len`** = `(3 + payload.count) + 4` — the inner `[type][seq][cmd][payload]` length plus the 4-byte
  CRC32 trailer. Total frame length on the wire is `len + 4`.
- **`crc8`** (poly `0x07`, table in `Framing.swift`) guards **only the two length bytes** — a cheap
  header integrity check that lets the reassembler trust the declared length.
- **`crc32`** is standard zlib CRC-32 (reflected, poly `0xEDB88320`) over the inner bytes.

`type` is the packet type (see §5), `cmd` is the command/event number, `seq` is a rolling sequence
byte (and, for historical records, doubles as the **record version** — see §3).

### Reassembly

BLE delivers frames in MTU-sized fragments. The `Reassembler` (`Framing.swift`) accumulates bytes,
finds the `0xAA` SOF, reads the `len` field, and only emits a frame once `len + 4` bytes are present.
`BLEManager.didUpdateValueFor` feeds every custom-channel notification through it before routing.

### WHOOP 5.0 envelope

WHOOP 5.0 changed the header and swapped the header checksum for CRC16-Modbus
(`verifyFrameWhoop5` / `parseFrameWhoop5`):

```text
[0]   0xAA SOF
[1]   format byte (0x01)
[2-3] declaredLength u16 LE   (= payload length + 4)
[4-5] header bytes
[6-7] CRC16-Modbus over frame[0..<6]  (poly 0xA001, init 0xFFFF, reflected), u16 LE
[8..] inner record: [type][seq][cmd][data…]
tail  CRC32 (zlib, LE) over the payload, 4 bytes
total = declaredLength + 8
```

The inner record (`[type][seq][cmd][data…]`) starts at **offset 8** instead of offset 4, and the
payload CRC32 is unchanged from 4.0. The whole 4-vs-5 difference is funnelled through one switch:
`DeviceFamily.headerCRCKind`.

---

## 3. WHOOP 4 (Harvard) vs WHOOP 5 (puffin)

`DeviceFamily` (`DeviceFamily.swift`) is the single enum that captures every hardware-generation
difference. The family-aware `verifyFrame(_:family:)` and `parseFrame(_:family:)` overloads branch on
it; the `whoop4` path is byte-for-byte identical to the original no-family functions (back-compat).

| Aspect | WHOOP 4.0 (`whoop4`, "Harvard") | WHOOP 5.0 (`whoop5`, "puffin") |
|---|---|---|
| GATT service | `61080001-8d6d-82b8-614a-1c8cb0f8dcc6` | `fd4b0001-cce1-4033-93ce-002d5875f58a` |
| Characteristics | `…0002`–`…0005` | `fd4b…0002`–`0005` **plus** `…0007` |
| Header check | CRC8 (poly `0x07`) over the 2 length bytes | CRC16-Modbus over `frame[0..<6]` |
| Inner record offset | byte 4 | byte 8 |
| Session start | confirmed-write bond, then `GET_HELLO_HARVARD` | static `CLIENT_HELLO` frame |
| Extra packet types | — | "puffin" types 37/38/53/54/56 |

### The WHOOP 5.0 `CLIENT_HELLO`

WHOOP 5.0 starts a session by writing a fixed 16-byte command frame (transcribed from Goose):

```text
AA 01 08 00 00 01 E6 71 23 01 91 01 36 3E 5C 8D
```

This is a fully-formed type-35 COMMAND frame with a valid CRC16-Modbus header and CRC32 trailer,
exposed as `DeviceFamily.whoop5ClientHello`.

### Bonding and the puffin session (hardware-verified)

Confirmed against a real WHOOP 5 strap using the Linux capture tooling in `tools/linux-capture/` (a
`bleak`/BlueZ capture feeding the `whoop-decode` CLI). The notes below supersede the earlier
"unverified on MG hardware" caveats for the connect path.

**The `fd4b…` service requires an encrypted link.** Unlike WHOOP 4.0 — whose custom characteristics
are readable after a plain confirmed write — every `fd4b` operation (subscribing to a notify channel,
writing to `fd4b0002`) needs the link to be **bonded** first. Without a bond the operation simply
stalls while the stack waits for an encryption that never arrives. So the 5.0 session has a step the
4.0 does not: establish a BLE bond *before* anything else.

**The bond is "just works"** — no PIN, no passkey, no OOB. On Apple, CoreBluetooth performs it
transparently the first time an encrypted characteristic is touched (no strap screen, nothing to
confirm). On Linux it was reproduced with standard pairing: clear any stale bond, put the strap in
pairing mode, then pair — `Pair()` completes in ~0.2 s and the bond persists, after which connecting
needs no further pairing. WHOOP's own guidance is to pair only through the app and *not* via the OS
Bluetooth menu; for interoperability with a strap **you own**, an OS-level just-works bond is
nonetheless sufficient — no app-side step is required. (The strap holds one central at a time, so the
phone must be disconnected first; the firmware logs a `BLE Bond failure` for a contended attempt.)

**How NOOP's macOS app triggers it (v1.5):** it writes `CLIENT_HELLO` to `fd4b0002` *with response*.
That single confirmed write makes CoreBluetooth bring up the just-works bond *before* the puffin notify
subscriptions are attempted — without it those subscriptions are rejected with *"Authentication is
insufficient"* and the handshake hangs at "Finishing the secure pairing handshake…" forever (issue #17).

**Once bonded, the session mirrors 4.0** on the new transport:

1. Subscribe `fd4b0003/0004/0005/0007`.
2. Write `CLIENT_HELLO` to `fd4b0002`. The strap replies with two `COMMAND_RESPONSE` (GET_HELLO, cmd
   145) frames carrying the device serial and a session token.
3. Drive the strap with **the 4.0 command numbers, re-framed for puffin** (`puffinCommandFrame` in
   `Framing.swift`). Verified on hardware: `SEND_HISTORICAL_DATA` (22) starts a full historical
   offload — trim-cursor acks, `History burst success`, `Historical Dump Complete`, exactly the §5
   4.0 mechanism; `GET_CLOCK` (11), `TOGGLE_REALTIME_HR` (3) and `SEND_R10_R11_REALTIME` (63) are all
   accepted. The puffin command set is therefore the 4.0 set on the 5.0 transport, not a new one.

**`CONSOLE_LOGS` (type 50) are plaintext firmware logs.** The 5.0 emits them freely, and they narrate
the command flow in clear text (`HELLO: Send hello packet`, `Command Send Historical Data`, `History
burst success. Trim: 0x00000010:0001b635 (16:112181)`, `Historical Dump Complete`, `PullStats:
Data: 5, Events: 279, Bytes: 21292`). They are a useful cross-check when mapping the rest of the
protocol.

### "Puffin" packet types

WHOOP 5.0 introduces parallel packet types that carry the same semantics on the new transport. Rather
than decode them separately, `canonicalTypeName` aliases them onto their 4.0 equivalents so they never
fall through to "unknown":

| Puffin type | Aliased to |
|---|---|
| 38 `PUFFIN_COMMAND_RESPONSE` | `COMMAND_RESPONSE` (36) |
| 56 `PUFFIN_METADATA` | `METADATA` (49) |

> WHOOP 5.0 framing, the hello, the puffin aliases, the bond/session handshake and the command set
> are implemented and now hardware-verified (see "Bonding and the puffin session" above): the strap
> bonds, accepts the 4.0 command numbers, and performs a full historical offload, all decoding
> CRC-valid. The 5.0 **biometric field offsets** are now mapped from real captures too — live
> `REALTIME_DATA` (§5) and the historical type-47 record (version 18, §5) both decode HR / R-R /
> gravity, validated against ground truth. Capture with `tools/linux-capture/whoop_capture.py
> --history-only --history-ack` and decode with `whoop-decode`.

---

## 4. The realtime "R10/R11" raw stream (type 43)

`REALTIME_RAW_DATA` (packet type **43**, internally "R10/R11") is the strap's high-rate raw sensor
stream. On the WHOOP 4.0 firmware it streams **continuously and unprompted** at roughly 2 packets per
second once the link is up — and each packet is large (~1.9 KB). Two variants have been mapped,
distinguished by payload length (`PostHooks.swift` `raw_data` hook + the `variants` table in
`whoop_protocol.json`):

| Payload len | Kind | Contents |
|---|---|---|
| 1917 | `imu` | HR byte + R-R + **6 IMU axes** (accelX/Y/Z, gyroX/Y/Z), 100 signed-`i16` LE samples/axis @ ~100 Hz |
| 1921 | `optical` | A single AC-coupled PPG waveform: ~419 `s24` LE samples @ ~437 Hz, stride 4 |

The IMU variant is well-characterised and on-device-verified:

- **Accel** scale `1/4096` g/LSB (sphere-fit `|g| ≈ 0.99`, residual 0.0%).
- **Gyro** scale `2000/32768 = 0.06104` deg/s/LSB → full-scale ±2000 dps, verified with controlled
  720° rotations.
- Axes live at frame offsets `accelX@89, accelY@289, accelZ@489, gyroX@692, gyroY@892, gyroZ@1092`.
- Roughly 36% of the frame (a header gap and a tail from offset 1292) is **still unmapped** and kept
  raw — an honest gap, not an invented field.

### Why NOOP disables it on connect

The type-43 flood is expensive on two axes the strap can't spare:

- **BLE airtime** — at ~2 × 1.9 KB/s it dominates the connection and starves the historical offload.
- **Strap flash** — keeping the raw stream on blocks dense biometric retention and disconnected
  operation.

The real control is **not** `STOP_RAW_DATA` (82), which doesn't affect this stream — it is
`SEND_R10_R11_REALTIME` (63). Sending it with `[0x00]` on connect stops the flood (verified on-device:
2.1/s → 0/s, and it **persists across reconnect**). This is part of the handshake:

```swift
send(.sendR10R11Realtime, payload: [0x00])   // stop the type-43 realtime flood (BLE airtime/battery)
```

Because the flood can resume, the backfill idle-watchdog deliberately ignores type-43/40 frames and
only re-arms on genuine offload frames (`BLEManager.isOffloadFrame` → types 47/48/49/50). With the raw
stream off, NOOP's primary metric source becomes the **historical offload** (next section).

### On-demand raw capture

For research, raw IMU can be captured for a bounded window with `captureRawAccel(seconds:)`, which
sends `START_RAW_DATA` (81) + `TOGGLE_IMU_MODE` (106), records for the window, then re-issues
`STOP_RAW_DATA` and disables the stream again. This is opt-in only; the global research toggle
(`enableRawCapture`) defaults **off** and the app is decoded-only otherwise.

---

## 5. Packet types and the historical store

Packet types come from the `PacketType` enum in `whoop_protocol.json`:

| Type | Name | Notes |
|---|---|---|
| 35 | `COMMAND` | App → strap. |
| 36 | `COMMAND_RESPONSE` | Strap → app (battery, clock, version, data range). |
| 37/38 | `PUFFIN_COMMAND` / `…_RESPONSE` | WHOOP 5.0. |
| 40 | `REALTIME_DATA` | Live HR + R-R (1 Hz). |
| 43 | `REALTIME_RAW_DATA` | The raw IMU/optical flood (§4). |
| 47 | `HISTORICAL_DATA` | The 14-day biometric store (below). |
| 48 | `EVENT` | Wrist on/off, double-tap, battery, alarms. |
| 49 | `METADATA` | Chunk boundary + trim cursor. |
| 50 | `CONSOLE_LOGS` | Firmware log text. |
| 51–56 | IMU streams / puffin events / puffin metadata | WHOOP 5.0 / extended. |

### The type-47 biometric record

`HISTORICAL_DATA` is the durable, DSP-processed 14-day store and the heart of offline operation. It is
re-offloaded periodically (~every 15 min while connected), mirroring how the official app syncs. Each
record's **version is the `seq` byte** (`frame[5]`); the schema resolves it via `versions`. Version 24
(the WHOOP 4.0 DSP record) is verified against 762 real device records and decodes a full sensor block
(`PostHooks.swift` `historical_data` hook + the v24 layout in `whoop_protocol.json`):

| Offset | Field | Sensor / meaning |
|---|---|---|
| 11 | `unix` (u32) | Real unix seconds — no clock offset needed. |
| 21 | `heart_rate` (u8) | bpm. |
| 22 | `rr_count` (u8) | Number of R-R intervals that follow. |
| 33 / 35 | `ppg_green` / `ppg_red_ir` (u16) | Optical LED ADCs. |
| 40/44/48 | `gravity_x/y/z` (f32) | Accel-derived gravity vector (g). |
| 55 | `skin_contact` (u8) | 0 = off-wrist (capacitive). |
| 56/60/64 | `gravity2_x/y/z` (f32) | Second accel/gravity triplet. |
| 68 / 70 | `spo2_red` / `spo2_ir` (u16) | Raw ADC; SpO₂ % computed locally. |
| 72 | `skin_temp_raw` (u16) | Raw ADC; °C computed locally. |
| 74 / 76 / 78 | `ambient`, `led_drive_1/2` (u16) | Optical config. |
| 80 | `resp_rate_raw` (u16) | Raw; respiratory rate computed locally. |
| 82 | `signal_quality` (u16) | DSP quality. |

Versions 5/7/9 are generic HR/R-R-only records with no DSP sensor block; version 12 shares the v24
layout. `extractHistoricalStreams` (`HistoricalStreams.swift`) turns these into the typed rows
(`HRSample`, `SpO2Sample`, `SkinTempSample`, `RespSample`, `GravitySample`, …). The raw ADCs are kept
as-is (`unit: "raw_adc"`) — SpO₂ %, skin temperature in °C, and respiratory rate are derived later in
`StrandAnalytics`, on-device, never on a server.

### Safe offload + trim

The strap streams `HISTORY_START → type-47 records → METADATA (HISTORY_END) → … → HISTORY_COMPLETE`.
Each `METADATA` chunk carries a **`trim_cursor`** (u32 at frame offset 17). NOOP persists the decoded +
raw rows first, then sends `HISTORICAL_DATA_RESULT` (23) as a confirmed write echoing the chunk's
`end_data` — only then may the strap forget that chunk. This makes the offload resumable: the durable
`strap_trim` cursor means the next session resumes exactly where the last one stopped.

### WHOOP 5.0 historical offload (hardware-verified)

The ack is not just for resumability on WHOOP 5 — **it is what makes the offload progress at all.**
Confirmed on a real worn WHOOP 5 (latest firmware) via `tools/linux-capture/`:

- **Without acking**, the strap re-serves the *same* early chunk forever. Across 16 deterministic
  re-requests the `trim_cursor` stayed frozen at `112193` and **zero** type-47 records arrived — only
  `CONSOLE_LOGS`, small `EVENT`s and `METADATA` (HISTORY_START/END).
- **With the chunk-ack handshake** — parse each `HISTORY_END`'s 8-byte `end_data` (trim u32 + next
  u32) and write it back in a `HISTORICAL_DATA_RESULT` (23) confirmed write — the cursor walks forward
  (`112193 → 112195 → … → 112474`) and the DSP records pour out. One 90 s capture pulled **3193**
  CRC-valid type-47 frames. (`whoop_capture.py --history-only --history-ack`.)

On WHOOP 5 the metadata fields sit at the 4.0 offsets **+4** (the envelope shift): `meta_type` at 10,
`trim_cursor` at 21, `end_data` = `frame[21:29]`.

### The WHOOP 5.0 type-47 record (version 18)

The historical record's version byte is `frame[9]` on WHOOP 5 (the +4 image of the 4.0 `frame[5]`).
Real WHOOP 5 hardware on the **latest firmware** emits **version 18 (124-byte)** — **not** the 4.0
**v24** layout documented above, and **not** v24 shifted by +4. The repo schema does not contain v18;
this device's firmware revision simply uses a different layout, and a naive "v24 + 4" decodes to
garbage (HR `0`, gravity overflow). The fields below were read off real frames at their **absolute
5.0 offsets** and cross-checked physiologically, never assumed (`decodeWhoop5Historical` in
`Interpreter.swift`, parity test `Whoop5HistoricalTests.swift`):

| Offset | Field | Validation |
|---|---|---|
| 9 | `hist_version` (u8) = 18 | discriminates the layout |
| 15 | `unix` (u32) | monotonic, +1 s |
| 22 | `heart_rate` (u8) | **matched the 2A37-verified live HR exactly at all 96 overlapping timestamps** (mean \|Δ\| 0.00 bpm); note this is v24's `21`+1, **not** +4 |
| 23 | `rr_count` (u8) | matches #valid R-R intervals 100 % (1141/1143) |
| 24 + 2·i | `rr[i]` (u16, ms) | 60000/mean(R-R) ≈ HR for 88 % (rest are HR-averaging) |
| 45 / 49 / 53 | `gravity_x/y/z` (f32, g) | \|g\| ≈ 1.0 for 100 % of 500 records; v18 has **one** triplet (not v24's two) |

The strongest check on the HR offset: where a historical record and a live `REALTIME_DATA` (§5, 2A37
ground-truth-verified) frame share a timestamp, the historical HR equalled the live HR at **96/96**
samples — so HR@22 is anchored to hardware ground truth, not just internally consistent.

PPG / SpO₂ / skin-temp live further in the 124-byte record but lack on-device ground truth, so they
are left as a single raw region rather than guessed (project rule: real captures, never invented
offsets). The decoded fields feed the existing `extractHistoricalStreams` path unchanged, so WHOOP 5
historical HR / HRV / gravity land in the datastore exactly like 4.0.

The same WHOOP 5 also emits an **88-byte type-47 record with version byte 26** — its body is a
high-rate big-endian i16 waveform buffer (a PPG/IMU trace), distinct from the v18 per-second summary.
It is not mapped; `decodeWhoop5Historical` keys on the version byte and falls back to a labelled raw
region for any version other than 18, so an unknown record is described, never mis-decoded.

> **Firmware-version caveat.** The 4.0 `v24` layout in `whoop_protocol.json` reflects one firmware
> revision (the `my-whoop` reference device); a given strap may run older or newer firmware with a
> different record version. Always key the decode on the version byte and anchor offsets to a real
> capture from the device in hand — do not assume one generation's documented layout transfers to
> another, even within the same generation.

---

## 6. Haptic preset discovery (GET_ALL_HAPTICS_PATTERN)

The strap has a built-in table of haptic waveforms. `GET_ALL_HAPTICS_PATTERN` (command **80**) reports
the device's preset patterns — **7 presets on the WHOOP 4.0 (Harvard)**, indexed `0–6`. They are fired
with `RUN_HAPTICS_PATTERN` (command **79**):

```text
RUN_HAPTICS_PATTERN payload = [patternId, numLoops, 0, 0, 0]   // 5 bytes
```

NOOP uses **`patternId = 2`** — the characteristic graduated "alarm" buzz, observed as the one the
official app fires, for interoperability (`testAlarmBuzz`, `AppModel.buzz`). `numLoops` sets the
length; `STOP_HAPTICS` (122) cancels an in-progress pattern. All notification patterns in NOOP map to
this confirmed preset and vary only the repeat count, so behaviour is predictable on real hardware.

Haptics tie into the firmware **alarm**: `SET_ALARM_TIME` (66) arms a UTC alarm that buzzes even if
NOOP is closed (event `STRAP_DRIVEN_ALARM_EXECUTED`=57); always `SET_CLOCK` first so the RTC is
UTC-correct.

---

## 7. Sensor inventory

Combining the type-47 DSP record (§5), the type-43 raw streams (§4), and the `EventNumber` enum, the
WHOOP 4.0 strap exposes the following sensors and actuators. NOOP only consumes what the device already
measures:

| Sensor / actuator | How it surfaces in the protocol |
|---|---|
| **PPG optical** (green + red/IR LEDs, ambient) | type-47 `ppg_green` / `ppg_red_ir` / `ambient` / `led_drive_1/2`; type-43 optical variant (single AC-coupled green waveform @ ~437 Hz). Drives HR, SpO₂, respiratory rate. |
| **3-axis accelerometer** | type-47 `gravity_x/y/z` (f32, g); type-43 IMU `accelX/Y/Z` (i16 @ ~100 Hz, `1/4096` g/LSB). |
| **Gyroscope / IMU** | type-43 IMU `gyroX/Y/Z` (i16, `0.06104` deg/s/LSB, ±2000 dps). |
| **Skin temperature** | type-47 `skin_temp_raw` (u16 ADC); event `TEMPERATURE_LEVEL`. |
| **Capacitive double-tap** | event `DOUBLE_TAP` (14) → `FrameRouter` fires `onDoubleTap`. |
| **Wrist detection** | events `WRIST_ON` (9) / `WRIST_OFF` (10); type-47 `skin_contact` (0 = off-wrist). |
| **Haptic motor** | `RUN_HAPTICS_PATTERN` / `STOP_HAPTICS`; events `HAPTICS_FIRED` (60), `HAPTICS_TERMINATED` (100). |
| **Battery / charge** | standard `2A19`; type-48 `BATTERY_LEVEL` (SoC/mV/charging ~every 8 min); events `CHARGING_ON/OFF`. |

**Sensors the strap does NOT have** (and that NOOP therefore never fabricates): **no microphone, no
speaker, no GPS, no display.** All feedback to the wearer is via the single haptic motor; all
"location" or "audio" context, if any, comes from imported data, never the strap.

The live physical inputs are wired through `FrameRouter.handle(frame:)`: `DOUBLE_TAP` and
`WRIST_ON`/`WRIST_OFF` events update `LiveState` and can trigger user-configured Mac actions.

---

## 8. Extending the decoder

The decoder is **data-driven**: most of the protocol lives in
`Resources/whoop_protocol.json`, not in code. To add or refine a packet/field:

1. **New static field on an existing type** — add an entry to that packet's `fields` array in the JSON
   (`off`, `len`, `dtype` of `u8`/`u16`/`u32`/`i16`, `name`, `cat`, optional `enum`, optional `note`).
   `parseFrame` picks it up automatically.
2. **New enum value** — add it under `enums` (`PacketType`, `EventNumber`, `CommandNumber`,
   `MetadataType`). `schema.enumName` and `canonicalTypeName` resolve names from here.
3. **Irregular / variable layout** (variable-count R-R, IMU/optical blocks, per-version records) — add
   a closure to `registerPostHooks()` in `PostHooks.swift` and reference it via the packet's `post`
   key. Hooks get `(FieldBuilder, frame, length, schema)` and write into `fb.parsed`.
4. **New historical record version** — add a key under `HISTORICAL_DATA.versions` (the version is
   `frame[5]`); use `"ref"` to reuse another version's layout, or give it its own `fields`.
5. **New durable row** — define the struct in `Streams.swift`, add it to the `Streams` aggregate, and
   emit it from `extractStreams` / `extractHistoricalStreams`. The GRDB persistence layer lives in
   the `WhoopStore` package.
6. **New command** — add a case to `WhoopCommand` in `Commands.swift` with its on-wire raw value.
   Keep the [safety rule](#safety) below.

Every change should be backed by a golden-frame fixture. The package ships captured frames and expected
output in `Tests/WhoopProtocolTests/Resources/` (`frames.json`, `golden.json`,
`historical_golden.json`, `biometric_streams_golden.json`, …); the parity tests assert the Swift
decoder reproduces them byte-for-byte. Prefer real captures over invented offsets — unmapped regions
are kept raw and labelled rather than guessed.

### A note on whoop5 offsets

If you map the WHOOP 5.0 biometric fields, do it in `parseFrameWhoop5` (inner record at offset 8) and
back it with real 5.0 captures. Until then the 5.0 path intentionally leaves the inner record as an
unparsed region — describing the frame faithfully without inventing structure.

<a name="safety"></a>
### Safety rule

`WhoopCommand` in `Commands.swift` is a **deliberately curated subset**. Destructive or dangerous
commands — reboot, firmware load, force-trim, ship-mode, power-cycle, fuel-gauge reset, BLE DFU — are
**excluded by design** so the in-app command sender can never brick or wipe a device. When extending
the command set, keep it reversible and non-destructive.

---

## Summary

NOOP interoperates with a WHOOP strap you own by: scanning for its hidden custom GATT service,
triggering just-works bonding with a single confirmed `GET_BATTERY_LEVEL` write, reassembling the
`0xAA` CRC-framed messages, and decoding them with a data-driven schema. The expensive type-43 raw
flood is switched off on connect (`SEND_R10_R11_REALTIME [0x00]`), leaving the periodically-offloaded
type-47 14-day biometric store as the primary on-device data source. WHOOP 4.0 and 5.0 differ only in
their GATT UUIDs, header checksum (CRC8 vs CRC16-Modbus), inner-record offset, and session start — all
funnelled through `DeviceFamily`. The work stands on the shoulders of `johnmiddleton12/my-whoop`
(4.0) and `b-nnett/goose` (5.0), with sensor scales and offsets re-verified on real hardware.

> Reminder: not affiliated with WHOOP; not a medical device. All values are raw or locally-estimated
> and are for personal, informational use only.
