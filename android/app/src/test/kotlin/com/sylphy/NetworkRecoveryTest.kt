package com.sylphy

import org.junit.Assert.*
import org.junit.Test

class NetworkRecoveryTest {
    @Test fun coalescesDuplicateCallbacksAndSupersedesOldRecoveryAttempts() {
        val state = NetworkTransitionState()
        val wifi = state.update("wifi", true)!!
        assertNull(state.update("wifi", true))
        val mobile = state.update("mobile", true)!!
        assertFalse(state.isCurrent(wifi))
        assertTrue(state.isCurrent(mobile))
        val offline = state.update(null, false)!!
        assertFalse(state.isCurrent(mobile))
        assertNull(state.update(null, false))
        assertTrue(state.isCurrent(offline))
        assertNotNull(state.update("mobile", true))
    }

    @Test fun retainsPromptBusyRetryAndBacksOffOfflineOrLockedFallbackPolling() {
        assertEquals(750L, BackgroundPollPolicy.delay(true, -2))
        assertEquals(60_000L, BackgroundPollPolicy.delay(false, 0))
        assertEquals(60_000L, BackgroundPollPolicy.delay(true, -3))
        assertEquals(30_000L, BackgroundPollPolicy.delay(true, 1))
        assertEquals(30_000L, BackgroundPollPolicy.delay(true, -1))
    }
}
