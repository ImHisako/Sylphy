package com.sylphy

internal object BackgroundPollPolicy {
    fun delay(online: Boolean, outcome: Int): Long = when {
        outcome == -2 -> 750L // A foreground command was still committing.
        outcome == -3 || !online -> 60_000L
        else -> 30_000L // Native network events drive normal delivery immediately.
    }
}

internal class NetworkTransitionState {
    private var network: Any? = null
    private var initialized = false
    private var online = false
    private var validated = false
    private var revision = 0L

    fun update(network: Any?, online: Boolean, validated: Boolean = false): Long? {
        if (initialized && this.network == network && this.online == online &&
            this.validated == validated) return null
        initialized = true
        this.network = network
        this.online = online
        this.validated = validated
        revision++
        return revision
    }

    fun isCurrent(revision: Long): Boolean = this.revision == revision
}
