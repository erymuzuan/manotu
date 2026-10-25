package my.gimano.app.car

import android.app.Presentation
import android.graphics.Rect
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.os.Bundle
import androidx.car.app.CarContext
import androidx.car.app.SurfaceCallback
import androidx.car.app.SurfaceContainer
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.Spacer
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.setViewTreeLifecycleOwner
import androidx.savedstate.SavedStateRegistry
import androidx.savedstate.SavedStateRegistryController
import androidx.savedstate.SavedStateRegistryOwner
import androidx.savedstate.setViewTreeSavedStateRegistryOwner
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import my.gimano.app.AppContainer
import my.gimano.app.BuildConfig
import my.gimano.app.core.geo.GeoPoint
import my.gimano.app.nav.DriveRenderer
import my.gimano.app.ui.common.Attribution
import my.gimano.app.ui.common.Speedometer
import my.gimano.app.ui.map.CameraCommand
import my.gimano.app.ui.map.GimanoMap
import my.gimano.app.ui.map.MapHandle
import my.gimano.app.ui.map.MapRenderState
import my.gimano.app.ui.theme.GimanoTheme

/** What the car surface shows: the same render state and camera commands as the phone map. */
data class CarMapContent(
    val render: MapRenderState = MapRenderState(),
    val camera: CameraCommand? = null,
    val navigating: Boolean = false,
    val speedKmh: Int? = null,
)

/**
 * Draws Manotu's own map on the Android Auto surface (docs/driving.md §5): a virtual display on the host's surface, with
 * a Presentation hosting the phone's map composable, the same steady arrow / camera renderer, restricted areas and the
 * "© OpenStreetMap contributors" line. Nothing here talks to the network beyond the map tiles the phone already loads.
 */
class CarMapSurface(private val carContext: CarContext, private val c: AppContainer) : SurfaceCallback {
    val content = MutableStateFlow(CarMapContent())
    val renderer = DriveRenderer()
    private val follow = MutableStateFlow(true)
    private val visible = MutableStateFlow<Rect?>(null)
    private val size = MutableStateFlow(0 to 0)
    private val dpi = MutableStateFlow(160)
    private var display: VirtualDisplay? = null
    private var presentation: Presentation? = null
    private var owner: SurfaceOwner? = null
    private val handle = MapHandle()
    private var resumeAtMs = 0L

    val following: StateFlow<Boolean> = follow

    override fun onSurfaceAvailable(container: SurfaceContainer) {
        val surface = container.surface ?: return
        release()
        size.value = container.width to container.height
        dpi.value = container.dpi
        val dm = carContext.getSystemService(DisplayManager::class.java)
        val vd = dm.createVirtualDisplay("manotu-car", container.width, container.height, container.dpi, surface,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_OWN_CONTENT_ONLY)
        display = vd
        val o = SurfaceOwner().also { owner = it }
        presentation = Presentation(carContext, vd.display).apply {
            val view = ComposeView(context).apply {
                setViewTreeLifecycleOwner(o)
                setViewTreeSavedStateRegistryOwner(o)
                setContent { CarMap() }
            }
            setContentView(view)
            show()
        }
        o.resume()
    }

    override fun onSurfaceDestroyed(container: SurfaceContainer) = release()

    override fun onVisibleAreaChanged(visibleArea: Rect) { visible.value = visibleArea }

    override fun onStableAreaChanged(stableArea: Rect) { if (visible.value == null) visible.value = stableArea }

    /** Pan (pan mode or a drag on touch screens): pauses the camera modes until the 10 s auto-recentre. */
    override fun onScroll(distanceX: Float, distanceY: Float) {
        handle.map?.scrollBy(-distanceX, -distanceY, 0)
        pause()
    }

    override fun onScale(focusX: Float, focusY: Float, scaleFactor: Float) {
        val m = handle.map ?: return
        val zoom = m.cameraPosition.zoom + Math.log(scaleFactor.toDouble()) / Math.log(2.0)
        m.moveCamera(org.maplibre.android.camera.CameraUpdateFactory.zoomTo(zoom))
        pause()
    }

    private fun pause() {
        follow.value = false
        resumeAtMs = android.os.SystemClock.elapsedRealtime() + my.gimano.app.core.location.FixRules.FOLLOW_RESUME_MS
    }

    fun recenter() { follow.value = true }

    /** Called about once a second by the session: resumes following 10 s after the last pan. */
    fun tick() {
        if (!follow.value && android.os.SystemClock.elapsedRealtime() >= resumeAtMs) follow.value = true
    }

    fun release() {
        owner?.destroy(); owner = null
        presentation?.dismiss(); presentation = null
        display?.release(); display = null
    }

    @Composable
    private fun CarMap() {
        val ct by content.collectAsState()
        val f by follow.collectAsState()
        val area by visible.collectAsState()
        val h = size.value.second
        val settings by c.settings.state.collectAsState()
        val restricted by c.restricted.areas.collectAsState()
        val dark = carContext.isDarkMode
        // The presentation renders at the car surface's dpi.
        val density = (dpi.value / 160f).coerceAtLeast(0.5f)
        // Visible area (outside the host's cards and strips) in dp of the presentation's display.
        val topDp = ((area?.top ?: 0) / density).toInt()
        val bottomDp = (((h - (area?.bottom ?: h)).coerceAtLeast(0)) / density).toInt()
        val startDp = ((area?.left ?: 0) / density).toInt()
        GimanoTheme(dark = dark) {
            Box(Modifier.fillMaxSize()) {
                GimanoMap(
                    styleUrl = if (dark) BuildConfig.MAP_STYLE_DARK_URL else settings.mapStyleUrl,
                    state = ct.render,
                    camera = ct.camera,
                    handle = handle,
                    modifier = Modifier.fillMaxSize(),
                    restricted = restricted,
                    drive = if (ct.navigating) renderer else null,
                    driveFollow = f,
                    driveTopDp = topDp, driveBottomDp = bottomDp,
                    topInsetDp = topDp, bottomInsetDp = bottomDp,
                )
                Column(Modifier.align(Alignment.BottomStart).padding(start = (startDp + 8).dp, bottom = (bottomDp + 6).dp)) {
                    ct.speedKmh?.let { Speedometer(it, null); Spacer(Modifier.height(4.dp)) }
                    Attribution()
                }
            }
        }
    }

    /** Lifecycle + saved state for the Compose view inside the Presentation (it has no activity). */
    private class SurfaceOwner : LifecycleOwner, SavedStateRegistryOwner {
        private val registry = LifecycleRegistry(this)
        private val saved = SavedStateRegistryController.create(this)
        override val lifecycle: Lifecycle get() = registry
        override val savedStateRegistry: SavedStateRegistry get() = saved.savedStateRegistry

        init {
            saved.performAttach()
            saved.performRestore(Bundle())
        }

        fun resume() { registry.currentState = Lifecycle.State.RESUMED }
        fun destroy() { if (registry.currentState != Lifecycle.State.INITIALIZED) registry.currentState = Lifecycle.State.DESTROYED }
    }

}
