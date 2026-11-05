package ir.ironpin.ironpin

import android.app.Activity
import android.content.Intent
import android.os.Environment
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class MainActivity: FlutterActivity() {
    private val requestExport = 6012
    private val ioExecutor = Executors.newSingleThreadExecutor()
    private var pending: MethodChannel.Result? = null
    private var pendingPaths: List<String> = emptyList()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ir.ironpin/storage").setMethodCallHandler { call, result ->
            when (call.method) {
                "logDirectory" -> {
                    val dir = File(getExternalFilesDir(Environment.DIRECTORY_DOCUMENTS) ?: filesDir, "IronPin/logs")
                    if (dir.exists() || dir.mkdirs()) result.success(dir.absolutePath)
                    else result.error("DIRECTORY", "Cannot create log directory", null)
                }
                "exportLogs" -> {
                    if (pending != null) { result.error("BUSY", "Another export is open", null); return@setMethodCallHandler }
                    pending = result
                    pendingPaths = call.argument<List<String>>("paths") ?: emptyList()
                    try {
                        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                        }, requestExport)
                    } catch (e: Exception) { pending=null; result.error("PICKER", e.message, null) }
                }
                else -> result.notImplemented()
            }
        }
    }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != requestExport) return
        val result=pending ?: return
        pending=null
        val tree=data?.data
        if (resultCode != Activity.RESULT_OK || tree == null) { result.success(null); return }
        val paths=pendingPaths.toList(); pendingPaths=emptyList()
        // SAF content-provider I/O must not block Android's main thread.
        ioExecutor.execute {
            try {
                val flags=(data?.flags ?: 0) and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                try { contentResolver.takePersistableUriPermission(tree,flags) } catch (_: SecurityException) { }
                val parent=DocumentsContract.buildDocumentUriUsingTree(tree,DocumentsContract.getTreeDocumentId(tree))
                val root=File(getExternalFilesDir(Environment.DIRECTORY_DOCUMENTS) ?: filesDir,"IronPin/logs").canonicalFile
                for (path in paths) {
                    val file=File(path).canonicalFile
                    if (!file.path.startsWith(root.path+File.separator) || file.extension != "md") throw SecurityException("Invalid log file")
                    val stamp=System.currentTimeMillis()
                    val uri=DocumentsContract.createDocument(contentResolver,parent,"text/markdown","${file.nameWithoutExtension}-export-$stamp.md") ?: throw IllegalStateException("Cannot create export")
                    contentResolver.openOutputStream(uri,"w")?.use { output -> file.inputStream().use { input -> input.copyTo(output) } } ?: throw IllegalStateException("Cannot write export")
                }
                runOnUiThread { result.success(tree.toString()) }
            } catch (e: Exception) { runOnUiThread { result.error("EXPORT",e.message,null) } }
        }
    }
    override fun onDestroy() {
        pending?.error("ACTIVITY_CLOSED","Export window closed",null);pending=null
        ioExecutor.shutdown()
        super.onDestroy()
    }
}
