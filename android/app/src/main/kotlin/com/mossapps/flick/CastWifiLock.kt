package com.mossapps.flick

import android.net.wifi.WifiManager

/** Only return modes documented to work with the screen off for this SDK.
 * API 34+ maps HIGH_PERF to LOW_LATENCY, which requires an on-screen app.
 * On those releases the relay relies on its foreground service/CPU wake lock
 * and normal platform network scheduling, not a non-functional WifiLock.
 */
@Suppress("DEPRECATION")
internal fun castScreenOffWifiLockMode(sdk: Int): Int? = when {
    sdk < 29 -> WifiManager.WIFI_MODE_FULL
    sdk < 34 -> WifiManager.WIFI_MODE_FULL_HIGH_PERF
    else -> null
}
