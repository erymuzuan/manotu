package my.gimano.app.ui.update

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.SystemUpdate
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import my.gimano.app.R
import my.gimano.app.core.update.StoreUpdateDecision
import my.gimano.app.ui.theme.Gimano

private tailrec fun android.content.Context.findActivity(): android.app.Activity? = when (this) {
    is android.app.Activity -> this
    is android.content.ContextWrapper -> baseContext.findActivity()
    else -> null
}

/**
 * Google Play build: full-screen "New version" card. Soft = Update + small Later (Back = Later). Forced = Update only,
 * Back leaves the app. Only the caller decides when it may show (never during navigation).
 */
@Composable
fun StoreUpdateCard(d: StoreUpdateDecision, onUpdate: () -> Unit, onLater: () -> Unit) {
    val c = Gimano.colors
    val activity = LocalContext.current.findActivity()
    val (current, latest, forced) = when (d) {
        is StoreUpdateDecision.Soft -> Triple(d.current, d.latest, false)
        is StoreUpdateDecision.Forced -> Triple(d.current, d.latest, true)
        StoreUpdateDecision.None -> return
    }
    BackHandler { if (forced) activity?.finish() else onLater() }
    Box(
        Modifier.fillMaxSize().background(c.background).windowInsetsPadding(WindowInsets.systemBars)
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {},   // swallow touches
        contentAlignment = Alignment.Center,
    ) {
        Column(Modifier.padding(28.dp), verticalArrangement = Arrangement.spacedBy(18.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Box(Modifier.size(120.dp).clip(RoundedCornerShape(34.dp)).background(c.brandMist), contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.SystemUpdate, null, tint = c.brandInk, modifier = Modifier.size(68.dp))
            }
            Text(stringResource(if (forced) R.string.store_update_required else R.string.store_update_new), fontSize = 28.sp, fontWeight = FontWeight.Black, color = c.text)
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(current, fontSize = 18.sp, fontWeight = FontWeight.ExtraBold, color = c.textMuted)
                Icon(Icons.AutoMirrored.Filled.ArrowForward, null, tint = c.textMuted)
                Text(latest, fontSize = 22.sp, fontWeight = FontWeight.Black, color = c.brand)
            }
            if (forced) Text(stringResource(R.string.store_update_forced_body), fontSize = 15.sp, fontWeight = FontWeight.Bold, color = c.textMuted)
            Spacer(Modifier.height(6.dp))
            Button(onClick = onUpdate, modifier = Modifier.fillMaxWidth().height(64.dp), shape = RoundedCornerShape(20.dp),
                colors = ButtonDefaults.buttonColors(containerColor = c.brand, contentColor = c.brandOn)) {
                Text(stringResource(R.string.update_now), fontSize = 19.sp, fontWeight = FontWeight.Black)
            }
            if (!forced) TextButton(onClick = onLater) {
                Text(stringResource(R.string.update_later), fontSize = 15.sp, fontWeight = FontWeight.ExtraBold, color = c.textMuted)
            }
        }
    }
}
