package com.diego.pocketlink

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.core.content.ContextCompat
import androidx.core.content.IntentCompat
import com.diego.pocketlink.mirroring.MirrorConsentRouter
import com.diego.pocketlink.mirroring.MirroringService
import com.diego.pocketlink.ui.ConnectionScreen
import com.diego.pocketlink.ui.ConnectionViewModel
import com.diego.pocketlink.ui.theme.MobileTheme

class MainActivity : ComponentActivity() {

    private val viewModel: ConnectionViewModel by viewModels()

    private val requestPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { _ ->
        // Permission result handled
    }

    private val mirrorConsentLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        MirrorConsentRouter.onConsentResult(result.resultCode, result.data)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        requestNotificationPermissionIfNeeded()
        handleShareIntent(intent)
        MirrorConsentRouter.handleDeepLinkIntent(intent)

        setContent {
            MobileTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    ConnectionScreen(viewModel = viewModel)
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleShareIntent(intent)
        MirrorConsentRouter.handleDeepLinkIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        MirrorConsentRouter.onActivityResumed(this)
    }

    override fun onPause() {
        MirrorConsentRouter.onActivityPaused()
        super.onPause()
    }

    fun launchMirrorConsent() {
        if (MirroringService.isRunning) return
        val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        mirrorConsentLauncher.launch(manager.createScreenCaptureIntent())
    }

    private fun handleShareIntent(intent: Intent?) {
        val uris = when (intent?.action) {
            Intent.ACTION_SEND ->
                listOfNotNull(IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java))
            Intent.ACTION_SEND_MULTIPLE ->
                IntentCompat.getParcelableArrayListExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)
                    ?: emptyList()
            else -> emptyList()
        }
        if (uris.isNotEmpty()) {
            viewModel.sendSharedFiles(uris)
        }
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(
                    this,
                    Manifest.permission.POST_NOTIFICATIONS
                ) != PackageManager.PERMISSION_GRANTED
            ) {
                requestPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
            }
        }
    }
}
