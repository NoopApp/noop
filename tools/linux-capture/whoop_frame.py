"""WHOOP BLE framing helpers — the minimum needed to bond a strap and reassemble its frames.

This is a small, dependency-free port of the framing rules implemented (and verified on real
hardware) in the Swift `WhoopProtocol` package — see `docs/BLE_REVERSE_ENGINEERING.md`. It does NOT
decode payloads: the capture tool records complete frames as hex, and the Swift `whoop-decode` CLI
(or the WhoopProtocol parity tests) does the decoding, so there is exactly one decoder of record.

WHOOP 4.0 ("Harvard") envelope:
    [0xAA][len u16 LE][crc8(len bytes)][type][seq][cmd][payload…][crc32 LE]
    len = (3 + len(payload)) + 4 ;  total on wire = len + 4
    crc8: poly 0x07, init 0x00, no reflection, over the 2 length bytes only
    crc32: standard zlib (reflected, poly 0xEDB88320) over [type][seq][cmd][payload]

WHOOP 5.0 ("puffin") envelope:
    [0xAA][format=0x01][declaredLength u16 LE][header u16][crc16 u16 LE][type][seq][cmd][data…][crc32 LE]
    total on wire = declaredLength + 8 ;  inner record starts at offset 8
"""

import zlib

# COMMAND packet type byte (PacketType.COMMAND).
COMMAND_TYPE = 35

# Command numbers (subset; mirrors WhoopCommand in Commands.swift). The numbers are shared with the
# 5.0 puffin command set — only the framing differs (CRC8 here vs CRC16 there).
CMD_GET_BATTERY_LEVEL = 26
CMD_GET_CLOCK = 11
CMD_REPORT_VERSION_INFO = 7
CMD_GET_EXTENDED_BATTERY_INFO = 98
CMD_GET_DATA_RANGE = 34
CMD_GET_HELLO_HARVARD = 35

# WHOOP 5.0 session-start frame, written verbatim to fd4b0002 to open the puffin session.
# (DeviceFamily.whoop5ClientHello — a fully-formed type-35 COMMAND with valid CRC16 header + CRC32.)
WHOOP5_CLIENT_HELLO = bytes.fromhex("aa0108000001e67123019101363e5c8d")


def _crc8_table():
    table = []
    for i in range(256):
        c = i
        for _ in range(8):
            c = ((c << 1) ^ 0x07) & 0xFF if (c & 0x80) else (c << 1) & 0xFF
        table.append(c)
    return table


_CRC8_TABLE = _crc8_table()


def crc8(data: bytes) -> int:
    """CRC-8 (poly 0x07, init 0x00) — the WHOOP 4.0 header check over the two length bytes."""
    crc = 0
    for b in data:
        crc = _CRC8_TABLE[crc ^ b]
    return crc


def crc32(data: bytes) -> int:
    """Standard zlib CRC-32 — the WHOOP 4.0/5.0 payload trailer."""
    return zlib.crc32(data) & 0xFFFFFFFF


def build_command_frame(cmd: int, seq: int = 0, payload: bytes = b"\x00") -> bytes:
    """Build a complete WHOOP 4.0 COMMAND frame ready to write to the CMD-write characteristic.

    Mirrors `WhoopCommand.frame(seq:payload:)`. Used to send the benign GET_BATTERY_LEVEL that
    triggers just-works bonding on a 4.0 strap.
    """
    inner = bytes([COMMAND_TYPE, seq & 0xFF, cmd & 0xFF]) + payload
    length = (3 + len(payload)) + 4           # inner (type+seq+cmd+payload) + 4-byte CRC32 trailer
    len_bytes = bytes([length & 0xFF, (length >> 8) & 0xFF])
    header_crc = crc8(len_bytes)
    trailer = crc32(inner)
    trailer_bytes = bytes([trailer & 0xFF, (trailer >> 8) & 0xFF,
                           (trailer >> 16) & 0xFF, (trailer >> 24) & 0xFF])
    return bytes([0xAA]) + len_bytes + bytes([header_crc]) + inner + trailer_bytes


def crc16_modbus(data: bytes) -> int:
    """CRC16-Modbus (poly 0xA001, init 0xFFFF, reflected) — the WHOOP 5.0 frame header check."""
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if (crc & 1) else (crc >> 1)
    return crc & 0xFFFF


# Puffin command numbers worth probing after CLIENT_HELLO to elicit streaming (all non-destructive
# reads/toggles; mirror WhoopCommand). These reuse the 4.0 command numbers on the 5.0 transport;
# GET_CLOCK, TOGGLE_REALTIME_HR, SEND_R10_R11_REALTIME and SEND_HISTORICAL_DATA are confirmed accepted
# on real WHOOP 5 hardware (see docs/BLE_REVERSE_ENGINEERING.md §3); the rest remain educated guesses.
PUFFIN_CMD_TOGGLE_REALTIME_HR = 3
PUFFIN_CMD_SEND_HISTORICAL_DATA = 22
# Ack a received history chunk (confirmed write echoing the chunk's end_data / trim cursor). On 4.0
# this is what advances the strap's trim cursor to the NEXT chunk; without it the strap re-sends the
# same early chunk forever. The leading hypothesis for why the DSP (type-47) records never arrive is
# that we never ack — so the cursor never reaches them. Build the payload from each METADATA (type 49)
# chunk's trim/end_data; see Strand/BLE/BLEManager.swift `ackHistoricalChunk` for the 4.0 shape.
PUFFIN_CMD_HISTORICAL_DATA_RESULT = 23
PUFFIN_CMD_GET_CLOCK = 11
PUFFIN_CMD_GET_DATA_RANGE = 34
PUFFIN_CMD_SEND_R10_R11_REALTIME = 63
# Read-only "GET" commands that elicit a COMMAND_RESPONSE (type 36) — used to map the WHOOP 5
# command-response payloads at the +4 offsets. All are non-destructive reads; the response echoes the
# command number in its cmd byte (frame[10] on 5.0), which selects the payload layout.
PUFFIN_CMD_REPORT_VERSION_INFO = 7          # → fw version block
PUFFIN_CMD_GET_BATTERY_LEVEL = 26           # → battery %
PUFFIN_CMD_GET_EXTENDED_BATTERY_INFO = 98   # → battery mV
PUFFIN_CMD_GET_BATTERY_PACK_INFO = 151      # WHOOP 5 removable battery pack (no 4.0 analogue)


def build_puffin_command(cmd: int, seq: int = 0, payload: bytes = b"\x00",
                         type_: int = 35, header: bytes = b"\x00\x01") -> bytes:
    """Build a WHOOP 5.0 ("puffin") command frame. Port of `puffinCommandFrame` in Framing.swift:
    [0xAA][0x01][declLen u16 LE][header u16][crc16 u16 LE][type][seq][cmd][payload…][crc32 LE].
    """
    inner = bytes([type_, seq & 0xFF, cmd & 0xFF]) + payload
    decl = len(inner) + 4
    frame = bytearray([0xAA, 0x01, decl & 0xFF, (decl >> 8) & 0xFF, header[0], header[1]])
    c16 = crc16_modbus(bytes(frame[0:6]))
    frame += bytes([c16 & 0xFF, (c16 >> 8) & 0xFF])
    frame += inner
    c32 = crc32(inner)
    frame += bytes([c32 & 0xFF, (c32 >> 8) & 0xFF, (c32 >> 16) & 0xFF, (c32 >> 24) & 0xFF])
    return bytes(frame)


# --- WHOOP 5.0 historical-offload helpers ---------------------------------------------------------
# Packet types (PacketType enum, wire byte at the inner-record start, offset 8 on 5.0).
PACKET_METADATA = 49
PACKET_HISTORICAL_DATA = 47
# MetadataType enum values (the meta_type byte).
META_HISTORY_START = 1
META_HISTORY_END = 2
META_HISTORY_COMPLETE = 3
# WHOOP 5.0 metadata field offsets = the 4.0 offsets + 4 (the inner record starts at byte 8 vs 4).
# Verified on real hardware: meta_type at 6→10, trim_cursor at 17→21 (decodes to clean HISTORY_END
# values with a consistent trim across a whole capture). The 8-byte end_data the ack echoes is the
# trim u32 followed by the next u32, i.e. frame[21:29].
WHOOP5_INNER_OFF = 8
WHOOP5_META_TYPE_OFF = 10
WHOOP5_META_TRIM_OFF = 21
WHOOP5_END_DATA_LEN = 8


def verify_whoop5_frame(frame: bytes) -> bool:
    """True if a WHOOP 5.0 frame's declared length, CRC16 header and CRC32 trailer all check out.

    The ack must only echo a genuine, intact HISTORY_END — CRC is the protocol's only integrity
    check, so a garbled BLE frame must never advance the strap's trim cursor.
    """
    if len(frame) < 12 or frame[0] != 0xAA:
        return False
    decl = frame[2] | (frame[3] << 8)
    total = decl + 8
    if total != len(frame):
        return False
    if crc16_modbus(bytes(frame[0:6])) != (frame[6] | (frame[7] << 8)):
        return False
    inner = bytes(frame[8:total - 4])
    wire = int.from_bytes(frame[total - 4:total], "little")
    return crc32(inner) == wire


def history_end_data(frame: bytes):
    """If `frame` is a CRC-valid WHOOP 5.0 METADATA HISTORY_END, return its 8-byte end_data
    (trim u32 + next u32 at offset 21) to echo back in the ack; otherwise None.

    Echoing these bytes verbatim in a HISTORICAL_DATA_RESULT(23) is what advances the strap's trim
    cursor to the next chunk on 4.0 — without it the strap re-serves the same early chunk forever and
    the type-47 DSP records further in the store are never reached.
    """
    if len(frame) < WHOOP5_META_TRIM_OFF + WHOOP5_END_DATA_LEN:
        return None
    if frame[WHOOP5_INNER_OFF] != PACKET_METADATA:
        return None
    if frame[WHOOP5_META_TYPE_OFF] != META_HISTORY_END:
        return None
    if not verify_whoop5_frame(frame):
        return None
    return bytes(frame[WHOOP5_META_TRIM_OFF:WHOOP5_META_TRIM_OFF + WHOOP5_END_DATA_LEN])


def build_history_ack(end_data: bytes, seq: int = 0) -> bytes:
    """Build the HISTORICAL_DATA_RESULT(23) ack frame: payload = 0x01 + the 8-byte end_data.

    Mirrors `ackHistoricalChunk` in Strand/BLE/BLEManager.swift (`send(.historicalDataResult,
    payload: [0x01] + endData, .withResponse)`). Written to fd4b0002 as a CONFIRMED write.
    """
    return build_puffin_command(PUFFIN_CMD_HISTORICAL_DATA_RESULT, seq=seq,
                                payload=b"\x01" + bytes(end_data))


# --- WHOOP 4.0 historical-offload helpers ---------------------------------------------------------
# The 4.0 image of the whoop5 helpers above. The inner record starts at offset 4 (vs 5.0's 8), so the
# metadata fields sit 4 bytes earlier: meta_type at frame[6] (5.0's 10 − 4) and trim_cursor at
# frame[17] (5.0's 21 − 4). The 8-byte end_data the ack echoes is the trim u32 + next u32 = frame[17:25]
# (vs 5.0's frame[21:29]). PACKET_* / META_* / the command numbers (22 SEND_HISTORICAL_DATA, 23
# HISTORICAL_DATA_RESULT) are SHARED across generations — only the framing differs (CRC8 here, CRC16
# there) — so they are reused as-is rather than forked. See PostHooks.swift `metadata` (4.0) and
# docs/BLE_REVERSE_ENGINEERING.md §5.
WHOOP4_INNER_OFF = 4
WHOOP4_META_TYPE_OFF = 6
WHOOP4_META_TRIM_OFF = 17
WHOOP4_END_DATA_LEN = 8


def verify_whoop4_frame(frame: bytes) -> bool:
    """True if a WHOOP 4.0 frame's declared length, CRC8 header and CRC32 trailer all check out.

    As on 5.0, the ack must only echo a genuine, intact HISTORY_END — CRC is the protocol's only
    integrity check, so a garbled BLE frame must never advance the strap's trim cursor.
    """
    if len(frame) < 8 or frame[0] != 0xAA:
        return False
    declared = frame[1] | (frame[2] << 8)
    total = declared + 4
    if total != len(frame):
        return False
    if crc8(bytes(frame[1:3])) != frame[3]:
        return False
    inner = bytes(frame[4:total - 4])
    wire = int.from_bytes(frame[total - 4:total], "little")
    return crc32(inner) == wire


def history_end_data_whoop4(frame: bytes):
    """If `frame` is a CRC-valid WHOOP 4.0 METADATA HISTORY_END, return its 8-byte end_data
    (trim u32 + next u32 at frame[17]) to echo back in the ack; otherwise None.

    Echoing these bytes verbatim in a HISTORICAL_DATA_RESULT(23) advances the strap's trim cursor to
    the next chunk — the 4.0 image of `history_end_data`, with offsets 4 bytes earlier.
    """
    if len(frame) < WHOOP4_META_TRIM_OFF + WHOOP4_END_DATA_LEN:
        return None
    if frame[WHOOP4_INNER_OFF] != PACKET_METADATA:
        return None
    if frame[WHOOP4_META_TYPE_OFF] != META_HISTORY_END:
        return None
    if not verify_whoop4_frame(frame):
        return None
    return bytes(frame[WHOOP4_META_TRIM_OFF:WHOOP4_META_TRIM_OFF + WHOOP4_END_DATA_LEN])


def build_history_ack_whoop4(end_data: bytes, seq: int = 0) -> bytes:
    """Build the WHOOP 4.0 HISTORICAL_DATA_RESULT(23) ack: payload = 0x01 + the 8-byte end_data,
    framed as a 4.0 COMMAND (CRC8 header). The 4.0 image of `build_history_ack`.
    """
    return build_command_frame(PUFFIN_CMD_HISTORICAL_DATA_RESULT, seq=seq,
                               payload=b"\x01" + bytes(end_data))


class Reassembler:
    """Family-aware frame reassembler: BLE delivers MTU-sized fragments; this accumulates bytes,
    finds the 0xAA SOF, reads the declared length, and emits a complete frame once enough bytes are
    present. One instance per notify characteristic so channels don't interleave.

    family: "whoop4" or "whoop5".
    """

    def __init__(self, family: str):
        self.family = family
        self.buf = bytearray()

    def _total_len(self):
        """Total on-wire length of the frame at the front of the buffer, or None if not yet known."""
        b = self.buf
        if self.family == "whoop4":
            if len(b) < 3:
                return None
            declared = b[1] | (b[2] << 8)      # len field
            return declared + 4
        else:  # whoop5
            if len(b) < 4:
                return None
            declared = b[2] | (b[3] << 8)      # declaredLength
            return declared + 8

    def feed(self, data: bytes):
        """Add a notification's bytes; return a list of any complete frames now available (as bytes)."""
        self.buf.extend(data)
        out = []
        while True:
            # Resync to the next SOF if the buffer doesn't start on one.
            sof = self.buf.find(0xAA)
            if sof == -1:
                self.buf.clear()
                break
            if sof > 0:
                del self.buf[:sof]
            total = self._total_len()
            if total is None:
                break
            # Guard against an absurd length from a corrupt SOF FIRST — before waiting for more
            # bytes — so a bad length can't stall the buffer forever. Drop one byte and resync.
            if total <= 0 or total > 4096:
                del self.buf[:1]
                continue
            if len(self.buf) < total:
                break
            out.append(bytes(self.buf[:total]))
            del self.buf[:total]
        return out


def parse_standard_hr(data: bytes):
    """Parse a standard Heart Rate Measurement (0x2A37) notification → bpm, or None.

    Layout: flags u8; bit0 = HR is u16 (else u8). We only need the bpm for ground-truth correlation.
    """
    if not data:
        return None
    flags = data[0]
    if flags & 0x01:
        if len(data) < 3:
            return None
        return data[1] | (data[2] << 8)
    if len(data) < 2:
        return None
    return data[1]
