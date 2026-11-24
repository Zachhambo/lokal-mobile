package com.mossapps.flick

import android.app.Application
import android.view.KeyEvent
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class CastVolumeKeysTest {
    @Test fun pressAndReleaseSendOneReceiverStep() {
        val steps = mutableListOf<Int>()
        for (key in listOf(KeyEvent.KEYCODE_VOLUME_UP, KeyEvent.KEYCODE_VOLUME_DOWN)) {
            assertTrue(handleCastVolumeKey(KeyEvent(KeyEvent.ACTION_DOWN, key), true, steps::add))
            assertTrue(handleCastVolumeKey(KeyEvent(KeyEvent.ACTION_UP, key), true, steps::add))
        }
        assertEquals(listOf(1, -1), steps)
    }

    @Test fun heldKeysSendEachRepeatToReceiver() {
        val steps = mutableListOf<Int>()
        for (repeat in 0..3) {
            val event = KeyEvent(0L, 0L, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_VOLUME_UP, repeat)
            assertTrue(handleCastVolumeKey(event, true, steps::add))
        }
        assertEquals(listOf(1, 1, 1, 1), steps)
    }

    @Test fun disconnectedAndUnrelatedKeysFallThroughWithoutReceiverWrites() {
        var writes = 0
        assertFalse(handleCastVolumeKey(
            KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_VOLUME_UP), false,
        ) { writes++ })
        assertFalse(handleCastVolumeKey(
            KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_MEDIA_PLAY), true,
        ) { writes++ })
        assertEquals(0, writes)
    }
}
