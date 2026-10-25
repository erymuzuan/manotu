package my.gimano.app.core.car

import androidx.car.app.navigation.model.Maneuver

/**
 * Our maneuver types (docs/api.md) → Car App Library maneuver types. Malaysia drives on the left, so roundabouts turn
 * clockwise. Types that would need extra data the route doesn't carry (roundabout exit numbers) are avoided.
 */
object CarManeuvers {
    fun type(t: String): Int = when (t) {
        "depart" -> Maneuver.TYPE_DEPART
        "arrive" -> Maneuver.TYPE_DESTINATION
        "straight" -> Maneuver.TYPE_STRAIGHT
        "slight_left" -> Maneuver.TYPE_TURN_SLIGHT_LEFT
        "left" -> Maneuver.TYPE_TURN_NORMAL_LEFT
        "sharp_left" -> Maneuver.TYPE_TURN_SHARP_LEFT
        "slight_right" -> Maneuver.TYPE_TURN_SLIGHT_RIGHT
        "right" -> Maneuver.TYPE_TURN_NORMAL_RIGHT
        "sharp_right" -> Maneuver.TYPE_TURN_SHARP_RIGHT
        "uturn_left" -> Maneuver.TYPE_U_TURN_LEFT
        "uturn_right" -> Maneuver.TYPE_U_TURN_RIGHT
        "roundabout_enter" -> Maneuver.TYPE_ROUNDABOUT_ENTER_CW
        "roundabout_exit" -> Maneuver.TYPE_ROUNDABOUT_EXIT_CW
        "merge" -> Maneuver.TYPE_MERGE_SIDE_UNSPECIFIED
        "ramp_left" -> Maneuver.TYPE_ON_RAMP_NORMAL_LEFT
        "ramp_right" -> Maneuver.TYPE_ON_RAMP_NORMAL_RIGHT
        "exit_left" -> Maneuver.TYPE_OFF_RAMP_NORMAL_LEFT
        "exit_right" -> Maneuver.TYPE_OFF_RAMP_NORMAL_RIGHT
        "keep_left" -> Maneuver.TYPE_KEEP_LEFT
        "keep_right" -> Maneuver.TYPE_KEEP_RIGHT
        "ferry" -> Maneuver.TYPE_FERRY_BOAT
        else -> Maneuver.TYPE_STRAIGHT
    }
}
