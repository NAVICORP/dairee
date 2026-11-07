package co.skifi.dairee

import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The channel the server sends to: requests, problems, bills and reminders.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel("dairee", "Dairee", NotificationManager.IMPORTANCE_HIGH)
            channel.description = "Requests, problems on the round, bills and reminders"
            getSystemService(NotificationManager::class.java)?.createNotificationChannel(channel)
        }
    }
}
