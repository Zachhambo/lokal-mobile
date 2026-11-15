package com.mossapps.flick

import android.content.Context
import com.google.android.gms.cast.framework.CastOptions
import com.google.android.gms.cast.framework.OptionsProvider
import com.google.android.gms.cast.framework.SessionProvider
import com.google.android.gms.cast.framework.media.CastMediaOptions
import com.google.android.gms.cast.framework.media.NotificationOptions

// Google CAF owns the Cast media session, notification and lock-screen controls.
// Lokal's own media notification must not impersonate the remote session.
class CastOptionsProvider : OptionsProvider {
    override fun getCastOptions(context: Context): CastOptions {
        val notification = NotificationOptions.Builder()
            .setTargetActivityClassName(MainActivity::class.java.name)
            .build()
        val media = CastMediaOptions.Builder()
            .setMediaSessionEnabled(true)
            .setNotificationOptions(notification)
            .build()
        return CastOptions.Builder()
            .setReceiverApplicationId("2060B9B3")
            .setCastMediaOptions(media)
            .build()
    }

    override fun getAdditionalSessionProviders(context: Context): MutableList<SessionProvider>? =
        null
}
