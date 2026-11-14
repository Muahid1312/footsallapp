package com.saturdayfutsal.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.os.SystemClock
import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import androidx.core.content.FileProvider
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val io = Executors.newSingleThreadExecutor()
    private var pending: MethodChannel.Result? = null
    private var exportSource: File? = null
    private var maximumBytes = 0L
    private val documentRequest = 1405

    private fun privateFile(value: String): File {
        val file = File(value).canonicalFile
        val root = File(applicationInfo.dataDir).canonicalFile.path + File.separator
        require(file.path.startsWith(root) && file.isFile) { "Export file is unavailable" }
        return file
    }

    private fun safeName(value: String): String {
        require(value.matches(Regex("[A-Za-z0-9_.-]{1,120}"))) { "Invalid export name" }
        return value
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "saturday_futsal/clock")
            .setMethodCallHandler { call, result ->
                if (call.method == "elapsedRealtime") {
                    result.success(SystemClock.elapsedRealtime())
                } else {
                    result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "saturday_futsal/files")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "pick", "save" -> {
                            check(pending == null) { "Finish the current file selection first" }
                            val save = call.method == "save"
                            val intent = Intent(if (save) Intent.ACTION_CREATE_DOCUMENT else Intent.ACTION_OPEN_DOCUMENT)
                                .addCategory(Intent.CATEGORY_OPENABLE)
                            if (save) {
                                exportSource = privateFile(requireNotNull(call.argument<String>("path")))
                                intent.type = call.argument<String>("mime") ?: "application/octet-stream"
                                intent.putExtra(Intent.EXTRA_TITLE, safeName(requireNotNull(call.argument<String>("name"))))
                            } else {
                                val kind = call.argument<String>("kind")
                                require(kind == "csv" || kind == "backup")
                                maximumBytes = if (kind == "csv") 2L * 1024 * 1024 else 512L * 1024 * 1024
                                intent.type = "*/*"
                                intent.putExtra(Intent.EXTRA_MIME_TYPES, if (kind == "csv")
                                    arrayOf("text/csv", "text/comma-separated-values", "text/plain", "application/vnd.ms-excel")
                                    else arrayOf("application/zip", "application/octet-stream"))
                            }
                            pending = result
                            try { startActivityForResult(intent, documentRequest) }
                            catch (e: Exception) { pending = null; exportSource = null; throw e }
                        }
                        "share" -> {
                            val source = privateFile(requireNotNull(call.argument<String>("path")))
                            val name = safeName(requireNotNull(call.argument<String>("name")))
                            val mime = call.argument<String>("mime") ?: "application/octet-stream"
                            io.execute {
                                try {
                                    val directory = File(cacheDir, "shared_exports").apply { mkdirs() }
                                    // Remove only expired copies, leaving active share targets intact.
                                    directory.listFiles()?.filter { System.currentTimeMillis() - it.lastModified() > 7L * 86400000 }?.forEach { it.delete() }
                                    val target = File(directory, "${UUID.randomUUID()}_$name")
                                    source.copyTo(target)
                                    val uri = FileProvider.getUriForFile(this, "$packageName.files", target)
                                    runOnUiThread {
                                        try {
                                            startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
                                                type = mime; putExtra(Intent.EXTRA_STREAM, uri)
                                                clipData = android.content.ClipData.newRawUri("Saturday Futsal export", uri)
                                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                            }, "Share Saturday Futsal"))
                                            result.success(null)
                                        } catch (e: Exception) { result.error("share_failed", "No compatible sharing application is available.", null) }
                                    }
                                } catch (e: Exception) { runOnUiThread { result.error("share_failed", "Could not prepare this export for sharing.", null) } }
                            }
                        }
                        "jpeg" -> {
                            val bytes = requireNotNull(call.argument<ByteArray>("bytes"))
                            require(bytes.size <= 20 * 1024 * 1024)
                            io.execute {
                                try {
                                    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                                    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
                                    require(bounds.outWidth in 1..1200 && bounds.outHeight in 1..1200)
                                    val bitmap = requireNotNull(BitmapFactory.decodeByteArray(bytes, 0, bytes.size))
                                    val opaque = Bitmap.createBitmap(bitmap.width, bitmap.height, Bitmap.Config.ARGB_8888)
                                    Canvas(opaque).apply { drawColor(Color.WHITE); drawBitmap(bitmap, 0f, 0f, null) }
                                    val output = ByteArrayOutputStream()
                                    check(opaque.compress(Bitmap.CompressFormat.JPEG, 85, output))
                                    bitmap.recycle(); opaque.recycle()
                                    runOnUiThread { result.success(output.toByteArray()) }
                                } catch (e: Exception) { runOnUiThread { result.error("photo_failed", "This photo could not be processed.", null) } }
                            }
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) { result.error("file_failed", e.message ?: "File operation failed", null) }
            }
    }

    @Deprecated("Used for the system document picker")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != documentRequest) return
        val result = pending ?: return
        val source = exportSource
        pending = null; exportSource = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { result.success(if (source == null) null else false); return }
        val limit = maximumBytes
        io.execute {
            var local: File? = null
            try {
                if (source != null) {
                    requireNotNull(contentResolver.openOutputStream(uri, "wt")).use { output -> source.inputStream().use { it.copyTo(output, 65536) } }
                    runOnUiThread { result.success(true) }
                } else {
                    val selected = File(cacheDir, "import_${UUID.randomUUID()}.dat")
                    local = selected
                    requireNotNull(contentResolver.openInputStream(uri)).use { input -> selected.outputStream().use { output ->
                        val buffer = ByteArray(65536); var total = 0L
                        while (true) { val count = input.read(buffer); if (count < 0) break; total += count
                            require(total <= limit) { "Selected file is too large" }; output.write(buffer, 0, count) }
                    } }
                    runOnUiThread { result.success(selected.path) }
                }
            } catch (e: Exception) { local?.delete(); runOnUiThread { result.error("file_failed", "The selected file could not be read or saved. Check storage space and try again.", null) } }
        }
    }
}
