package ir.ironpin.ironpin

import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import com.googlecode.tesseract.android.TessBaseAPI
import java.io.File
import java.util.concurrent.Executors

/**
 * Offline Persian image text recognition.
 *
 * Google's on-device ML Kit text recognition has no Persian model, so the app
 * ships Tesseract with the `fas` (and `eng` for grades such as ST37 / IPE) model
 * and reads the picture on the phone. Nothing is uploaded and no network is
 * used; the recognised text goes back to Dart, where the same analyzer that
 * reads channel posts extracts the product, the price and the place.
 */
class OcrChannel(private val activity: Activity, messenger: BinaryMessenger) {
    companion object {
        const val CHANNEL = "ir.ironpin.ironpin/ocr"
        private const val PICK_IMAGE = 6131
        private const val LANGUAGE = "fas+eng"
        private const val MAX_SIDE = 2600
        private val ASSETS = listOf("fas.traineddata", "eng.traineddata")
    }

    private val executor = Executors.newSingleThreadExecutor()
    private var pendingPick: MethodChannel.Result? = null
    private var api: TessBaseAPI? = null
    private var initialised = false

    init {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "pickImage" -> pickImage(result)
                "recognize" -> recognize(call.argument<String>("path"), result)
                else -> result.notImplemented()
            }
        }
    }

    private fun pickImage(result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("BUSY", "A photo picker is already open", null)
            return
        }
        pendingPick = result
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "image/*"
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            activity.startActivityForResult(intent, PICK_IMAGE)
        } catch (e: Exception) {
            pendingPick = null
            result.error("PICKER", e.message, null)
        }
    }

    /** Returns true when the result belonged to the OCR picker. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK_IMAGE) return false
        val result = pendingPick ?: return true
        pendingPick = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return true
        }
        executor.execute {
            try {
                val dir = File(activity.cacheDir, "ocr").apply { mkdirs() }
                val out = File(dir, "pick-${System.currentTimeMillis()}.img")
                activity.contentResolver.openInputStream(uri)?.use { input ->
                    out.outputStream().use { output -> input.copyTo(output, 64 * 1024) }
                } ?: throw IllegalStateException("Cannot read the chosen picture")
                activity.runOnUiThread { result.success(out.absolutePath) }
            } catch (e: Exception) {
                activity.runOnUiThread { result.error("IMAGE", e.message, null) }
            }
        }
        return true
    }

    private fun recognize(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrEmpty()) {
            result.error("PATH", "No image path", null)
            return
        }
        val file = File(path)
        val allowed = file.canonicalPath.startsWith(activity.cacheDir.canonicalPath) ||
                file.canonicalPath.startsWith(activity.filesDir.canonicalPath)
        if (!allowed || !file.isFile) {
            result.error("PATH", "Image is not readable inside the app sandbox", null)
            return
        }
        executor.execute {
            var text = ""
            var error: String? = null
            var confidence: Double? = null
            try {
                val bitmap = decode(file)
                if (bitmap == null) throw IllegalStateException("Picture could not be decoded")
                val engine = engine()
                engine.pageSegMode = TessBaseAPI.PageSegMode.PSM_AUTO
                engine.setImage(bitmap)
                text = engine.getUTF8Text() ?: ""
                confidence = meanConfidence(engine)
                engine.clear()
                bitmap.recycle()
            } catch (e: Exception) {
                error = e.message ?: e.javaClass.simpleName
            }
            activity.runOnUiThread {
                result.success(mapOf(
                    "text" to text,
                    "confidence" to confidence,
                    "engine" to "tesseract-$LANGUAGE",
                    "error" to error
                ))
            }
        }
    }

    private fun decode(file: File): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.absolutePath, bounds)
        var sample = 1
        while (bounds.outWidth / sample > MAX_SIDE || bounds.outHeight / sample > MAX_SIDE) sample *= 2
        val options = BitmapFactory.Options().apply {
            inSampleSize = sample
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        return BitmapFactory.decodeFile(file.absolutePath, options)
    }

    /** Copies the bundled `tessdata` out of the APK once and initialises Tesseract. */
    @Synchronized
    private fun engine(): TessBaseAPI {
        val root = activity.filesDir
        val tessdata = File(root, "tessdata").apply { mkdirs() }
        for (name in ASSETS) {
            val target = File(tessdata, name)
            if (target.length() > 0) continue
            try {
                activity.assets.open("tessdata/$name").use { input ->
                    target.outputStream().use { output -> input.copyTo(output, 64 * 1024) }
                }
            } catch (_: Exception) {
                // A missing model is reported by init() below instead of guessing.
            }
        }
        val existing = api
        if (existing != null && initialised) return existing
        val created = existing ?: TessBaseAPI().also { api = it }
        if (!created.init(root.absolutePath, LANGUAGE)) {
            throw IllegalStateException("موتور OCR راه‌اندازی نشد؛ فایل زبان Tesseract در دسترس نیست")
        }
        initialised = true
        return created
    }

    /**
     * Word confidence when the bundled Tesseract exposes it. Read reflectively so
     * an engine upgrade that renames the getter cannot break the build; the Dart
     * side treats `null` as "unknown" and never invents a number.
     */
    private fun meanConfidence(engine: TessBaseAPI): Double? {
        return try {
            val method = engine.javaClass.methods.firstOrNull {
                it.parameterTypes.isEmpty() &&
                        (it.name == "meanConfidence" || it.name == "getMeanConfidence")
            }
            val value = method?.invoke(engine) as? Number
            value?.toDouble()?.let { if (it > 1.0) it / 100.0 else it }
        } catch (_: Throwable) {
            null
        }
    }

    fun dispose() {
        pendingPick?.success(null)
        pendingPick = null
        executor.shutdown()
        try {
            api?.recycle()
        } catch (_: Throwable) {
        }
        api = null
        initialised = false
    }
}
