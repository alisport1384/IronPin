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
    private val requestBackupExport = 6013
    private val requestBackupImport = 6014
    private val maxBackupBytes = 512L * 1024 * 1024
    private var backupPath: String? = null
    private val ioExecutor = Executors.newSingleThreadExecutor()
    private var pending: MethodChannel.Result? = null
    private var pendingPaths: List<String> = emptyList()
    private var ocr: OcrChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ocr = OcrChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ir.ironpin/storage").setMethodCallHandler { call, result ->
            when (call.method) {
                "logDirectory" -> {
                    val dir = File(getExternalFilesDir(Environment.DIRECTORY_DOCUMENTS) ?: filesDir, "IronPin/logs")
                    if (dir.exists() || dir.mkdirs()) result.success(dir.absolutePath)
                    else result.error("DIRECTORY", "Cannot create log directory", null)
                }
                "backupDirectory" -> {
                    val dir=File(filesDir,"IronPin/backups")
                    if (dir.exists() || dir.mkdirs()) result.success(dir.absolutePath)
                    else result.error("DIRECTORY","Cannot create backup directory",null)
                }
                "exportBackup", "importBackup" -> {
                    if (pending != null) { result.error("BUSY","Another picker is open",null); return@setMethodCallHandler }
                    val exporting=call.method == "exportBackup"
                    try {
                        if (exporting) {
                            val root=File(filesDir,"IronPin/backups").canonicalFile
                            val file=File(call.argument<String>("path") ?: "").canonicalFile
                            if (file.parentFile != root || file.extension != "jsonl" || !file.isFile || file.length()>maxBackupBytes) throw SecurityException("Invalid backup path")
                            backupPath=file.path
                        }
                        pending=result
                        val intent=Intent(if (exporting) Intent.ACTION_CREATE_DOCUMENT else Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type=if (exporting) "application/x-ndjson" else "*/*"
                            if (exporting) putExtra(Intent.EXTRA_TITLE,call.argument<String>("name") ?: "IronPin.ironpin.jsonl")
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                        }
                        startActivityForResult(intent,if (exporting) requestBackupExport else requestBackupImport)
                    } catch (e: Exception) { pending=null; backupPath=null; result.error("PICKER",e.message,null) }
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
        if (requestCode == requestBackupExport || requestCode == requestBackupImport) {
            val result=pending ?: return
            pending=null
            val uri=data?.data
            val path=backupPath; backupPath=null
            if (resultCode != Activity.RESULT_OK || uri == null) { result.success(null); return }
            ioExecutor.execute {
                var incoming: File?=null
                try {
                    val answer: String
                    if (requestCode == requestBackupExport) {
                        val file=File(path ?: throw SecurityException("Missing backup path")).canonicalFile
                        val root=File(filesDir,"IronPin/backups").canonicalFile
                        if (file.parentFile != root || file.extension != "jsonl" || file.length()>maxBackupBytes) throw SecurityException("Invalid backup path")
                        contentResolver.openOutputStream(uri,"wt")?.use { out -> file.inputStream().use { input ->
                            val buffer=ByteArray(65536); var total=0L
                            while (true) { val n=input.read(buffer); if (n<0) break; total+=n; if (total>maxBackupBytes) throw IllegalStateException("Backup too large"); out.write(buffer,0,n) }
                        } } ?: throw IllegalStateException("Cannot write backup")
                        answer=uri.toString()
                    } else {
                        val root=File(filesDir,"IronPin/backups"); if (!root.exists() && !root.mkdirs()) throw IllegalStateException("Cannot create backup directory")
                        val file=File.createTempFile("incoming-",".jsonl",root); incoming=file
                        contentResolver.openInputStream(uri)?.use { input -> file.outputStream().use { out ->
                            val buffer=ByteArray(65536); var total=0L
                            while (true) { val n=input.read(buffer); if (n<0) break; total+=n; if (total>maxBackupBytes) throw IllegalStateException("Backup too large"); out.write(buffer,0,n) }
                        } } ?: throw IllegalStateException("Cannot read backup")
                        answer=file.absolutePath
                    }
                    runOnUiThread { result.success(answer) }
                } catch (e: Exception) {
                    incoming?.delete()
                    runOnUiThread { result.error("BACKUP",e.message,null) }
                }
            }
            return
        }
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
        ocr?.dispose(); ocr = null
        pending?.error("ACTIVITY_CLOSED","Export window closed",null);pending=null
        ioExecutor.shutdown()
        super.onDestroy()
    }
}
