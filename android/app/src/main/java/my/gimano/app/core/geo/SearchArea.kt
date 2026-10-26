package my.gimano.app.core.geo

/** Captured visible map footprint. In-memory only, never preferences or search history. */
object SearchArea {
    fun contains(wire: String, lat: Double, lng: Double): Boolean {
        val points = wire.split(';').mapNotNull { pair ->
            val p = pair.split(','); if (p.size != 2) null else p[0].toDoubleOrNull()?.let { x -> p[1].toDoubleOrNull()?.let { y -> x to y } }
        }
        if (points.size < 3) return false
        var inside = false
        for (i in points.indices) {
            val (x, y) = points[i]; val (px, py) = points[(i + points.size - 1) % points.size]
            val cross = (lng - px) * (y - py) - (lat - py) * (x - px)
            if (kotlin.math.abs(cross) < 1e-10 && lng in minOf(x, px)..maxOf(x, px) && lat in minOf(y, py)..maxOf(y, py)) return true
            if ((y > lat) != (py > lat) && lng < (px - x) * (lat - y) / (py - y) + x) inside = !inside
        }
        return inside
    }
}
