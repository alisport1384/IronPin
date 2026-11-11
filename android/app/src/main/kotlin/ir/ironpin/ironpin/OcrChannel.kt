package ir.ironpin.ironpin

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.Paint
import android.os.Handler
import android.os.Looper
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
class OcrChannel(context: Context, messenger: BinaryMessenger) {

    private val appContext = context.applicationContext
    companion object {
        const val CHANNEL = "ir.ironpin.ironpin/ocr"
        private const val LANGUAGE = "fas+eng"
        private const val MAX_SIDE = 2600
        private val ASSETS = listOf("fas.traineddata", "eng.traineddata")
    }

    private val executor = Executors.newSingleThreadExecutor()
    private var api: TessBaseAPI? = null
    private var initialised = false

    init {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                // The cache directory the app may write a downloaded picture into.
                "cacheDir" -> result.success(appContext.cacheDir.absolutePath)
                "recognize" -> recognize(call.argument<String>("path"), result)
                else -> result.notImplemented()
            }
        }
    }

    private fun recognize(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrEmpty()) {
            result.error("PATH", "No image path", null)
            return
        }
        val file = File(path)
        val allowed = file.canonicalPath.startsWith(appContext.cacheDir.canonicalPath) ||
                file.canonicalPath.startsWith(appContext.filesDir.canonicalPath)
        if (!allowed || !file.isFile) {
            result.error("PATH", "Image is not readable inside the app sandbox", null)
            return
        }
        executor.execute {
            var text = ""
            var error: String? = null
            var confidence: Double? = null
            val passes = ArrayList<String>()
            try {
                val bitmap = decode(file)
                if (bitmap == null) throw IllegalStateException("Picture could not be decoded")
                val engine = engine()
                // Several readings of the same pixels, because no single setting
                // reads every picture: the picture as it is; a grey, larger,
                // higher-contrast copy; the same copy read as one uniform block
                // (a price table is one block, and automatic layout analysis
                // often splits its columns apart); and, for a dark-theme
                // screenshot, an inverted copy — Tesseract expects dark text on
                // a light page. Every reading goes back to Dart, which keeps the
                // one that yields the most product rows with a price and takes
                // phone numbers and map links from all of them. Nothing is
                // invented — every pass reads the same picture.
                val dark = isDark(bitmap)
                val base = if (dark) invert(bitmap) else bitmap
                val enhanced = enhance(base)
                val plan = listOf(
                    Pair(base, TessBaseAPI.PageSegMode.PSM_AUTO),
                    Pair(enhanced, TessBaseAPI.PageSegMode.PSM_AUTO),
                    Pair(enhanced, TessBaseAPI.PageSegMode.PSM_SINGLE_BLOCK),
                    Pair(enhanced, TessBaseAPI.PageSegMode.PSM_SPARSE_TEXT)
                )
                var best = ""
                for ((candidate, mode) in plan) {
                    // The sparse-text reading is the slowest and only helps a
                    // picture the other readings found almost no digits in.
                    if (mode == TessBaseAPI.PageSegMode.PSM_SPARSE_TEXT &&
                        best.count { it.isDigit() } >= 8
                    ) continue
                    try {
                        engine.pageSegMode = mode
                        engine.setImage(candidate)
                        val read = engine.getUTF8Text() ?: ""
                        val passConfidence = meanConfidence(engine)
                        if (read.isNotBlank()) passes.add(read)
                        if (score(read) > score(best)) {
                            best = read
                            // The confidence reported is the one of the reading
                            // that was kept, not of whichever pass ran last.
                            confidence = passConfidence
                        }
                    } catch (e: Exception) {
                        if (error == null) error = e.message ?: e.javaClass.simpleName
                    } finally {
                        engine.clear()
                    }
                }
                text = best
                if (text.isNotBlank()) error = null
                enhanced.recycle()
                if (base !== bitmap) base.recycle()
                bitmap.recycle()
            } catch (e: Throwable) {
                error = e.message ?: e.javaClass.simpleName
            }
            // The reply must be delivered on the main thread, but this class only
            // needs a Context (it never opens an activity of its own).
            Handler(Looper.getMainLooper()).post {
                result.success(mapOf(
                    "text" to text,
                    "passes" to passes,
                    "confidence" to confidence,
                    "engine" to "tesseract-$LANGUAGE",
                    "error" to error
                ))
            }
        }
    }

    /** Mean brightness of a coarse sample: a dark-theme screenshot is below 110. */
    private fun isDark(source: Bitmap): Boolean {
        val small = Bitmap.createScaledBitmap(source, 32, 32, true)
        val pixels = IntArray(32 * 32)
        small.getPixels(pixels, 0, 32, 0, 0, 32, 32)
        if (small !== source) small.recycle()
        var sum = 0L
        for (p in pixels) {
            sum += ((p shr 16 and 0xff) * 299 + (p shr 8 and 0xff) * 587 + (p and 0xff) * 114) / 1000
        }
        return sum / pixels.size < 110
    }

    /** Negative of the picture, so light-on-dark text becomes dark-on-light. */
    private fun invert(source: Bitmap): Bitmap {
        val out = Bitmap.createBitmap(source.width, source.height, Bitmap.Config.ARGB_8888)
        val paint = Paint().apply {
            colorFilter = ColorMatrixColorFilter(
                ColorMatrix(
                    floatArrayOf(
                        -1f, 0f, 0f, 0f, 255f,
                        0f, -1f, 0f, 0f, 255f,
                        0f, 0f, -1f, 0f, 255f,
                        0f, 0f, 0f, 1f, 0f
                    )
                )
            )
        }
        Canvas(out).drawBitmap(source, 0f, 0f, paint)
        return out
    }

    /** Persian letters and digits read: the only yardstick used to pick a pass. */
    private fun score(text: String): Int =
        text.count { c -> c in '\u0600'..'\u06FF' || c.isDigit() }

    /** Grey, higher-contrast, larger copy of the picture for the second pass. */
    private fun enhance(source: Bitmap): Bitmap {
        // Small pictures (a 720-pixel screenshot, a 600-pixel price card) are
        // enlarged more: Tesseract wants letters about 30 pixels tall.
        val longest = maxOf(source.width, source.height)
        val wanted = if (longest < 900) 3.0f else if (longest < 1600) 2.0f else 1.3f
        val scale = minOf(wanted, 3600f / longest)
        val width = (source.width * scale).toInt().coerceAtLeast(1)
        val height = (source.height * scale).toInt().coerceAtLeast(1)
        val out = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            colorFilter = ColorMatrixColorFilter(
                ColorMatrix(
                    floatArrayOf(
                        0.55f, 0.55f, 0.55f, 0f, 18f,
                        0.55f, 0.55f, 0.55f, 0f, 18f,
                        0.55f, 0.55f, 0.55f, 0f, 18f,
                        0f, 0f, 0f, 1f, 0f
                    )
                )
            )
        }
        Canvas(out).drawBitmap(source, null, android.graphics.Rect(0, 0, width, height), paint)
        return out
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
        val root = appContext.filesDir
        val tessdata = File(root, "tessdata").apply { mkdirs() }
        for (name in ASSETS) {
            val target = File(tessdata, name)
            if (target.length() > 0) continue
            try {
                appContext.assets.open("tessdata/$name").use { input ->
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
        executor.shutdown()
        try {
            api?.recycle()
        } catch (_: Throwable) {
        }
        api = null
        initialised = false
    }
}
