package com.noop.protocol

/**
 * On-wire enums for the WHOOP protocol. Each constant carries its raw (on-wire) Int value and
 * every enum offers a `fromRaw(Int)` companion lookup that returns null for unknown codes.
 *
 * Values mirror the canonical schema (whoop_protocol.json) and the project SHARED CONTRACT.
 * These are deliberately a curated subset of the full device enum tables — only the codes the
 * offline companion app reads or sends. Unknown codes are surfaced by name elsewhere (see
 * [Framing.enumLabel]); they are not added here so the enums stay small and intentional.
 */

/** Frame packet type (envelope byte at offset 4 for Whoop 4.0). */
enum class PacketType(val rawValue: Int) {
    COMMAND(35),
    COMMAND_RESPONSE(36),
    PUFFIN_COMMAND(37),
    PUFFIN_COMMAND_RESPONSE(38),
    REALTIME_DATA(40),
    REALTIME_RAW_DATA(43),
    HISTORICAL_DATA(47),
    EVENT(48),
    METADATA(49),
    CONSOLE_LOGS(50),
    REALTIME_IMU_DATA_STREAM(51),
    HISTORICAL_IMU_DATA_STREAM(52);

    companion object {
        private val byRaw = entries.associateBy { it.rawValue }
        fun fromRaw(raw: Int): PacketType? = byRaw[raw]
    }
}

/** METADATA frame sub-type (historical-offload state machine). */
enum class MetadataType(val rawValue: Int) {
    HISTORY_START(1),
    HISTORY_END(2),
    HISTORY_COMPLETE(3);

    companion object {
        private val byRaw = entries.associateBy { it.rawValue }
        fun fromRaw(raw: Int): MetadataType? = byRaw[raw]
    }
}

/** EVENT frame event code (offset 6 in an EVENT frame). */
enum class EventNumber(val rawValue: Int) {
    BATTERY_LEVEL(3),
    CHARGING_ON(7),
    CHARGING_OFF(8),
    WRIST_ON(9),
    WRIST_OFF(10),
    DOUBLE_TAP(14),
    TEMPERATURE_LEVEL(17),
    BLE_BONDED(23),
    BLE_REALTIME_HR_ON(33),
    BLE_REALTIME_HR_OFF(34),
    STRAP_DRIVEN_ALARM_EXECUTED(57),
    APP_DRIVEN_ALARM_EXECUTED(58),
    HAPTICS_FIRED(60);

    companion object {
        private val byRaw = entries.associateBy { it.rawValue }
        fun fromRaw(raw: Int): EventNumber? = byRaw[raw]
    }
}

/**
 * Curated, SAFE command codes for *sending* to the strap. Destructive commands
 * (reboot / firmware load / force-trim / ship-mode / power-cycle / fuel-gauge reset / BLE DFU)
 * are deliberately excluded so the in-app sender can never brick or wipe the device.
 */
enum class CommandNumber(val rawValue: Int) {
    TOGGLE_REALTIME_HR(3),
    SET_CLOCK(10),
    GET_CLOCK(11),
    SEND_HISTORICAL_DATA(22),
    // The historical-offload trim/ack command. Sent (with response) to confirm one HISTORY_END
    // chunk so the strap may trim it; payload = [0x01] + the verbatim 8-byte HISTORY_END end_data.
    // Port of Swift `WhoopCommand.historicalDataResult` (whoop_protocol.json: 23 HISTORICAL_DATA_RESULT).
    HISTORICAL_DATA_RESULT(23),
    GET_BATTERY_LEVEL(26),
    GET_DATA_RANGE(34),
    GET_HELLO_HARVARD(35),
    SEND_R10_R11_REALTIME(63),
    // WHOOP 5.0/MG (device family GOOSE/MAVERICK) one-shot buzz. Gen-4 straps use the legacy
    // RUN_HAPTICS_PATTERN(79) below; a 5/MG strap only honors this command.
    RUN_HAPTIC_PATTERN_MAVERICK(19),
    SET_ALARM_TIME(66),
    GET_ALARM_TIME(67),
    RUN_ALARM(68),
    DISABLE_ALARM(69),
    RUN_HAPTICS_PATTERN(79),
    GET_ALL_HAPTICS_PATTERN(80),
    START_RAW_DATA(81),
    STOP_RAW_DATA(82),
    STOP_HAPTICS(122),
    SELECT_WRIST(123);

    companion object {
        private val byRaw = entries.associateBy { it.rawValue }
        fun fromRaw(raw: Int): CommandNumber? = byRaw[raw]
    }
}
