package my.gimano.app.ui.report

import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import my.gimano.app.R
import my.gimano.app.ui.common.GIcons
import my.gimano.app.ui.common.Labels
import my.gimano.app.ui.common.ReportTile
import my.gimano.app.ui.theme.Gimano
import my.gimano.app.ui.theme.Radius
import my.gimano.app.ui.theme.ReportColors
import my.gimano.app.ui.theme.Sizes
import my.gimano.app.ui.theme.GimanoType
import androidx.compose.ui.semantics.semantics

/** "What do you see?" — 3×3 grid of report types, then one-tap subtypes. */
@Composable
fun ReportSheet(
    onDismiss: () -> Unit,
    onSubmit: (type: String, subtype: String?, comment: String?) -> Unit,
    /** Complaints v1 "Masalah jalan" group (during navigation, when the server has /issues). */
    onRoadProblem: ((type: String, durationHint: String?) -> Unit)? = null,
    /** Opened straight at this type's subtypes ("Details" after a quick report, docs/driving.md §6.4); back closes. */
    initialType: String? = null,
) {
    val c = Gimano.colors
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var type by remember { mutableStateOf(initialType) }
    var comment by remember { mutableStateOf("") }
    var road by remember { mutableStateOf<String?>(null) }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = c.surface,
        shape = RoundedCornerShape(topStart = Radius.sheet, topEnd = Radius.sheet),
    ) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 24.dp)) {
            val t = type
            val rp = road
            if (rp != null && onRoadProblem != null) {
                my.gimano.app.ui.issues.RoadProblemConfirm(rp, onBack = { road = null }) { d -> onRoadProblem(rp, d) }
            } else if (t == null) {
                Spacer(Modifier.height(4.dp))
                LazyVerticalGrid(
                    GridCells.Fixed(3), verticalArrangement = Arrangement.spacedBy(14.dp), horizontalArrangement = Arrangement.spacedBy(10.dp),
                    userScrollEnabled = false, modifier = Modifier.heightIn(max = 560.dp),
                ) {
                    items(GIcons.reportTypes) { rt ->
                        val label = stringResource(Labels.shortType(rt))
                        Column(
                            Modifier.clip(RoundedCornerShape(Radius.md)).semantics(mergeDescendants = true) {}.clickable(onClickLabel = label) {
                                if (Labels.subtypes[rt] == null && rt != "closure" && rt != "map_issue") onSubmit(rt, null, null) else type = rt
                            }.padding(vertical = 4.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                        ) {
                            ReportTile(rt, Sizes.reportTile, iconSize = Sizes.reportTileIcon, radius = Radius.reportTile)
                            Text(label, style = GimanoType.label.copy(fontSize = 15.sp), color = c.text, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 6.dp), maxLines = 1)
                        }
                    }
                }
                if (onRoadProblem != null) my.gimano.app.ui.issues.RoadProblemGroup { road = it }
            } else {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(bottom = 12.dp)) {
                    IconButton(onClick = { if (initialType != null) onDismiss() else type = null }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.back), tint = c.text) }
                    ReportTile(t, 48.dp)
                    Spacer(Modifier.width(12.dp))
                    Text(stringResource(Labels.reportType(t)), fontSize = 22.sp, fontWeight = FontWeight.SemiBold, color = c.text)
                }
                val subs = Labels.subtypes[t].orEmpty()
                if (subs.isNotEmpty()) {
                    LazyVerticalGrid(
                        GridCells.Fixed(2), verticalArrangement = Arrangement.spacedBy(10.dp), horizontalArrangement = Arrangement.spacedBy(10.dp),
                        modifier = Modifier.heightIn(max = 420.dp),
                    ) {
                        items(subs) { (sub, label) ->
                            Button(
                                onClick = { onSubmit(t, sub, null) },
                                modifier = Modifier.fillMaxWidth().height(64.dp),
                                shape = RoundedCornerShape(Radius.md),
                                colors = ButtonDefaults.buttonColors(containerColor = ReportColors.duotone(t).tile, contentColor = ReportColors.duotone(t).stroke),
                            ) { Text(stringResource(label), fontSize = 16.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center) }
                        }
                    }
                    Spacer(Modifier.height(12.dp))
                } else {
                    OutlinedTextField(
                        comment, { comment = it }, Modifier.fillMaxWidth(),
                        placeholder = { Text(stringResource(R.string.comment_hint)) }, minLines = 2, maxLines = 4,
                        shape = RoundedCornerShape(Radius.md),
                    )
                    Spacer(Modifier.height(12.dp))
                }
                Button(
                    onClick = { onSubmit(t, null, comment) },
                    modifier = Modifier.fillMaxWidth().height(56.dp), shape = RoundedCornerShape(Radius.md),
                    colors = ButtonDefaults.buttonColors(containerColor = c.report, contentColor = c.reportOn),
                ) { Text(stringResource(R.string.send), fontSize = 17.sp, fontWeight = FontWeight.SemiBold) }
            }
        }
    }
}
