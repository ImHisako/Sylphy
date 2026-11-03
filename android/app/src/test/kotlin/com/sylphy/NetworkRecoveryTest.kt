package com.sylphy

import org.junit.Assert.*
import org.junit.Test

class NetworkRecoveryTest {
    @Test fun reopeningOnTheSameNetworkRenewsTheConnectionAndSupersedesOldRetries() {
        val state = NetworkTransitionState()
        val beforeClose = state.update("wifi", true, true)!!
        assertNull(state.update("wifi", true, true))

        state.requestRecovery()
        state.requestRecovery() // Lifecycle and connectivity callbacks may overlap.
        val reopened = state.update("wifi", true, true)!!
        assertFalse(state.isCurrent(beforeClose))
        assertTrue(state.isCurrent(reopened))
        assertNull(state.update("wifi", true, true))

        state.requestRecovery()
        val reopenedAgain = state.update("wifi", true, true)!!
        assertFalse(state.isCurrent(reopened))
        assertTrue(state.isCurrent(reopenedAgain))
    }

    @Test fun reopeningUsesCurrentConnectivityAndDoesNotInventAnOnlineNetwork() {
        val state = NetworkTransitionState()
        val beforeClose = state.update("wifi", true, true)!!
        state.requestRecovery()
        val offline = state.update(null, false)!!
        assertFalse(state.isCurrent(beforeClose))
        assertTrue(state.isCurrent(offline))
        assertNull(state.update(null, false))
        // An unvalidated VPN remains eligible for native reachability checks.
        state.requestRecovery()
        val vpn = state.update("vpn", true, false)!!
        assertFalse(state.isCurrent(offline))
        assertTrue(state.isCurrent(vpn))
        assertNull(state.update("vpn", true, false))
    }

    @Test fun recoversWhenMobileCoverageReturnsOnTheSameNetwork() {
        val state = NetworkTransitionState()
        val connected = state.update("mobile", true, true)!!
        val noCoverage = state.update("mobile", true, false)!!
        assertFalse(state.isCurrent(connected))
        assertNull(state.update("mobile", true, false))
        val recovered = state.update("mobile", true, true)!!
        assertFalse(state.isCurrent(noCoverage))
        assertTrue(state.isCurrent(recovered))
        assertNull(state.update("mobile", true, true))
        // Lack of Android validation never means an otherwise usable VPN is offline.
        assertNotNull(state.update("vpn", true, false))
    }

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
