package my.gimano.app.update

import my.gimano.app.BuildConfig
import my.gimano.app.core.update.UpdateDecision
import my.gimano.app.core.update.UpdateManifest
import my.gimano.app.core.update.UpdatePolicy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Runs only for the Google Play build type (testManotuPlayUnitTest): the app must have no self-updater. */
class PlayVariantTest {
    @Test fun playBuildHasNoSelfUpdater() {
        assertEquals("play", BuildConfig.DISTRIBUTION)
        assertFalse(BuildConfig.SELF_UPDATE)
        assertEquals("my.manotu.app", BuildConfig.APPLICATION_ID)
        val m = UpdateManifest.parse("""{"versionCode":99,"apkUrl":"https://manotu.app/download/x.apk",
            "sha256":"51f9ae66d2866390a23406696589d1619e01624e4c6bae14151b5d70a702721b","minSupported":99}""")!!
        assertEquals(UpdateDecision.UpToDate, UpdatePolicy.decide(BuildConfig.VERSION_CODE, m, 0, 0, BuildConfig.SELF_UPDATE))
        assertFalse(UpdatePolicy.shouldCheck(0, Long.MAX_VALUE, force = true, selfUpdate = BuildConfig.SELF_UPDATE))
    }

    @Test fun playBuildChecksTheStoreVersion() {
        assertTrue(my.gimano.app.core.update.StoreUpdatePolicy.enabled(BuildConfig.DISTRIBUTION, BuildConfig.DEBUG, false))
    }
}
