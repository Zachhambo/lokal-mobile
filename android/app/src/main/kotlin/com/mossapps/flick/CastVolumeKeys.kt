package com.mossapps.flick

import android.view.KeyEvent

/** Consume both halves of a receiver-volume key so Android cannot also
 * change STREAM_MUSIC. Long-press repeats are deliberate volume steps.
 */
internal fun handleCastVolumeKey(
    event: KeyEvent,
    connected: Boolean,
    adjust: (Int) -> Unit,
): Boolean {
    if (!connected) return false
    val direction = when (event.keyCode) {
        KeyEvent.KEYCODE_VOLUME_UP -> 1
        KeyEvent.KEYCODE_VOLUME_DOWN -> -1
        else -> return false
    }
    if (event.action != KeyEvent.ACTION_DOWN && event.action != KeyEvent.ACTION_UP) return false
    if (event.action == KeyEvent.ACTION_DOWN && !event.isCanceled) adjust(direction)
    return true
}
