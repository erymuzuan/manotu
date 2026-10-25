package my.gimano.app.data.location

import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.os.Looper
import androidx.core.content.ContextCompat
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.tasks.await
import my.gimano.app.core.geo.GeoPoint
import my.gimano.app.core.nav.RouteGeometry

/** A position fix, independent of android.location for testability. */
data class Fix(
    val point: GeoPoint,
    val speedMps: Float? = null,
    val bearing: Float? = null,
    val accuracyM: Float? = null,
    val timeMs: Long = System.currentTimeMillis(),
    val simulated: Boolean = false,
)

fun Location.toFix() = Fix(
    GeoPoint(latitude, longitude),
    if (hasSpeed()) speed else null,
    if (hasBearing()) bearing else null,
    if (hasAccuracy()) accuracy else null,
    time,
)

class FusedLocationSource(private val context: Context) {
    private val client = LocationServices.getFusedLocationProviderClient(context)

    fun hasFine() = ContextCompat.checkSelfPermission(context, android.Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
    fun precision() = my.gimano.app.core.location.LocationPrecision.of(hasFine(),
        ContextCompat.checkSelfPermission(context, android.Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED)

    private val playServices: Boolean by lazy {
        runCatching { com.google.android.gms.common.GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(context) == com.google.android.gms.common.ConnectionResult.SUCCESS }
            .getOrDefault(false)
    }

    fun hasPermission() = ContextCompat.checkSelfPermission(context, android.Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
        ContextCompat.checkSelfPermission(context, android.Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED

    @SuppressLint("MissingPermission")
    suspend fun lastKnown(): Fix? = if (!hasPermission()) null else if (!playServices) runCatching {
        context.getSystemService(android.location.LocationManager::class.java).getLastKnownLocation(android.location.LocationManager.GPS_PROVIDER)?.toFix()
    }.getOrNull() else runCatching { client.lastLocation.await()?.toFix() }.getOrNull()

    @SuppressLint("MissingPermission")
    fun updates(intervalMs: Long = 1_000): Flow<Fix> = callbackFlow {
        if (!hasPermission()) {
            close(); return@callbackFlow
        }
        if (!playServices) {
            // No Google Play services (e.g. de-Googled phones): GNSS straight from LocationManager.
            val lm = context.getSystemService(android.location.LocationManager::class.java)
            val provider = if (hasFine()) android.location.LocationManager.GPS_PROVIDER else android.location.LocationManager.NETWORK_PROVIDER
            val l = android.location.LocationListener { loc -> trySend(loc.toFix()) }
            runCatching { lm.requestLocationUpdates(provider, intervalMs, 0f, l, Looper.getMainLooper()) }
            awaitClose { lm.removeUpdates(l) }
            return@callbackFlow
        }
        val req = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, intervalMs)
            .setMinUpdateIntervalMillis(intervalMs / 2)
            .build()
        val cb = object : LocationCallback() {
            override fun onLocationResult(r: LocationResult) {
                r.lastLocation?.let { trySend(it.toFix()) }
            }
        }
        client.requestLocationUpdates(req, cb, Looper.getMainLooper())
        awaitClose { client.removeLocationUpdates(cb) }
    }
}

/**
 * Drives along a route geometry, emitting a fix per second. Used in demo mode (and with the
 * "Simulate drive" setting) so navigation can be shown without moving.
 */
object DriveSimulator {
    /**
     * @param holdAtM along-route distances where the simulated driver stops (multi-stop trips);
     *   [awaitResume] suspends until the driver taps Continue for that stop.
     */
    fun drive(
        geometry: RouteGeometry, speedKmh: Double, startAlongM: Double = 0.0, tickMs: Long = 1_000,
        holdAtM: List<Double> = emptyList(), awaitResume: suspend (Int) -> Unit = {},
        /** Debug replay: speed (km/h) at an along-route distance, instead of the constant [speedKmh]. */
        speedAt: ((Double) -> Double)? = null,
    ): Flow<Fix> = flow {
        var along = startAlongM
        val mps = speedKmh / 3.6
        var nextHold = holdAtM.indexOfFirst { it > along }.let { if (it < 0) holdAtM.size else it }
        while (along <= geometry.lengthM) {
            if (nextHold < holdAtM.size && along >= holdAtM[nextHold]) {
                val (sp, sb) = geometry.pointAt(holdAtM[nextHold])
                emit(Fix(sp, 0f, sb.toFloat(), 5f, System.currentTimeMillis(), simulated = true))
                awaitResume(nextHold)
                along = holdAtM[nextHold] + 1.0
                nextHold++
                continue
            }
            val (p, brg) = geometry.pointAt(along)
            // Slow down near the end for a natural arrival.
            val left = geometry.lengthM - along
            val base = speedAt?.invoke(along)?.div(3.6) ?: mps
            val v = if (left < 150) maxOf(4.0, base * left / 150) else base
            emit(Fix(p, v.toFloat(), brg.toFloat(), 5f, System.currentTimeMillis(), simulated = true))
            delay(tickMs)
            along += v * tickMs / 1000.0
        }
        val (end, brg) = geometry.pointAt(geometry.lengthM)
        emit(Fix(end, 0f, brg.toFloat(), 5f, System.currentTimeMillis(), simulated = true))
    }
}
