package my.gimano.app.ui.map

import android.graphics.Bitmap
import android.graphics.PointF
import android.graphics.RectF
import androidx.compose.foundation.layout.Box
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Navigation
import androidx.compose.material.icons.filled.Place
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.drawscope.CanvasDrawScope
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import my.gimano.app.core.geo.GeoPoint
import my.gimano.app.ui.common.GIcons
import my.gimano.app.ui.theme.Gimano
import my.gimano.app.ui.theme.GimanoColors
import my.gimano.app.ui.theme.ReportColors
import org.maplibre.android.MapLibre
import org.maplibre.android.camera.CameraPosition
import org.maplibre.android.camera.CameraUpdateFactory
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.geometry.LatLngBounds
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.MapView
import org.maplibre.android.maps.Style
import org.maplibre.android.style.expressions.Expression
import org.maplibre.android.style.layers.CircleLayer
import org.maplibre.android.style.layers.Layer
import org.maplibre.android.style.layers.LineLayer
import org.maplibre.android.style.layers.Property
import org.maplibre.android.style.layers.PropertyFactory as PF
import org.maplibre.android.style.layers.SymbolLayer
import org.maplibre.android.style.sources.GeoJsonSource
import org.maplibre.geojson.Feature
import org.maplibre.geojson.FeatureCollection
import org.maplibre.geojson.LineString
import org.maplibre.geojson.Point

/** Imperative handle on the map for overlays (route bubbles) and the view model (bbox). */
@Stable
class MapHandle {
    internal var map: MapLibreMap? = null
    /** Bumped on every camera move so screen-projected overlays recompose. */
    var cameraVersion by mutableIntStateOf(0)
        internal set
    var userMovedCamera by mutableStateOf(false)
        internal set
    var ready by mutableStateOf(false)
        internal set

    fun project(p: GeoPoint): Offset? {
        val m = map ?: return null
        val pt = m.projection.toScreenLocation(LatLng(p.lat, p.lng))
        return Offset(pt.x, pt.y)
    }

    fun bounds(): VisibleBounds? {
        val b = map?.projection?.visibleRegion?.latLngBounds ?: return null
        return VisibleBounds(b.longitudeWest, b.latitudeSouth, b.longitudeEast, b.latitudeNorth)
    }

    fun clearUserMoved() { userMovedCamera = false }

    /** Screen pixel to map position (route builder drag and draw). */
    fun unproject(x: Float, y: Float): GeoPoint? {
        val m = map ?: return null
        val ll = m.projection.fromScreenLocation(PointF(x, y))
        return GeoPoint(ll.latitude, ll.longitude)
    }
}

private object Ids {
    const val ROUTES = "g-routes"
    const val ROUTE_TRAFFIC = "g-route-traffic"
    const val JAMS = "g-jams"
    const val DRIVERS = "g-drivers"
    const val ALERTS = "g-alerts"
    const val PUCK = "g-puck"
    const val TOLLS = "g-tolls"
    const val LAST_METRES = "g-last-metres"
    const val L_LAST_METRES = "g-l-last-metres"
    const val L_LAST_ENTRANCE = "g-l-last-entrance"
    const val DRIVE_PUCK = "g-drive-puck"
    const val TRAVELLED = "g-travelled"
    const val TRAVELLED_TAIL = "g-travelled-tail"
    const val L_TRAV_CASE = "g-l-trav-case"
    const val L_TRAV_TAIL_CASE = "g-l-trav-tail-case"
    const val L_TRAV = "g-l-trav"
    const val L_TRAV_TAIL = "g-l-trav-tail"
    const val L_DRIVE_PUCK = "g-l-drive-puck"
    const val L_DRIVE_PUCK_ACC = "g-l-drive-puck-acc"
    const val L_TOLLS = "g-l-tolls"
    const val PINS = "g-pins"
    const val L_ALT_CASE = "g-l-alt-case"
    const val L_ALT = "g-l-alt"
    const val L_ACT_CASE = "g-l-act-case"
    const val L_ACT = "g-l-act"
    const val L_TRAFFIC = "g-l-traffic"
    const val L_JAMS = "g-l-jams"
    const val L_DRIVERS = "g-l-drivers"
    const val L_ALERTS = "g-l-alerts"
    const val L_PUCK = "g-l-puck"
    const val L_PUCK_ACC = "g-l-puck-acc"
    const val L_PINS = "g-l-pins"
    const val BUILD_LINES = "g-build-lines"
    const val BUILD_PTS = "g-build-pts"
    const val L_B_CASE = "g-l-b-case"
    const val L_B_ROUTED = "g-l-b-routed"
    const val L_B_SKETCH = "g-l-b-sketch"
    const val L_B_UNMATCHED = "g-l-b-unmatched"
    const val L_B_DRAWN = "g-l-b-drawn"
    const val L_B_DRAWING = "g-l-b-drawing"
    const val L_B_PTS = "g-l-b-pts"
    const val RESTRICTED = "g-restricted"
    const val L_R_FILL = "g-l-r-fill"
    const val L_R_LINE = "g-l-r-line"
    const val L_R_LABEL = "g-l-r-label"
    const val HATCH = "g-restricted-hatch"
}

@Composable
fun GimanoMap(
    styleUrl: String,
    state: MapRenderState,
    camera: CameraCommand?,
    handle: MapHandle,
    modifier: Modifier = Modifier,
    onCameraIdle: (VisibleBounds) -> Unit = {},
    onMapClick: (GeoPoint) -> Unit = {},
    onMapLongClick: (GeoPoint) -> Unit = {},
    onAlertClick: (String) -> Unit = {},
    onRouteClick: (String) -> Unit = {},
    onPrivateClick: (String) -> Unit = {},
    /** Height (dp) of UI covering the bottom of the map (the home sheet, the place card): camera centres above it. */
    bottomInsetDp: Int = 0,
    /** Height (dp) covered at the top (the status bar, on the place card): camera centres below it. */
    topInsetDp: Int = 0,
    /**
     * A point the view stays centred on (the place card's pin): whenever the insets change (the card swiped between
     * peek and full), the camera moves back to it, centred in the visible map. Otherwise only the padding changes.
     */
    focus: GeoPoint? = null,
    /**
     * Raw touches before the map's own gestures (route builder: drag a point, draw with a finger). Return true to
     * consume the event (the map then neither pans nor clicks). The view is the map's, so an interceptor can hand the
     * rest of a gesture to the map (`view.onTouchEvent`).
     */
    touchInterceptor: ((android.view.View, android.view.MotionEvent) -> Boolean)? = null,
    /** Restricted areas (docs/safety.md §4 D): grey hatched, dashed outline, from zoom 12, "Kawasan larangan". */
    restricted: my.gimano.app.core.safety.RestrictedAreas? = null,
    /** Tap inside a drawn restricted area; return true to consume the tap. */
    onRestrictedClick: (GeoPoint) -> Boolean = { false },
    /**
     * Navigation (docs/driving.md §2–3): the steady arrow is drawn and the camera follows it on every frame. While
     * [driveFollow] is false (the driver panned), only the arrow moves.
     */
    drive: my.gimano.app.nav.DriveRenderer? = null,
    driveFollow: Boolean = true,
    /** Map covered by the turn banner (top) and the trip bar (bottom) while driving: the arrow is placed between them. */
    driveTopDp: Int = 0,
    driveBottomDp: Int = 0,
    /** Frame cap of the steady arrow / camera loop. */
    driveFrameMs: Long = 33,
    /** Covered on the left (the car's template card): the camera centres in the rest. */
    startInsetDp: Int = 0,
) {
    val context = LocalContext.current
    val density = LocalDensity.current
    val colors = Gimano.colors
    val lifecycle = LocalLifecycleOwner.current.lifecycle

    val iconBitmaps = rememberMapIcons(colors, density)

    val mapView = remember {
        MapLibre.getInstance(context)
        MapView(context).also { it.onCreate(null) }
    }
    var style by remember { mutableStateOf<Style?>(null) }
    var loadedStyleUrl by remember { mutableStateOf<String?>(null) }

    val idleCb by rememberUpdatedState(onCameraIdle)
    val clickCb by rememberUpdatedState(onMapClick)
    val longClickCb by rememberUpdatedState(onMapLongClick)
    val alertCb by rememberUpdatedState(onAlertClick)
    val routeCb by rememberUpdatedState(onRouteClick)
    val privateCb by rememberUpdatedState(onPrivateClick)
    val touchCb by rememberUpdatedState(touchInterceptor)
    val restrictedCb by rememberUpdatedState(onRestrictedClick)
    val restrictedLabel = androidx.compose.ui.res.stringResource(my.gimano.app.R.string.restricted_area)
    DisposableEffect(mapView) {
        mapView.setOnTouchListener { v, ev -> touchCb?.invoke(v, ev) ?: false }
        onDispose { mapView.setOnTouchListener(null) }
    }

    DisposableEffect(lifecycle, mapView) {
        val obs = LifecycleEventObserver { _, e ->
            when (e) {
                Lifecycle.Event.ON_START -> mapView.onStart()
                Lifecycle.Event.ON_RESUME -> mapView.onResume()
                Lifecycle.Event.ON_PAUSE -> mapView.onPause()
                Lifecycle.Event.ON_STOP -> mapView.onStop()
                else -> Unit
            }
        }
        lifecycle.addObserver(obs)
        onDispose {
            lifecycle.removeObserver(obs)
        }
    }
    DisposableEffect(mapView) {
        onDispose { mapView.onDestroy() }
    }

    // One-time map setup.
    LaunchedEffect(mapView) {
        mapView.getMapAsync { map ->
            handle.map = map
            map.uiSettings.apply {
                isLogoEnabled = false
                isAttributionEnabled = false // we render "© OpenStreetMap contributors" ourselves
                isCompassEnabled = false
                isRotateGesturesEnabled = true
                isTiltGesturesEnabled = true
            }
            map.setMinZoomPreference(3.0)
            map.moveCamera(CameraUpdateFactory.newCameraPosition(CameraPosition.Builder().target(LatLng(3.1390, 101.6869)).zoom(12.0).build()))
            map.addOnCameraMoveListener { handle.cameraVersion++ }
            map.addOnCameraMoveStartedListener { reason ->
                if (reason == MapLibreMap.OnCameraMoveStartedListener.REASON_API_GESTURE) handle.userMovedCamera = true
            }
            map.addOnCameraIdleListener {
                handle.cameraVersion++
                handle.bounds()?.let { idleCb(it) }
            }
            map.addOnMapClickListener { ll ->
                val sp = map.projection.toScreenLocation(ll)
                val r = 24f * density.density
                val rect = RectF(sp.x - r, sp.y - r, sp.x + r, sp.y + r)
                val alert = map.queryRenderedFeatures(rect, Ids.L_ALERTS).firstOrNull()?.getStringProperty("id")
                if (alert != null) {
                    alertCb(alert); return@addOnMapClickListener true
                }
                val pid = map.queryRenderedFeatures(rect, Ids.L_PINS).firstNotNullOfOrNull { f -> f.getStringProperty("pid") }
                if (pid != null) {
                    privateCb(pid); return@addOnMapClickListener true
                }
                val route = map.queryRenderedFeatures(rect, Ids.L_ALT, Ids.L_ACT).firstOrNull()?.getStringProperty("id")
                if (route != null) {
                    routeCb(route); return@addOnMapClickListener true
                }
                if (map.queryRenderedFeatures(sp, Ids.L_R_FILL).isNotEmpty() && restrictedCb(GeoPoint(ll.latitude, ll.longitude))) return@addOnMapClickListener true
                clickCb(GeoPoint(ll.latitude, ll.longitude))
                false
            }
            map.addOnMapLongClickListener { ll -> longClickCb(GeoPoint(ll.latitude, ll.longitude)); true }
            handle.ready = true
        }
    }

    // (Re)load the style when the URL changes.
    LaunchedEffect(styleUrl, handle.ready) {
        val map = handle.map ?: return@LaunchedEffect
        if (loadedStyleUrl == styleUrl) return@LaunchedEffect
        loadedStyleUrl = styleUrl
        style = null
        map.setStyle(Style.Builder().fromUri(styleUrl)) { s ->
            if (!colors.isDark) s.getLayer("background")?.setProperties(PF.backgroundColor(colors.mapBackground.toArgb()))
            // Route/traffic colours follow the basemap (light or dark style).
            installLayers(s, if (colors.isDark) my.gimano.app.ui.theme.DarkTokens else my.gimano.app.ui.theme.LightTokens, iconBitmaps)
            installRestricted(s, colors.isDark, restrictedLabel, density)
            style = s
        }
    }

    // Push data into sources whenever it changes: only the sources whose data changed (a new puck position must
    // not re-upload the whole route line).
    val pushed = remember { SourceCache() }
    LaunchedEffect(style, state) {
        val s = style ?: return@LaunchedEffect
        if (pushed.style !== s) { pushed.clear(); pushed.style = s }
        updateSources(s, state, pushed)
    }

    // The steady arrow and the camera that follows it, on every display frame while navigating.
    val followCb by rememberUpdatedState(driveFollow)
    LaunchedEffect(style, drive) {
        val s = style ?: return@LaunchedEffect
        val src = s.getSourceAs<GeoJsonSource>(Ids.DRIVE_PUCK) ?: return@LaunchedEffect
        val d = drive ?: run { src.setGeoJson(FeatureCollection.fromFeatures(emptyList())); return@LaunchedEffect }
        val map = handle.map ?: return@LaunchedEffect
        try {
            runDriveFrames(map, src, d, { followCb }, { mapView.height.toDouble() }, density.density.toDouble(),
                { driveTopDp * density.density.toDouble() }, { driveBottomDp * density.density.toDouble() }, driveFrameMs)
        } finally {
            src.setGeoJson(FeatureCollection.fromFeatures(emptyList()))
        }
    }

    // Restricted areas change rarely (daily at most): pushed on their own, never with every puck update.
    LaunchedEffect(style, restricted) {
        val s = style ?: return@LaunchedEffect
        val features = restricted?.rings.orEmpty().map { r ->
            Feature.fromGeometry(org.maplibre.geojson.Polygon.fromLngLats(listOf(r.points.map(::pt))))
        }
        s.getSourceAs<GeoJsonSource>(Ids.RESTRICTED)?.setGeoJson(FeatureCollection.fromFeatures(features))
    }

    LaunchedEffect(camera?.id, handle.ready) {
        val map = handle.map ?: return@LaunchedEffect
        val cmd = camera ?: return@LaunchedEffect
        // A new map (the car surface is recreated on every template change) has no size yet: a fit before layout is lost.
        while (mapView.width == 0 || mapView.height == 0) kotlinx.coroutines.delay(16)
        applyCamera(map, cmd, density, bottomInsetDp, topInsetDp, startInsetDp)
    }
    // When the covered area changes (home sheet appears / grows, place card swiped), shift the view so its centre
    // (or the focus point) stays in the middle of the visible map.
    LaunchedEffect(bottomInsetDp, topInsetDp, startInsetDp, focus, handle.ready) {
        val map = handle.map ?: return@LaunchedEffect
        if (camera is CameraCommand.Follow || drive != null) return@LaunchedEffect
        // A fit already accounts for the covered areas: re-fit with the new insets (a padding animation would cancel it).
        if (camera is CameraCommand.Fit) {
            while (mapView.width == 0 || mapView.height == 0) kotlinx.coroutines.delay(16)
            applyCamera(map, camera, density, bottomInsetDp, topInsetDp, startInsetDp)
            return@LaunchedEffect
        }
        val top = (topInsetDp * density.density).toDouble()
        val bottom = (bottomInsetDp * density.density).toDouble()
        val start = (startInsetDp * density.density).toDouble()
        if (focus != null) {
            // A pending MoveTo to the same point (the card just opened) keeps its zoom; this animation replaces it.
            val zoom = (camera as? CameraCommand.MoveTo)?.takeIf { it.point == focus }?.zoom
            val b = CameraPosition.Builder().target(LatLng(focus.lat, focus.lng)).padding(0.0, top, 0.0, bottom)
            zoom?.let { b.zoom(it) }
            map.animateCamera(CameraUpdateFactory.newCameraPosition(b.build()), 350)
        } else {
            map.animateCamera(CameraUpdateFactory.paddingTo(start, top, 0.0, bottom), 300)
        }
    }

    Box(modifier) {
        AndroidView(factory = { mapView }, modifier = Modifier.matchParentSize())
    }
}

private fun applyCamera(map: MapLibreMap, cmd: CameraCommand, density: Density, bottomInsetDp: Int = 0, topInsetDp: Int = 0, startInsetDp: Int = 0) {
    val px = { dp: Int -> (dp * density.density).toDouble() }
    when (cmd) {
        is CameraCommand.MoveTo -> {
            val b = CameraPosition.Builder().target(LatLng(cmd.point.lat, cmd.point.lng)).padding(px(startInsetDp), px(topInsetDp), 0.0, px(bottomInsetDp))
            cmd.zoom?.let { b.zoom(it) }
            val u = CameraUpdateFactory.newCameraPosition(b.build())
            if (cmd.animate) map.animateCamera(u, 700) else map.moveCamera(u)
        }
        is CameraCommand.Fit -> {
            if (cmd.points.size < 2) return
            val bounds = LatLngBounds.Builder().includes(cmd.points.map { LatLng(it.lat, it.lng) }).build()
            val side = px(cmd.sideDp).toInt()
            map.animateCamera(
                CameraUpdateFactory.newLatLngBounds(bounds, 0.0, 0.0, px(startInsetDp).toInt() + (cmd.startDp?.let { px(it).toInt() } ?: side), px(cmd.topDp).toInt(), side, px(cmd.bottomDp).toInt()),
                800,
            )
        }
        is CameraCommand.Follow -> {
            val pos = CameraPosition.Builder()
                .target(LatLng(cmd.point.lat, cmd.point.lng))
                .bearing(cmd.bearing).tilt(cmd.tilt).zoom(cmd.zoom)
                .padding(0.0, px(cmd.topDp), 0.0, px(cmd.bottomDp))
                .build()
            map.animateCamera(CameraUpdateFactory.newCameraPosition(pos), 950)
        }
        is CameraCommand.Reset2D -> {
            val pos = CameraPosition.Builder().target(LatLng(cmd.point.lat, cmd.point.lng)).bearing(0.0).tilt(0.0).zoom(cmd.zoom)
                .padding(0.0, px(topInsetDp), 0.0, px(bottomInsetDp)).build()
            map.animateCamera(CameraUpdateFactory.newCameraPosition(pos), 700)
        }
    }
}

private fun firstSymbolLayerId(style: Style): String? = style.layers.firstOrNull { it is SymbolLayer }?.id

private fun Style.addBelowLabels(layer: Layer, below: String?) {
    if (below != null) addLayerBelow(layer, below) else addLayer(layer)
}

private fun installLayers(style: Style, c: GimanoColors, icons: Map<String, Bitmap>) {
    icons.forEach { (k, v) -> style.addImage(k, v) }
    val empty = FeatureCollection.fromFeatures(emptyList())
    listOf(Ids.ROUTES, Ids.ROUTE_TRAFFIC, Ids.JAMS, Ids.DRIVERS, Ids.ALERTS, Ids.PUCK, Ids.PINS, Ids.BUILD_LINES, Ids.BUILD_PTS, Ids.TOLLS, Ids.DRIVE_PUCK, Ids.LAST_METRES, Ids.TRAVELLED, Ids.TRAVELLED_TAIL).forEach {
        style.addSource(GeoJsonSource(it, empty))
    }
    val below = firstSymbolLayerId(style)
    val trafficColor = Expression.match(
        Expression.get("level"), Expression.color(c.traffic1.toArgb()),
        Expression.stop(1, Expression.color(c.traffic1.toArgb())),
        Expression.stop(2, Expression.color(c.traffic2.toArgb())),
        Expression.stop(3, Expression.color(c.traffic3.toArgb())),
        Expression.stop(4, Expression.color(c.traffic4.toArgb())),
    )
    val width = { base: Float -> Expression.interpolate(Expression.exponential(1.5f), Expression.zoom(), Expression.stop(10, base * 0.5f), Expression.stop(14, base), Expression.stop(18, base * 2.2f)) }

    style.addBelowLabels(
        LineLayer(Ids.L_JAMS, Ids.JAMS).withProperties(
            PF.lineColor(trafficColor), PF.lineWidth(width(4f)), PF.lineOpacity(0.85f),
            PF.lineCap(Property.LINE_CAP_ROUND), PF.lineJoin(Property.LINE_JOIN_ROUND),
        ), below,
    )
    val alt = Expression.eq(Expression.get("selected"), false)
    val act = Expression.eq(Expression.get("selected"), true)
    style.addBelowLabels(LineLayer(Ids.L_ALT_CASE, Ids.ROUTES).withFilter(alt).withProperties(
        PF.lineColor(Color.White.toArgb()), PF.lineWidth(width(9f)), PF.lineCap(Property.LINE_CAP_ROUND), PF.lineJoin(Property.LINE_JOIN_ROUND),
    ), below)
    style.addBelowLabels(LineLayer(Ids.L_ALT, Ids.ROUTES).withFilter(alt).withProperties(
        PF.lineColor(c.routeAlt.toArgb()), PF.lineWidth(width(6f)), PF.lineCap(Property.LINE_CAP_ROUND), PF.lineJoin(Property.LINE_JOIN_ROUND),
    ), below)
    style.addBelowLabels(LineLayer(Ids.L_ACT_CASE, Ids.ROUTES).withFilter(act).withProperties(
        PF.lineColor(c.navBanner.toArgb()), PF.lineWidth(width(11f)), PF.lineCap(Property.LINE_CAP_ROUND), PF.lineJoin(Property.LINE_JOIN_ROUND),
    ), below)
    style.addBelowLabels(LineLayer(Ids.L_ACT, Ids.ROUTES).withFilter(act).withProperties(
        PF.lineColor(c.routeActive.toArgb()), PF.lineWidth(width(8f)), PF.lineCap(Property.LINE_CAP_ROUND), PF.lineJoin(Property.LINE_JOIN_ROUND),
    ), below)
    style.addBelowLabels(LineLayer(Ids.L_TRAFFIC, Ids.ROUTE_TRAFFIC).withProperties(
        PF.lineColor(trafficColor), PF.lineWidth(width(5f)), PF.lineCap(Property.LINE_CAP_ROUND), PF.lineJoin(Property.LINE_JOIN_ROUND),
    ), below)
    // Travelled part (docs/driving.md §6.3): light grey on a white casing, over the blue route and its traffic colours,
    // so those show only ahead. Stable part + per-frame tail (TravelledTrail): casings first, then the grey lines.
    listOf(Ids.L_TRAV_CASE to Ids.TRAVELLED, Ids.L_TRAV_TAIL_CASE to Ids.TRAVELLED_TAIL).forEach { (id, src) ->
        style.addBelowLabels(LineLayer(id, src).withProperties(
            PF.lineColor(Color.White.toArgb()), PF.lineWidth(width(12.5f)), PF.lineCap(Property.LINE_CAP_ROUND), PF.lineJoin(Property.LINE_JOIN_ROUND),
        ), below)
    }
    listOf(Ids.L_TRAV to Ids.TRAVELLED, Ids.L_TRAV_TAIL to Ids.TRAVELLED_TAIL).forEach { (id, src) ->
        style.addBelowLabels(LineLayer(id, src).withProperties(
            PF.lineColor(TravelledGrey.toArgb()), PF.lineWidth(width(8f)), PF.lineCap(Property.LINE_CAP_ROUND), PF.lineJoin(Property.LINE_JOIN_ROUND),
        ), below)
    }
    // Route builder: road legs solid, sketches dashed, unmatched drawn parts dashed orange, the raw drawn line faint.
    val kind = { k: String -> Expression.eq(Expression.get("kind"), k) }
    style.addBelowLabels(LineLayer(Ids.L_B_CASE, Ids.BUILD_LINES).withFilter(Expression.any(kind("routed"), kind("sketch"))).withProperties(
        PF.lineColor(Color.White.toArgb()), PF.lineWidth(width(10f)), PF.lineCap(Property.LINE_CAP_ROUND), PF.lineJoin(Property.LINE_JOIN_ROUND)), below)
    style.addBelowLabels(LineLayer(Ids.L_B_ROUTED, Ids.BUILD_LINES).withFilter(kind("routed")).withProperties(
        PF.lineColor(c.routeActive.toArgb()), PF.lineWidth(width(7f)), PF.lineCap(Property.LINE_CAP_ROUND), PF.lineJoin(Property.LINE_JOIN_ROUND)), below)
    style.addBelowLabels(LineLayer(Ids.L_B_SKETCH, Ids.BUILD_LINES).withFilter(kind("sketch")).withProperties(
        PF.lineColor(c.routeActive.toArgb()), PF.lineWidth(width(5f)), PF.lineDasharray(arrayOf(1.2f, 1.4f)), PF.lineJoin(Property.LINE_JOIN_ROUND)), below)
    style.addBelowLabels(LineLayer(Ids.L_B_DRAWN, Ids.BUILD_LINES).withFilter(kind("drawn")).withProperties(
        PF.lineColor(c.brandTint.toArgb()), PF.lineWidth(width(4f)), PF.lineOpacity(0.9f), PF.lineDasharray(arrayOf(0.6f, 1.6f)), PF.lineJoin(Property.LINE_JOIN_ROUND)), below)
    style.addBelowLabels(LineLayer(Ids.L_B_UNMATCHED, Ids.BUILD_LINES).withFilter(kind("unmatched")).withProperties(
        PF.lineColor(c.report.toArgb()), PF.lineWidth(width(6f)), PF.lineDasharray(arrayOf(1.2f, 1.2f)), PF.lineJoin(Property.LINE_JOIN_ROUND)), below)
    style.addLayer(LineLayer(Ids.L_B_DRAWING, Ids.BUILD_LINES).withFilter(kind("drawing")).withProperties(
        PF.lineColor(c.brandTint.toArgb()), PF.lineWidth(5f), PF.lineCap(Property.LINE_CAP_ROUND), PF.lineJoin(Property.LINE_JOIN_ROUND)))
    val role = { r: String -> Expression.eq(Expression.get("role"), r) }
    val sel = Expression.eq(Expression.get("sel"), true)
    style.addLayer(CircleLayer(Ids.L_B_PTS, Ids.BUILD_PTS).withProperties(
        PF.circleRadius(Expression.switchCase(role("shape"), Expression.literal(6f), Expression.literal(9f))),
        PF.circleColor(Expression.switchCase(
            role("shape"), Expression.color(Color.White.toArgb()),
            role("end"), Expression.color(c.brandInk.toArgb()),
            Expression.color(c.brand.toArgb()))),
        PF.circleStrokeColor(Expression.switchCase(
            sel, Expression.color(c.report.toArgb()),
            role("shape"), Expression.color(c.brand.toArgb()),
            Expression.color(Color.White.toArgb()))),
        PF.circleStrokeWidth(Expression.switchCase(sel, Expression.literal(4f), Expression.literal(2.5f))),
        PF.circlePitchAlignment(Property.CIRCLE_PITCH_ALIGNMENT_MAP),
    ))
    style.addLayer(CircleLayer(Ids.L_DRIVERS, Ids.DRIVERS).withProperties(
        PF.circleColor(c.brand.toArgb()), PF.circleRadius(5.5f), PF.circleStrokeColor(Color.White.toArgb()), PF.circleStrokeWidth(2f),
    ))
    style.addLayer(SymbolLayer(Ids.L_PINS, Ids.PINS).withProperties(
        PF.iconImage(Expression.get("icon")), PF.iconAnchor(Property.ICON_ANCHOR_BOTTOM), PF.iconAllowOverlap(true), PF.iconIgnorePlacement(true),
    ))
    // Last metres: round dots (a zero-length dash with round caps), blue to the entrance, grey on to the pin.
    val lastKind = { k: String -> Expression.eq(Expression.get("kind"), k) }
    style.addLayer(LineLayer(Ids.L_LAST_METRES, Ids.LAST_METRES).withFilter(Expression.any(lastKind("entrance"), lastKind("pin"))).withProperties(
        PF.lineColor(Expression.switchCase(lastKind("entrance"), Expression.color(c.routeActive.toArgb()), Expression.color(android.graphics.Color.rgb(0x8A, 0x94, 0xA6)))),
        PF.lineWidth(Expression.interpolate(Expression.linear(), Expression.zoom(), Expression.stop(14, 3f), Expression.stop(18, 7f))),
        PF.lineCap(Property.LINE_CAP_ROUND), PF.lineDasharray(arrayOf(0.01f, 2f)),
    ))
    style.addLayer(CircleLayer(Ids.L_LAST_ENTRANCE, Ids.LAST_METRES).withFilter(lastKind("entrance-pt")).withProperties(
        PF.circleRadius(6f), PF.circleColor(c.routeActive.toArgb()), PF.circleStrokeColor(Color.White.toArgb()), PF.circleStrokeWidth(2.5f),
        PF.circlePitchAlignment(Property.CIRCLE_PITCH_ALIGNMENT_MAP),
    ))
    style.addLayer(SymbolLayer(Ids.L_TOLLS, Ids.TOLLS).withProperties(
        PF.iconImage("toll"), PF.iconAnchor(Property.ICON_ANCHOR_BOTTOM), PF.iconAllowOverlap(true), PF.iconIgnorePlacement(true),
        PF.iconSize(Expression.interpolate(Expression.linear(), Expression.zoom(), Expression.stop(10, 0.55f), Expression.stop(15, 0.9f))),
    ))
    style.addLayer(SymbolLayer(Ids.L_ALERTS, Ids.ALERTS).withProperties(
        PF.iconImage(Expression.concat(Expression.literal("alert-"), Expression.get("type"))),
        PF.iconAnchor(Property.ICON_ANCHOR_BOTTOM), PF.iconAllowOverlap(true), PF.iconIgnorePlacement(true),
        PF.iconSize(Expression.interpolate(Expression.linear(), Expression.zoom(), Expression.stop(10, 0.6f), Expression.stop(15, 1f))),
    ))
    addPuckLayers(style, Ids.PUCK, Ids.L_PUCK_ACC, Ids.L_PUCK)
    addPuckLayers(style, Ids.DRIVE_PUCK, Ids.L_DRIVE_PUCK_ACC, Ids.L_DRIVE_PUCK)
}

private fun addPuckLayers(style: Style, source: String, accId: String, puckId: String) {
    // Accuracy circle (metres → pixels: r_px = acc / (156543.03 · cos φ / 2^zoom)), under the puck.
    style.addLayer(CircleLayer(accId, source).withProperties(
        PF.circleRadius(Expression.interpolate(Expression.exponential(2f), Expression.zoom(),
            Expression.stop(0, Expression.get("acc0")),
            Expression.stop(22, Expression.product(Expression.get("acc0"), Expression.literal(4194304.0))))),
        PF.circleColor(android.graphics.Color.argb(40, 0, 71, 171)),
        PF.circleStrokeColor(android.graphics.Color.argb(110, 0, 71, 171)), PF.circleStrokeWidth(1.5f),
        PF.circlePitchAlignment(Property.CIRCLE_PITCH_ALIGNMENT_MAP),
    ))
    style.addLayer(SymbolLayer(puckId, source).withProperties(
        PF.iconImage("puck"), PF.iconRotate(Expression.get("bearing")), PF.iconRotationAlignment(Property.ICON_ROTATION_ALIGNMENT_MAP),
        PF.iconPitchAlignment(Property.ICON_PITCH_ALIGNMENT_MAP),
        PF.iconAllowOverlap(true), PF.iconIgnorePlacement(true),
    ))
}

/**
 * The per-frame loop (docs/driving.md §3): one animated puck, and the camera following it every frame. Returning to
 * follow after a pan blends from where the camera is over [RESUME_BLEND_MS]. Shared by the phone map and the car surface.
 */
internal suspend fun runDriveFrames(
    map: MapLibreMap, src: GeoJsonSource, d: my.gimano.app.nav.DriveRenderer,
    follow: () -> Boolean, heightPx: () -> Double, density: Double,
    topInsetPx: () -> Double = { 0.0 },
    bottomInsetPx: () -> Double = { 0.0 },
    /** Frame cap: the arrow and camera need ~30 fps, not the display's 120 Hz (the main thread also serves the car). */
    minFrameMs: Long = 33,
) {
    var wasFollowing = false
    var lastFrame = 0L
    val style = map.style
    val travelled = style?.getSourceAs<GeoJsonSource>(Ids.TRAVELLED)
    val travelledTail = style?.getSourceAs<GeoJsonSource>(Ids.TRAVELLED_TAIL)
    var trailShown = false
    try {
    var blendFrom: CameraPosition? = null
    var blendStart = 0L
    while (true) {
        androidx.compose.runtime.withFrameNanos { }
        val now = android.os.SystemClock.elapsedRealtime()
        if (now - lastFrame < minFrameMs) continue
        lastFrame = now
        val hPx = heightPx()
        val inset = topInsetPx()
        val visible = (hPx - inset - bottomInsetPx()).coerceAtLeast(hPx * 0.3)
        val f = d.frame(now, visible / density) ?: continue
        val t = f.trail
        if (t != null) {
            t.stable?.let { travelled?.setGeoJson(lineOrEmpty(it)) }
            travelledTail?.setGeoJson(lineOrEmpty(t.tail))
            trailShown = true
        } else if (trailShown) {
            travelled?.setGeoJson(lineOrEmpty(emptyList())); travelledTail?.setGeoJson(lineOrEmpty(emptyList()))
            trailShown = false
        }
        src.setGeoJson(Feature.fromGeometry(pt(f.point)).apply {
            addNumberProperty("bearing", f.bearing)
            addNumberProperty("acc0", (f.accuracyM ?: 0.0) / (156543.03 * kotlin.math.cos(Math.toRadians(f.point.lat))))
        })
        val following = follow()
        if (following && !wasFollowing) { blendFrom = map.cameraPosition; blendStart = now }
        wasFollowing = following
        if (!following || hPx <= 0) continue
        // Arrow at anchorY of the uncovered height; the camera centre is moved there with padding.
        val y = inset + f.anchorY * visible
        val top = (2 * y - hPx).coerceAtLeast(0.0)
        val bottom = (hPx - 2 * y).coerceAtLeast(0.0)
        var target = LatLng(f.point.lat, f.point.lng)
        var zoom = f.zoom
        var tilt = f.tilt
        var bearing = f.bearing
        blendFrom?.let { b ->
            val t = ((now - blendStart) / RESUME_BLEND_MS.toDouble()).coerceIn(0.0, 1.0)
            if (t >= 1.0) blendFrom = null else {
                val e = t * t * (3 - 2 * t)
                val from = b.target ?: target
                target = LatLng(from.latitude + (target.latitude - from.latitude) * e, from.longitude + (target.longitude - from.longitude) * e)
                zoom = b.zoom + (zoom - b.zoom) * e
                tilt = b.tilt + (tilt - b.tilt) * e
                bearing = b.bearing + my.gimano.app.core.geo.GeoMath.angleDiff(b.bearing, bearing) * e
            }
        }
        map.moveCamera(CameraUpdateFactory.newCameraPosition(
            CameraPosition.Builder().target(target).zoom(zoom).tilt(tilt).bearing(bearing).padding(0.0, top, 0.0, bottom).build()))
    }
    } finally {
        // Drive over (or the style changed): no grey line left behind on the map.
        travelled?.setGeoJson(lineOrEmpty(emptyList())); travelledTail?.setGeoJson(lineOrEmpty(emptyList()))
    }
}

private fun pt(p: GeoPoint) = Point.fromLngLat(p.lng, p.lat)

/** #C3CAD6, the travelled part of the route (§6.3). */
private val TravelledGrey = Color(0xFFC3CAD6)

private fun lineOrEmpty(points: List<GeoPoint>): FeatureCollection =
    FeatureCollection.fromFeatures(if (points.size < 2) emptyList() else listOf(Feature.fromGeometry(LineString.fromLngLats(points.map(::pt)))))

/**
 * Restricted areas, under the labels and the route lines: a translucent grey hatch, a dashed grey outline (zoom ≥ 12)
 * and a "Kawasan larangan" label (no names, no kinds).
 */
private fun installRestricted(style: Style, dark: Boolean, label: String, density: Density) {
    style.addSource(GeoJsonSource(Ids.RESTRICTED, FeatureCollection.fromFeatures(emptyList())))
    val ink = if (dark) Color(0xFFA9B6CF) else Color(0xFF4E5D78)
    style.addImage(Ids.HATCH, hatch(ink, density))
    // Under the first route layer (so routes stay on top) and under every label.
    val below = style.layers.firstOrNull { it.id == Ids.L_JAMS }?.id ?: firstSymbolLayerId(style)
    style.addBelowLabels(org.maplibre.android.style.layers.FillLayer(Ids.L_R_FILL, Ids.RESTRICTED).withProperties(
        PF.fillPattern(Ids.HATCH), PF.fillOpacity(0.9f),
    ).apply { minZoom = 12f }, below)
    style.addBelowLabels(LineLayer(Ids.L_R_LINE, Ids.RESTRICTED).withProperties(
        PF.lineColor(ink.toArgb()), PF.lineWidth(1.6f), PF.lineDasharray(arrayOf(3f, 2f)), PF.lineOpacity(0.9f),
    ).apply { minZoom = 12f }, below)
    style.addLayerBelow(SymbolLayer(Ids.L_R_LABEL, Ids.RESTRICTED).withProperties(
        PF.textField(label), PF.textFont(arrayOf("Noto Sans Bold")), PF.textSize(12f),
        PF.textColor(ink.toArgb()), PF.textHaloColor((if (dark) Color(0xFF0E1626) else Color.White).toArgb()), PF.textHaloWidth(1.5f),
        PF.symbolPlacement(Property.SYMBOL_PLACEMENT_POINT), PF.textAllowOverlap(false),
    ).apply { minZoom = 13f }, Ids.L_B_DRAWING)
}

/** 12 dp tile: translucent grey wash with one diagonal stroke (tiles into a hatch). */
private fun hatch(ink: Color, density: Density): Bitmap = render(12f, 12f, density) { size ->
    drawRect(ink.copy(alpha = 0.16f))
    val w = 1.4f * density.density
    drawLine(ink.copy(alpha = 0.55f), Offset(0f, size.height), Offset(size.width, 0f), strokeWidth = w)
    drawLine(ink.copy(alpha = 0.55f), Offset(-size.width / 2, size.height / 2), Offset(size.width / 2, -size.height / 2), strokeWidth = w)
    drawLine(ink.copy(alpha = 0.55f), Offset(size.width / 2, size.height * 1.5f), Offset(size.width * 1.5f, size.height / 2), strokeWidth = w)
}

/** What each source last received, so unchanged data is never pushed again. */
internal class SourceCache {
    var style: Style? = null
    private val last = HashMap<String, Any?>()
    fun clear() = last.clear()
    /** Runs [push] only when [key] differs from what [id] last received. */
    fun push(id: String, key: Any?, push: () -> Unit) {
        if (last.containsKey(id) && last[id] == key) return
        last[id] = key
        push()
    }
}

private const val RESUME_BLEND_MS = 800L

internal fun updateSources(style: Style, s: MapRenderState, cache: SourceCache) {
    cache.push(Ids.ROUTES, s.routes) { pushRoutes(style, s) }
    cache.push(Ids.ROUTE_TRAFFIC, s.routes to s.showTraffic) { pushTraffic(style, s) }
    cache.push(Ids.JAMS, Triple(s.jams, s.showTraffic, s.routes.isNotEmpty())) { pushJams(style, s) }
    cache.push(Ids.DRIVERS, Triple(s.drivers, s.showDrivers, s.navigating)) { pushDrivers(style, s) }
    cache.push(Ids.ALERTS, s.alerts to s.showAlerts) { pushAlerts(style, s) }
    cache.push(Ids.TOLLS, s.tolls) { style.getSourceAs<GeoJsonSource>(Ids.TOLLS)?.setGeoJson(FeatureCollection.fromFeatures(s.tolls.map { Feature.fromGeometry(pt(it)) })) }
    cache.push(Ids.PUCK, Triple(s.puck, s.puckBearing, s.puckAccuracyM)) { pushPuck(style, s) }
    cache.push(Ids.LAST_METRES, s.lastMetres) {
        val f = s.lastMetres.flatMap { l ->
            listOfNotNull(
                Feature.fromGeometry(LineString.fromLngLats(l.points.map(::pt))).apply { addStringProperty("kind", l.kind) },
                if (l.kind == "entrance") Feature.fromGeometry(pt(l.points.last())).apply { addStringProperty("kind", "entrance-pt") } else null,
            )
        }
        style.getSourceAs<GeoJsonSource>(Ids.LAST_METRES)?.setGeoJson(FeatureCollection.fromFeatures(f))
    }
    cache.push(Ids.PINS, Triple(s.privatePins, s.stops, s.pin)) { pushPins(style, s) }
    cache.push(Ids.BUILD_LINES, s.builder) { pushBuilder(style, s) }
}

private fun pushRoutes(style: Style, s: MapRenderState) {
    // Draw alternatives first so the selected route is on top within the same source.
    val routeFeatures = s.routes.sortedBy { it.selected }.filter { it.points.size >= 2 }.map { r ->
        Feature.fromGeometry(LineString.fromLngLats(r.points.map(::pt))).apply {
            addStringProperty("id", r.id); addBooleanProperty("selected", r.selected)
        }
    }
    style.getSourceAs<GeoJsonSource>(Ids.ROUTES)?.setGeoJson(FeatureCollection.fromFeatures(routeFeatures))
}

private fun pushTraffic(style: Style, s: MapRenderState) {

    val traffic = if (!s.showTraffic) emptyList() else s.routes.filter { it.selected }.flatMap { r ->
        r.traffic.filter { it.level > 0 }.mapNotNull { seg ->
            val from = seg.fromIndex.coerceIn(0, r.points.lastIndex)
            val to = seg.toIndex.coerceIn(0, r.points.lastIndex)
            if (to - from < 1) null else Feature.fromGeometry(LineString.fromLngLats(r.points.subList(from, to + 1).map(::pt))).apply {
                addNumberProperty("level", seg.level.coerceIn(1, 4))
            }
        }
    }
    style.getSourceAs<GeoJsonSource>(Ids.ROUTE_TRAFFIC)?.setGeoJson(FeatureCollection.fromFeatures(traffic))
}

private fun pushJams(style: Style, s: MapRenderState) {

    val jams = if (!s.showTraffic || s.routes.isNotEmpty()) emptyList() else s.jams.filter { it.second.size >= 2 }.map { (j, pts) ->
        Feature.fromGeometry(LineString.fromLngLats(pts.map(::pt))).apply { addNumberProperty("level", j.level.coerceIn(1, 4)) }
    }
    style.getSourceAs<GeoJsonSource>(Ids.JAMS)?.setGeoJson(FeatureCollection.fromFeatures(jams))
}

private fun pushDrivers(style: Style, s: MapRenderState) {

    val drivers = if (!s.showDrivers || s.navigating) emptyList() else s.drivers.map { d -> Feature.fromGeometry(Point.fromLngLat(d.lng, d.lat)) }
    style.getSourceAs<GeoJsonSource>(Ids.DRIVERS)?.setGeoJson(FeatureCollection.fromFeatures(drivers))
}

private fun pushAlerts(style: Style, s: MapRenderState) {

    val alerts = if (!s.showAlerts) emptyList() else s.alerts.map { a ->
        Feature.fromGeometry(Point.fromLngLat(a.lng, a.lat)).apply {
            addStringProperty("id", a.id)
            addStringProperty("type", if (a.type in GIcons.reportTypes) a.type else "hazard")
        }
    }
    style.getSourceAs<GeoJsonSource>(Ids.ALERTS)?.setGeoJson(FeatureCollection.fromFeatures(alerts))
}

private fun pushPuck(style: Style, s: MapRenderState) {

    val puck = s.puck?.let { g ->
        listOf(Feature.fromGeometry(pt(g)).apply {
            addNumberProperty("bearing", s.puckBearing)
            // Radius at zoom 0 in pixels; 0 hides the circle (no accuracy known).
            val acc = s.puckAccuracyM ?: 0.0
            addNumberProperty("acc0", acc / (156543.03 * kotlin.math.cos(Math.toRadians(g.lat))))
        })
    } ?: emptyList()
    style.getSourceAs<GeoJsonSource>(Ids.PUCK)?.setGeoJson(FeatureCollection.fromFeatures(puck))
}

private fun pushPins(style: Style, s: MapRenderState) {

    val pins = (s.privatePins.map { (id, g) -> Feature.fromGeometry(pt(g)).apply { addStringProperty("icon", "private"); addStringProperty("pid", id) } } +
        s.stops.map { Feature.fromGeometry(pt(it)).apply { addStringProperty("icon", "stop") } } +
        listOfNotNull(s.pin?.let { Feature.fromGeometry(pt(it)).apply { addStringProperty("icon", "pin") } }))
    style.getSourceAs<GeoJsonSource>(Ids.PINS)?.setGeoJson(FeatureCollection.fromFeatures(pins))
}

private fun pushBuilder(style: Style, s: MapRenderState) {

    val b = s.builder
    val lines = b?.lines.orEmpty().filter { it.points.size >= 2 }.map { l ->
        Feature.fromGeometry(LineString.fromLngLats(l.points.map(::pt))).apply { addStringProperty("kind", l.kind) }
    }
    style.getSourceAs<GeoJsonSource>(Ids.BUILD_LINES)?.setGeoJson(FeatureCollection.fromFeatures(lines))
    val marks = b?.marks.orEmpty().sortedBy { it.selected }.map { m ->
        Feature.fromGeometry(pt(m.point)).apply { addStringProperty("role", m.role); addBooleanProperty("sel", m.selected) }
    }
    style.getSourceAs<GeoJsonSource>(Ids.BUILD_PTS)?.setGeoJson(FeatureCollection.fromFeatures(marks))
}

/** Rasterises Gimano's own pebble markers (Material Symbols glyph on a type-coloured tile). */
@Composable
private fun rememberMapIcons(c: GimanoColors, density: Density): Map<String, Bitmap> {
    val painters = GIcons.reportTypes.associateWith { t ->
        val d = ReportColors.duotone(t)
        rememberVectorPainter(my.gimano.app.ui.common.Duotone.vector(GIcons.report(t), d.stroke, d.fill))
    }
    val navPainter = rememberVectorPainter(Icons.Filled.Navigation)
    val pinPainter = rememberVectorPainter(Icons.Filled.Place)
    val tollPainter = rememberVectorPainter(my.gimano.app.ui.common.Duotone.vector("toll", c.brandInk, c.brandTint))
    return remember(c, density) {
        val out = HashMap<String, Bitmap>()
        painters.forEach { (type, p) -> out["alert-$type"] = pebble(p, ReportColors.duotone(type).tile, ReportColors.duotone(type).stroke, density, 38f) }
        out["puck"] = puck(navPainter, c.brand, density)
        out["toll"] = pebble(tollPainter, c.brandMist, c.brandInk, density, 34f)
        out["pin"] = pin(pinPainter, c.report, density, 44f)
        out["stop"] = pin(pinPainter, c.brand, density, 36f)
        out["private"] = pin(pinPainter, c.brandInk, density, 38f)
        out
    }
}

private fun render(sizeDpW: Float, sizeDpH: Float, density: Density, block: androidx.compose.ui.graphics.drawscope.DrawScope.(Size) -> Unit): Bitmap {
    val w = (sizeDpW * density.density).toInt()
    val h = (sizeDpH * density.density).toInt()
    val img = ImageBitmap(w, h)
    val canvas = androidx.compose.ui.graphics.Canvas(img)
    val size = Size(w.toFloat(), h.toFloat())
    CanvasDrawScope().draw(density, LayoutDirection.Ltr, canvas, size) { block(size) }
    return img.asAndroidBitmap()
}

private fun pebble(icon: Painter, bg: Color, ring: Color, density: Density, dp: Float): Bitmap = render(dp, dp + 6, density) { size ->
    val d = density.density
    val box = size.width
    val r = CornerRadius(box * 0.32f)
    drawRoundRect(Color(0x33000000), topLeft = Offset(0f, 2 * d), size = Size(box, box), cornerRadius = r)
    drawRoundRect(Color.White, size = Size(box, box), cornerRadius = r)
    drawRoundRect(ring.copy(alpha = 0.35f), topLeft = Offset(1f * d, 1f * d), size = Size(box - 2 * d, box - 2 * d), cornerRadius = r)
    val b = 2.5f * d
    drawRoundRect(bg, topLeft = Offset(b, b), size = Size(box - 2 * b, box - 2 * b), cornerRadius = CornerRadius(box * 0.27f))
    // little pointer under the pebble
    val path = androidx.compose.ui.graphics.Path().apply {
        moveTo(box / 2 - 5 * d, box - 1); lineTo(box / 2 + 5 * d, box - 1); lineTo(box / 2, size.height); close()
    }
    drawPath(path, Color.White)
    val pad = box * 0.18f
    translate(pad, pad) {
        with(icon) { draw(Size(box - 2 * pad, box - 2 * pad)) }
    }
}

private fun puck(icon: Painter, brand: Color, density: Density): Bitmap = render(40f, 40f, density) { size ->
    val d = density.density
    val c = Offset(size.width / 2, size.height / 2)
    drawCircle(Color(0x2A0B8F6A), radius = size.width / 2, center = c)
    drawCircle(Color.White, radius = 14 * d, center = c)
    drawCircle(brand, radius = 11.5f * d, center = c)
    val s = 16 * d
    translate(c.x - s / 2, c.y - s / 2) {
        with(icon) { draw(Size(s, s), colorFilter = ColorFilter.tint(Color.White)) }
    }
}

private fun pin(icon: Painter, color: Color, density: Density, dp: Float): Bitmap = render(dp, dp, density) { size ->
    val d = density.density
    // white halo behind the glyph
    drawCircle(Color.White, radius = size.width * 0.27f, center = Offset(size.width / 2, size.height * 0.38f))
    with(icon) { draw(size, colorFilter = ColorFilter.tint(color)) }
}
