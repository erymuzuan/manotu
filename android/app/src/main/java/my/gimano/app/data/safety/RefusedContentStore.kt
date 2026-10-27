package my.gimano.app.data.safety

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import my.gimano.app.core.safety.AppealState
import my.gimano.app.core.safety.RefusedItem
import my.gimano.app.core.safety.RefusedKind
import my.gimano.app.core.safety.RefusedRules
import my.gimano.app.data.backup.SqlPort
import java.io.File
import java.time.Instant

/**
 * `refused_content` in the on-device DB (docs/privacy-and-backup.md): what the user wrote when the server refused it
 * (422 `content_rejected`), kept to edit or to appeal. Device-local like `outbox`: never in a Manotu backup, never
 * synced, sent to the server only inside an appeal the user sends. Rows older than 30 days are deleted (with their photo
 * files) by [purgeExpired], which runs on every read. Raw SQL (not a Room entity) so it runs on JDBC in tests.
 */
class RefusedContentStore(
    private val port: () -> SqlPort,
    /** Private folder for evidence photos: `<dir>/<id>/<n>.jpg`. */
    private val photoDir: File? = null,
    private val now: () -> Instant = Instant::now,
    private val io: kotlinx.coroutines.CoroutineDispatcher = Dispatchers.IO,
) {
    private val changes = MutableStateFlow(0L)
    private fun bump() { changes.value = changes.value + 1 }

    /** The items still kept, newest first. Re-read after every write of this store and after [purgeExpired]. */
    fun items(): Flow<List<RefusedItem>> = changes.map { allNow() }.flowOn(io)

    /** How many wait for a decision (the badge). */
    fun badge(): Flow<Int> = items().map { RefusedRules.badge(it, now()) }

    fun allNow(): List<RefusedItem> {
        purgeNow()
        return port().queryStrings("SELECT $COLS FROM refused_content ORDER BY created_at DESC").mapNotNull(::row)
    }

    suspend fun get(id: String): RefusedItem? = withContext(io) { allNow().firstOrNull { it.id == id } }

    /**
     * Keeps a refusal. The same text refused again for the same place replaces the earlier copy that was not appealed,
     * so retrying does not pile up duplicates. Returns the stored item.
     */
    suspend fun save(item: RefusedItem): RefusedItem = withContext(io) { saveNow(item) }

    fun saveNow(item: RefusedItem): RefusedItem {
        val text = RefusedRules.clipText(item.text)
        val p = port()
        val dupes = p.queryStrings(
            "SELECT id FROM refused_content WHERE kind = ? AND COALESCE(place_id,'') = ? AND text = ? AND appeal_state = 'none' AND id <> ?",
            item.kind.wire, item.placeId.orEmpty(), text, item.id,
        )
        dupes.forEach { deleteNow(it) }
        p.exec(
            "INSERT OR REPLACE INTO refused_content (id, kind, place_id, place_name, text, reasons_json, photos_json, created_at, appeal_state, rating) VALUES (?,?,?,?,?,?,?,?,?,?)",
            item.id, item.kind.wire, item.placeId, item.placeName?.replace('\u001f', ' '), text, RefusedRules.encodeList(item.reasons), RefusedRules.encodeList(item.photos),
            item.createdAt.toString(), item.appealState.wire, item.rating,
        )
        bump()
        return item.copy(text = text)
    }

    suspend fun setState(id: String, state: AppealState) = withContext(io) {
        port().exec("UPDATE refused_content SET appeal_state = ? WHERE id = ?", state.wire, id)
        bump()
    }

    suspend fun delete(id: String) = withContext(io) { deleteNow(id); bump() }

    /** Removes a refusal the user fixed and posted, unless an appeal for it is already with the maintainers. */
    suspend fun deleteIfUnappealed(id: String) = withContext(io) {
        if (port().queryStrings("SELECT id FROM refused_content WHERE id = ? AND appeal_state = 'none'", id).isNotEmpty()) { deleteNow(id); bump() }
    }

    /** "Delete my data": everything refused goes. */
    suspend fun clear() = withContext(io) {
        allIds().forEach { deleteFiles(it) }
        port().exec("DELETE FROM refused_content")
        bump()
    }

    /** Deletes rows (and photo files) older than 30 days. Returns how many went. */
    suspend fun purgeExpired(): Int = withContext(io) { purgeNow().also { if (it > 0) bump() } }

    private fun purgeNow(): Int {
        val rows = port().queryStrings("SELECT $COLS FROM refused_content").mapNotNull(::row)
        val gone = RefusedRules.expiredIds(rows, now())
        gone.forEach { deleteNow(it) }
        return gone.size
    }

    private fun allIds() = port().queryStrings("SELECT id FROM refused_content")

    private fun deleteNow(id: String) {
        deleteFiles(id)
        port().exec("DELETE FROM refused_content WHERE id = ?", id)
    }

    private fun deleteFiles(id: String) { photoDir?.resolve(id)?.deleteRecursively() }

    /** Writes a refused photo's bytes under the item [id] and returns the file name to keep in `photos_json`. */
    fun savePhoto(id: String, index: Int, bytes: ByteArray): String? {
        val dir = photoDir?.resolve(id)?.also { it.mkdirs() } ?: return null
        val name = "$index.jpg"
        return runCatching { dir.resolve(name).writeBytes(bytes); name }.getOrNull()
    }

    /** A stored photo (file name from `photos_json`), if the file is still there. Names with a path are refused. */
    fun photoFile(id: String, name: String): File? {
        if (name.contains('/') || name.contains('\\') || name.contains("..")) return null
        return photoDir?.resolve(id)?.resolve(name)?.takeIf { it.isFile }
    }

    private fun row(line: String): RefusedItem? {
        val f = line.split(SEP, limit = 10)
        if (f.size < 10) return null
        val kind = RefusedKind.of(f[1]) ?: return null
        val at = runCatching { Instant.parse(f[7]) }.getOrNull() ?: return null
        return RefusedItem(
            id = f[0], kind = kind, placeId = f[2].ifEmpty { null }, placeName = f[3].ifEmpty { null }, text = f[4],
            reasons = RefusedRules.decodeList(f[5]), photos = RefusedRules.decodeList(f[6]), createdAt = at, appealState = AppealState.of(f[8]), rating = f[9].toIntOrNull()?.takeIf { it in 1..5 },
        )
    }

    companion object {
        private const val SEP = "\u001f"
        private const val COLS = "id || '\u001f' || kind || '\u001f' || COALESCE(place_id,'') || '\u001f' || COALESCE(place_name,'') || '\u001f' || text || '\u001f' || reasons_json || '\u001f' || photos_json || '\u001f' || created_at || '\u001f' || appeal_state || '\u001f' || COALESCE(rating,'')"
    }
}
