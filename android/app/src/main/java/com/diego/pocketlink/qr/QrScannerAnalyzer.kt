package com.diego.pocketlink.qr

import androidx.annotation.OptIn
import androidx.camera.core.ExperimentalGetImage
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import com.google.zxing.BinaryBitmap
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeReader
import java.util.concurrent.atomic.AtomicBoolean

class QrScannerAnalyzer(
    private val onQrScanned: (String) -> Unit
) : ImageAnalysis.Analyzer {

    private val qrCodeReader = QRCodeReader()
    private val hasDecoded = AtomicBoolean(false)

    @OptIn(ExperimentalGetImage::class)
    override fun analyze(imageProxy: ImageProxy) {
        if (hasDecoded.get()) {
            imageProxy.close()
            return
        }

        val mediaImage = imageProxy.image
        if (mediaImage != null) {
            val planes = mediaImage.planes
            if (planes.isNotEmpty()) {
                val buffer = planes[0].buffer
                val data = ByteArray(buffer.remaining())
                buffer.get(data)
                val width = imageProxy.width
                val height = imageProxy.height

                val source = PlanarYUVLuminanceSource(
                    data,
                    width,
                    height,
                    0,
                    0,
                    width,
                    height,
                    false
                )
                val binaryBitmap = BinaryBitmap(HybridBinarizer(source))
                val orientedBitmap = when (imageProxy.imageInfo.rotationDegrees) {
                    90 -> binaryBitmap
                        .rotateCounterClockwise()
                        .rotateCounterClockwise()
                        .rotateCounterClockwise()
                    270 -> binaryBitmap.rotateCounterClockwise()
                    else -> binaryBitmap
                }

                try {
                    val result = qrCodeReader.decode(orientedBitmap)
                    if (result != null && hasDecoded.compareAndSet(false, true)) {
                        onQrScanned(result.text)
                    }
                } catch (_: Exception) {
                    // Scanning frame failed, ignore and continue
                } finally {
                    qrCodeReader.reset()
                }
            }
        }
        imageProxy.close()
    }
}
