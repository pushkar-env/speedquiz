package com.speedquiz.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createMultiplayerChannel()
    }

    /**
     * Register the channel our FCM messages target.
     *
     * On Android 8+ a notification whose channel does not exist is **dropped
     * without any error** — no crash, no log the app can see, just silence.
     * The backend sets `android.notification.channel_id` to this id, so the
     * channel has to exist before the first push arrives, which means creating
     * it at launch rather than lazily.
     *
     * Kept in Kotlin even though the app now carries
     * `flutter_local_notifications` for on-device reminders: that plugin
     * creates its own `speedquiz_reminders` channel from Dart, on first
     * initialize. This one has to exist *before* Dart runs at all, because a
     * push can arrive at a process the user never opened. Two channels is also
     * the right split for the player — reminders can be silenced in system
     * settings without losing challenges.
     *
     * Creating a channel that already exists is a documented no-op, so running
     * this on every launch is free — and it is also what picks up a renamed
     * channel after an app update.
     *
     * The importance is HIGH because these are time-sensitive: a live match
     * has a round clock running, and a silent notification is a forfeit.
     */
    private fun createMultiplayerChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.multiplayer_channel_name),
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = getString(R.string.multiplayer_channel_description)
            enableVibration(true)
        }

        val manager = getSystemService(NotificationManager::class.java)
        manager?.createNotificationChannel(channel)
    }

    private companion object {
        /** Must match `PushMessage.channel_id` in `backend/app/push/fcm.py`. */
        const val CHANNEL_ID = "speedquiz_multiplayer"
    }
}
