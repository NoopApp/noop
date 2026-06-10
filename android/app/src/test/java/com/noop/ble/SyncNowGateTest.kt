package com.noop.ble

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The "Sync now" gate (#93). The manual button forwards to the SAME [WhoopBleClient.requestSync]
 * guard the auto-kick and the 900s periodic timer use, so a manual sync can never bypass the
 * connected+bonded+not-already-backfilling precondition. These pin that pure predicate
 * ([WhoopBleClient.canRequestSync]) so the no-op behaviour the button relies on can't silently
 * regress — the full kick path needs a live GATT stack, but the decision to kick is pure.
 */
class SyncNowGateTest {

    @Test
    fun allowsSync_whenConnectedAndBondedAndIdle() {
        assertTrue(WhoopBleClient.canRequestSync(connected = true, bonded = true, backfilling = false))
    }

    @Test
    fun blocksSync_whenNotConnected() {
        // Disconnected: the command channel is gone — a kick would just be dropped by send().
        assertFalse(WhoopBleClient.canRequestSync(connected = false, bonded = true, backfilling = false))
    }

    @Test
    fun blocksSync_whenNotBonded() {
        // Connected but unbonded (e.g. 5/MG live-HR shortcut): the offload command needs the bonded
        // channel, so a manual tap must no-op rather than fire a doomed request.
        assertFalse(WhoopBleClient.canRequestSync(connected = true, bonded = false, backfilling = false))
    }

    @Test
    fun blocksSync_whenAlreadyBackfilling() {
        // THE reason the button is disabled mid-session: a second kick during an in-flight offload
        // would fight the running session. The gate is the real enforcement; the disabled UI mirrors it.
        assertFalse(WhoopBleClient.canRequestSync(connected = true, bonded = true, backfilling = true))
    }

    @Test
    fun blocksSync_whenDisconnectedMidBackfill() {
        // A dropout mid-backfill: every precondition that matters is false — still a no-op.
        assertFalse(WhoopBleClient.canRequestSync(connected = false, bonded = false, backfilling = true))
    }
}
