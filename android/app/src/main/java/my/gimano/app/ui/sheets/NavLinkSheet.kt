package my.gimano.app.ui.sheets

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Place
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import my.gimano.app.R
import my.gimano.app.core.links.NavLink
import my.gimano.app.ui.theme.Gimano

/**
 * "Route to this spot?" for a navigate link sent by another app. Any app can send one, so nothing starts until Confirm.
 * The label and coordinates are shown as plain text only.
 */
@Composable
fun NavLinkSheet(link: NavLink, onConfirm: () -> Unit, onCancel: () -> Unit) {
    val c = Gimano.colors
    fun fmt(v: Double) = java.math.BigDecimal(v).setScale(6, java.math.RoundingMode.HALF_UP).stripTrailingZeros().toPlainString()
    val coords = fmt(link.lat) + ", " + fmt(link.lng)
    ModalBottomSheet(
        onDismissRequest = onCancel,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = c.surface,
    ) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(bottom = 24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(Icons.Filled.Place, contentDescription = null, tint = c.brand, modifier = Modifier.size(72.dp))
            Spacer(Modifier.height(8.dp))
            Text(stringResource(R.string.nav_link_title), fontSize = 22.sp, fontWeight = FontWeight.ExtraBold, color = c.text, textAlign = TextAlign.Center)
            link.label?.let {
                Spacer(Modifier.height(8.dp))
                Text(it, fontSize = 18.sp, fontWeight = FontWeight.Bold, color = c.text, textAlign = TextAlign.Center)
            }
            Spacer(Modifier.height(4.dp))
            Text(coords, fontSize = 14.sp, color = c.textMuted, textAlign = TextAlign.Center)
            Spacer(Modifier.height(20.dp))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedButton(onClick = onCancel, modifier = Modifier.weight(1f).height(56.dp)) {
                    Text(stringResource(R.string.nav_link_cancel), fontWeight = FontWeight.ExtraBold)
                }
                Button(onClick = onConfirm, modifier = Modifier.weight(1f).height(56.dp)) {
                    Text(stringResource(R.string.nav_link_confirm), fontWeight = FontWeight.ExtraBold)
                }
            }
        }
    }
}
