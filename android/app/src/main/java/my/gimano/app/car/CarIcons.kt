package my.gimano.app.car

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import androidx.car.app.model.CarColor
import androidx.car.app.model.CarIcon
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asAndroidPath
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.VectorGroup
import androidx.compose.ui.graphics.vector.VectorPath
import androidx.compose.ui.graphics.vector.toPath
import androidx.core.graphics.drawable.IconCompat
import my.gimano.app.core.nav.ManeuverFormatter
import my.gimano.app.ui.common.Duotone
import my.gimano.app.ui.common.GIcons
import my.gimano.app.ui.theme.ReportColors

/** The phone's own glyphs (Material maneuvers, Manotu duotone report icons) as car icons. */
object CarIcons {
    private val cache = HashMap<String, CarIcon>()

    /** Maneuver arrow, white on transparent: the host tints it for day/night. */
    fun maneuver(type: String): CarIcon = cache.getOrPut("m:$type") {
        CarIcon.Builder(IconCompat.createWithBitmap(render(GIcons.maneuver(ManeuverFormatter.icon(type)), 128, Color.White))).build()
    }

    /** Report tile for the "Lapor" grid, in the report's own colours. */
    fun report(type: String): CarIcon = cache.getOrPut("r:$type") {
        val d = ReportColors.duotone(type)
        val v = Duotone.vector(GIcons.report(type), d.stroke, d.fill)
        val size = 128
        val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val c = Canvas(bmp)
        val bg = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = d.tile.toArgb() }
        c.drawRoundRect(0f, 0f, size.toFloat(), size.toFloat(), size * 0.3f, size * 0.3f, bg)
        val inner = render(v, (size * 0.62).toInt(), null)
        c.drawBitmap(inner, size * 0.19f, size * 0.19f, null)
        CarIcon.Builder(IconCompat.createWithBitmap(bmp)).build()
    }

    fun tinted(icon: CarIcon, color: CarColor): CarIcon = CarIcon.Builder(icon).setTint(color).build()

    /** Draws an [ImageVector] (fills and strokes) into a bitmap; [force] replaces every colour. */
    fun render(v: ImageVector, sizePx: Int, force: Color?): Bitmap {
        val bmp = Bitmap.createBitmap(sizePx, sizePx, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        canvas.scale(sizePx / v.viewportWidth, sizePx / v.viewportHeight)
        fun draw(g: VectorGroup) {
            for (n in g) when (n) {
                is VectorGroup -> draw(n)
                is VectorPath -> {
                    val path = n.pathData.toPath().asAndroidPath()
                    path.fillType = if (n.pathFillType == androidx.compose.ui.graphics.PathFillType.EvenOdd) android.graphics.Path.FillType.EVEN_ODD else android.graphics.Path.FillType.WINDING
                    (n.fill as? SolidColor)?.let { b ->
                        val p = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                            style = Paint.Style.FILL; color = (force ?: b.value).toArgb(); alpha = (n.fillAlpha * 255).toInt()
                        }
                        canvas.drawPath(path, p)
                    }
                    (n.stroke as? SolidColor)?.let { b ->
                        if (n.strokeLineWidth > 0f) canvas.drawPath(path, Paint(Paint.ANTI_ALIAS_FLAG).apply {
                            style = Paint.Style.STROKE; color = (force ?: b.value).toArgb(); alpha = (n.strokeAlpha * 255).toInt()
                            strokeWidth = n.strokeLineWidth; strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND
                        })
                    }
                }
            }
        }
        draw(v.root)
        return bmp
    }
}
