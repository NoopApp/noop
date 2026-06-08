package com.noop.ui

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.PermissionController
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoGraph
import androidx.compose.material.icons.filled.Bluetooth
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.FileUpload
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.Sensors
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.ble.WhoopModel
import com.noop.data.ImportSummary
import com.noop.ingest.AppleHealthImporter
import com.noop.ingest.HealthConnectImporter
import com.noop.ingest.WhoopCsvImporter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.roundToInt

// MARK: - OnboardingScreen
//
// Android's first-run flow mirrors the macOS OnboardingWizard shape: a paged,
// full-screen sequence that sets expectations, scans/connects to the strap, captures
// the profile values that power zones/calories, imports history, and then hands off to
// the app shell. It uses the same AppViewModel/Repository/BLE client as the app itself.

@Composable
fun OnboardingScreen(viewModel: AppViewModel, onFinished: () -> Unit) {
    val pages = remember { OnboardingPage.entries }
    var pageIndex by remember { mutableIntStateOf(0) }
    val page = pages[pageIndex]

    Surface(
        modifier = Modifier.fillMaxSize(),
        color = Palette.surfaceBase,
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 24.dp)
                .padding(top = 42.dp, bottom = 30.dp),
        ) {
            OnboardingTopBar(
                page = pageIndex + 1,
                total = pages.size,
                progress = (pageIndex + 1).toFloat() / pages.size.toFloat(),
            )

            Column(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(top = 44.dp, bottom = 18.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                when (page) {
                    OnboardingPage.Welcome -> WelcomeStep()
                    OnboardingPage.WhatItDoes -> WhatItDoesStep()
                    OnboardingPage.Expectations -> ExpectationsStep()
                    OnboardingPage.Bluetooth -> BluetoothStep()
                    OnboardingPage.Wear -> WearStep()
                    OnboardingPage.Connect -> ConnectStep(viewModel)
                    OnboardingPage.Profile -> ProfileStep()
                    OnboardingPage.Import -> ImportStep(viewModel)
                    OnboardingPage.Done -> DoneStep()
                }
            }

            OnboardingFooter(
                canGoBack = pageIndex > 0,
                cta = page.cta,
                onBack = { if (pageIndex > 0) pageIndex-- },
                onNext = {
                    if (pageIndex == pages.lastIndex) {
                        onFinished()
                    } else {
                        pageIndex++
                    }
                },
            )
        }
    }
}

private enum class OnboardingPage(val cta: String) {
    Welcome("Begin"),
    WhatItDoes("Continue"),
    Expectations("Continue"),
    Bluetooth("Continue"),
    Wear("Continue"),
    Connect("Continue"),
    Profile("Save & continue"),
    Import("Continue"),
    Done("Enter NOOP"),
}

// MARK: - Shell

@Composable
private fun OnboardingTopBar(page: Int, total: Int, progress: Float) {
    val animated by animateFloatAsState(
        targetValue = progress.coerceIn(0f, 1f),
        animationSpec = tween(Motion.durationStandard),
        label = "onboardingProgress",
    )

    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Overline("NOOP", color = Palette.accent)
            Spacer(Modifier.weight(1f))
            Text("$page / $total", style = NoopType.captionNumber, color = Palette.textTertiary)
        }
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(3.dp)
                .clip(RoundedCornerShape(50))
                .background(Palette.hairline),
        ) {
            Box(
                modifier = Modifier
                    .fillMaxWidth(animated)
                    .height(3.dp)
                    .clip(RoundedCornerShape(50))
                    .background(Palette.accent),
            )
        }
    }
}

@Composable
private fun OnboardingFooter(
    canGoBack: Boolean,
    cta: String,
    onBack: () -> Unit,
    onNext: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        OutlinedButton(
            onClick = onBack,
            enabled = canGoBack,
            colors = ButtonDefaults.outlinedButtonColors(
                contentColor = Palette.textPrimary,
                disabledContentColor = Palette.textTertiary,
            ),
            modifier = Modifier.weight(0.9f),
        ) {
            Text("Back", style = NoopType.subhead)
        }
        Button(
            onClick = onNext,
            colors = ButtonDefaults.buttonColors(
                containerColor = Palette.accent,
                contentColor = Palette.surfaceBase,
            ),
            modifier = Modifier.weight(1.4f),
        ) {
            Text(cta, style = NoopType.headline)
        }
    }
}

@Composable
private fun StepShell(
    title: String? = null,
    subtitle: String? = null,
    content: @Composable () -> Unit,
) {
    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        if (title != null || subtitle != null) {
            Column(
                modifier = Modifier.fillMaxWidth(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                title?.let {
                    Text(
                        it,
                        style = NoopType.title1,
                        color = Palette.textPrimary,
                        textAlign = TextAlign.Center,
                    )
                }
                subtitle?.let {
                    Text(
                        it,
                        style = NoopType.body,
                        color = Palette.textSecondary,
                        textAlign = TextAlign.Center,
                    )
                }
            }
        }
        content()
    }
}

// MARK: - Steps

@Composable
private fun WelcomeStep() {
    StepShell {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 430.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Box(contentAlignment = Alignment.Center) {
                Box(
                    modifier = Modifier
                        .size(150.dp)
                        .clip(CircleShape)
                        .border(1.dp, Palette.accent.copy(alpha = 0.24f), CircleShape),
                )
                Text("NOOP", style = NoopType.display(62f), color = Palette.textPrimary)
            }
            Spacer(Modifier.height(18.dp))
            Text(
                "all your data, none of the cloud",
                style = NoopType.title2,
                color = Palette.textSecondary,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(12.dp))
            Text(
                "A private window into your recovery, sleep and strain — read straight from your strap, kept only on this phone.",
                style = NoopType.body,
                color = Palette.textTertiary,
                textAlign = TextAlign.Center,
            )
        }
    }
}

@Composable
private fun WhatItDoesStep() {
    StepShell(
        title = "What NOOP does",
        subtitle = "Three quiet promises.",
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            FeatureRow(
                icon = Icons.Filled.AutoGraph,
                tint = Palette.recovery100,
                title = "See recovery, clearly",
                body = "A calm ring rolls HRV, resting heart rate and sleep into one read on whether to push or rest.",
            )
            FeatureRow(
                icon = Icons.Filled.MonitorHeart,
                tint = Palette.accent,
                title = "Watch your heart, live",
                body = "Connect your strap and watch each beat in real time, with zones that match your profile.",
            )
            FeatureRow(
                icon = Icons.Filled.Lock,
                tint = Palette.statusPositive,
                title = "Own your data, offline",
                body = "Everything lives on this phone. No account, no sync, no cloud.",
            )
        }
    }
}

@Composable
private fun ExpectationsStep() {
    StepShell(
        title = "What to expect",
        subtitle = "A few honest words, so nothing is a surprise.",
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            AppChangelog.expectations.forEach { e ->
                ExpectationCard(e)
            }
        }
    }
}

@Composable
private fun BluetoothStep() {
    StepShell(
        title = "A quick word before you connect",
        subtitle = "Android will ask for Bluetooth permission so NOOP can find your strap.",
    ) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            IconBadge(icon = Icons.Filled.Bluetooth, tint = Palette.accent, size = 86)
            InfoCard(
                icon = Icons.Filled.Lock,
                tint = Palette.statusPositive,
                title = "Nothing leaves your phone",
                message = "NOOP talks to your strap directly over Bluetooth Low Energy. There is no server in the middle — the connection is local, and so is every reading it pulls in.",
            )
            Checkline("When Android asks, allow Bluetooth so NOOP can scan and connect.")
            Checkline("WHOOP 5.0/MG may need pairing mode the first time, with the official WHOOP app closed.")
        }
    }
}

@Composable
private fun WearStep() {
    StepShell(
        title = "Put your strap on",
        subtitle = "The sensor needs skin contact before data starts to mean anything.",
    ) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            IconBadge(icon = Icons.Filled.Sensors, tint = Palette.recovery078, size = 86)
            NoopCard(padding = 18.dp) {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Checkline("Wear it snug on your wrist or bicep, sensor against skin.")
                    Checkline("Give it a few minutes of charge if the battery is low.")
                    Checkline("Keep it near this phone while pairing and during the first sync.")
                }
            }
        }
    }
}

@Composable
private fun ConnectStep(viewModel: AppViewModel) {
    val context = LocalContext.current
    val live by viewModel.live.collectAsStateWithLifecycle()
    val selectedModel by viewModel.selectedModel.collectAsStateWithLifecycle()

    val blePerms = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
    } else {
        arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
    }
    val blePermLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { viewModel.connect() }
    var autoConnectStarted by remember { mutableStateOf(false) }

    fun requestConnect() {
        val granted = blePerms.all {
            ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
        }
        if (granted) viewModel.connect() else blePermLauncher.launch(blePerms)
    }

    LaunchedEffect(Unit) {
        if (!autoConnectStarted && !live.bonded && !live.connected && !live.scanning) {
            autoConnectStarted = true
            requestConnect()
        }
    }

    StepShell(
        title = "Find your strap",
        subtitle = if (live.bonded) "Bonded. You can keep going." else "NOOP starts looking as soon as this step appears. You can keep going while it bonds.",
    ) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            IconBadge(
                icon = if (live.bonded) Icons.Filled.CheckCircle else Icons.Filled.Bluetooth,
                tint = if (live.bonded) Palette.statusPositive else Palette.accent,
                size = 92,
            )

            val (label, tone, pulsing) = when {
                live.bonded -> Triple("Bonded · streaming", StrandTone.Positive, true)
                live.connected -> Triple("Connected · pairing", StrandTone.Warning, true)
                live.scanning -> Triple("Searching", StrandTone.Accent, true)
                else -> Triple("Ready to scan", StrandTone.Neutral, false)
            }
            StatePill(label, tone = tone, pulsing = pulsing, showsDot = true)

            live.statusNote?.let {
                Text(
                    it,
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
                    textAlign = TextAlign.Center,
                )
            }

            if (!live.bonded) {
                NoopCard(padding = 16.dp) {
                    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            Text("Strap", style = NoopType.footnote, color = Palette.textSecondary)
                            SegmentedPillControl(
                                items = WhoopModel.entries.toList(),
                                selection = selectedModel,
                                label = { it.displayName },
                                onSelect = {
                                    viewModel.setSelectedModel(it)
                                    if (!live.bonded) {
                                        viewModel.disconnect()
                                        requestConnect()
                                    }
                                },
                                modifier = Modifier.weight(1f),
                            )
                        }

                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                            Button(
                                onClick = { requestConnect() },
                                colors = ButtonDefaults.buttonColors(
                                    containerColor = Palette.accent,
                                    contentColor = Palette.surfaceBase,
                                ),
                                modifier = Modifier.weight(1f),
                            ) {
                                Icon(Icons.Filled.Bluetooth, contentDescription = null, modifier = Modifier.size(18.dp))
                                Spacer(Modifier.width(6.dp))
                                Text(if (live.connected || live.scanning) "Re-scan" else "Scan again", style = NoopType.body)
                            }
                            OutlinedButton(
                                onClick = { viewModel.disconnect() },
                                enabled = live.connected || live.scanning,
                                colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.statusCritical),
                                modifier = Modifier.weight(1f),
                            ) {
                                Text("Stop", style = NoopType.body)
                            }
                        }
                    }
                }
            }

            InfoCard(
                icon = Icons.Filled.Lock,
                tint = Palette.statusPositive,
                title = "This can run while you finish setup",
                message = "If the strap is nearby, NOOP will keep the BLE link alive in the background. You can continue through profile and import while it bonds.",
            )
        }
    }
}

@Composable
private fun ProfileStep() {
    val context = LocalContext.current
    val profile = remember { ProfileStore.from(context.applicationContext) }
    var rev by remember { mutableIntStateOf(0) }
    fun mutate(block: () -> Unit) {
        block()
        rev++
    }
    @Suppress("UNUSED_VARIABLE") val tick = rev

    StepShell(
        title = "About you",
        subtitle = "So your zones, calories and on-device scoring start from the right numbers.",
    ) {
        NoopCard(padding = 18.dp) {
            Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                ProfileStepperRow(
                    label = "Age",
                    value = "${profile.age}",
                    unit = "yrs",
                    accessibility = "Age, ${profile.age} years",
                    onMinus = { mutate { profile.age -= 1 } },
                    onPlus = { mutate { profile.age += 1 } },
                )
                ThinDivider()
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Overline("Sex", color = Palette.textTertiary)
                    SegmentedPillControl(
                        items = ONBOARDING_SEX_OPTIONS,
                        selection = ONBOARDING_SEX_OPTIONS.firstOrNull { it.tag == profile.sex }
                            ?: ONBOARDING_SEX_OPTIONS[0],
                        label = { it.label },
                        onSelect = { mutate { profile.sex = it.tag } },
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                ThinDivider()
                ProfileSliderRow(
                    label = "Weight",
                    value = profile.weightKg,
                    display = "%.1f kg".format(profile.weightKg),
                    valueRange = 30f..250f,
                    onValueChange = { v ->
                        mutate { profile.weightKg = (v * 2f).roundToInt().toDouble() / 2.0 }
                    },
                )
                ThinDivider()
                ProfileSliderRow(
                    label = "Height",
                    value = profile.heightCm,
                    display = "${profile.heightCm.roundToInt()} cm",
                    valueRange = 120f..230f,
                    onValueChange = { v ->
                        mutate { profile.heightCm = v.roundToInt().toDouble() }
                    },
                )
            }
        }

        Row(
            modifier = Modifier.semantics { contentDescription = "Estimated max heart rate ${profile.hrMax} bpm" },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(Icons.Filled.FavoriteBorder, contentDescription = null, tint = Palette.accent, modifier = Modifier.size(17.dp))
            Text(
                "Estimated max heart rate · ${profile.hrMax} bpm",
                style = NoopType.footnote,
                color = Palette.textTertiary,
            )
        }
    }
}

@Composable
private fun ImportStep(viewModel: AppViewModel) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }
    var status by remember { mutableStateOf<String?>(null) }

    fun runImport(block: suspend () -> ImportSummary) {
        busy = true
        status = "Importing…"
        scope.launch {
            val summary = withContext(Dispatchers.IO) {
                runCatching { block() }.getOrElse { ImportSummary.failure("Import", it.message ?: "failed") }
            }
            busy = false
            status = summary.message
            Toast.makeText(context, summary.message, Toast.LENGTH_LONG).show()
        }
    }

    val whoopImportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri -> if (uri != null) runImport { WhoopCsvImporter.importZip(context, uri, viewModel.repo) } }

    val appleImportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri -> if (uri != null) runImport { AppleHealthImporter.importExport(context, uri, viewModel.repo) } }

    val hcPermissionLauncher = rememberLauncherForActivityResult(
        PermissionController.createRequestPermissionResultContract(),
    ) { granted ->
        if (granted.containsAll(HealthConnectImporter.PERMISSIONS)) {
            runImport { HealthConnectImporter.import(context, viewModel.repo) }
        } else {
            val message = "Health Connect access not granted."
            status = message
            Toast.makeText(context, message, Toast.LENGTH_LONG).show()
        }
    }

    val healthConnectAvailable = remember {
        HealthConnectImporter.sdkStatus(context) == HealthConnectClient.SDK_AVAILABLE
    }

    fun startHealthConnect() {
        scope.launch {
            val granted = runCatching {
                HealthConnectImporter.client(context).permissionController.getGrantedPermissions()
            }.getOrDefault(emptySet())
            if (granted.containsAll(HealthConnectImporter.PERMISSIONS)) {
                runImport { HealthConnectImporter.import(context, viewModel.repo) }
            } else {
                hcPermissionLauncher.launch(HealthConnectImporter.PERMISSIONS)
            }
        }
    }

    StepShell(
        title = "Bring your history",
        subtitle = "Optional — import now, or skip and return to Data Sources later.",
    ) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            IconBadge(icon = Icons.Filled.Storage, tint = Palette.accent, size = 82)
            InfoCard(
                icon = Icons.Filled.AutoGraph,
                tint = Palette.accent,
                title = "History fills the dashboard immediately",
                message = "A WHOOP export backfills recovery, strain, sleep and workouts. Health Connect can add steps, HR, HRV, sleep and weight from Android sources.",
            )

            NoopCard(padding = 16.dp) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    OnboardingActionButton(
                        label = "Import WHOOP export (.zip)",
                        icon = Icons.Filled.FileUpload,
                        enabled = !busy,
                    ) { whoopImportLauncher.launch(arrayOf("*/*")) }
                    OnboardingActionButton(
                        label = "Import from Health Connect",
                        icon = Icons.Filled.MonitorHeart,
                        enabled = !busy && healthConnectAvailable,
                    ) { startHealthConnect() }
                    OnboardingActionButton(
                        label = "Import Apple Health export",
                        icon = Icons.Filled.FavoriteBorder,
                        enabled = !busy,
                    ) { appleImportLauncher.launch(arrayOf("*/*")) }
                }
            }

            if (!healthConnectAvailable) {
                Text(
                    "Health Connect is not available on this device.",
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                    textAlign = TextAlign.Center,
                )
            }
            status?.let {
                Text(
                    it,
                    style = NoopType.footnote,
                    color = if (busy) Palette.accent else Palette.textSecondary,
                    textAlign = TextAlign.Center,
                )
            }
        }
    }
}

@Composable
private fun DoneStep() {
    StepShell {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 430.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            IconBadge(icon = Icons.Filled.CheckCircle, tint = Palette.statusPositive, size = 100)
            Spacer(Modifier.height(22.dp))
            Text(
                "Your thread starts here.",
                style = NoopType.title1,
                color = Palette.textPrimary,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(10.dp))
            Text(
                "Every beat, every night, every day — woven into one quiet picture of you. Welcome to NOOP.",
                style = NoopType.body,
                color = Palette.textSecondary,
                textAlign = TextAlign.Center,
            )
        }
    }
}

// MARK: - Pieces

@Composable
private fun FeatureRow(icon: ImageVector, tint: Color, title: String, body: String) {
    NoopCard(padding = 16.dp) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(14.dp),
            verticalAlignment = Alignment.Top,
        ) {
            IconSquare(icon = icon, tint = tint)
            Column(verticalArrangement = Arrangement.spacedBy(5.dp), modifier = Modifier.weight(1f)) {
                Text(title, style = NoopType.headline, color = Palette.textPrimary)
                Text(body, style = NoopType.subhead, color = Palette.textSecondary)
            }
        }
    }
}

@Composable
private fun ExpectationCard(e: AppChangelog.Expectation) {
    NoopCard(padding = 14.dp) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(14.dp),
            verticalAlignment = Alignment.Top,
        ) {
            Icon(e.icon, contentDescription = null, tint = Palette.accent, modifier = Modifier.size(22.dp))
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(e.title, style = NoopType.headline, color = Palette.textPrimary)
                Text(e.body, style = NoopType.subhead, color = Palette.textSecondary)
            }
        }
    }
}

@Composable
private fun InfoCard(icon: ImageVector, tint: Color, title: String, message: String) {
    NoopCard(padding = 16.dp) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(14.dp),
            verticalAlignment = Alignment.Top,
        ) {
            IconSquare(icon = icon, tint = tint)
            Column(verticalArrangement = Arrangement.spacedBy(5.dp), modifier = Modifier.weight(1f)) {
                Text(title, style = NoopType.headline, color = Palette.textPrimary)
                Text(message, style = NoopType.subhead, color = Palette.textSecondary)
            }
        }
    }
}

@Composable
private fun OnboardingActionButton(
    label: String,
    icon: ImageVector,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    Button(
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier.fillMaxWidth(),
        colors = ButtonDefaults.buttonColors(
            containerColor = Palette.accent,
            contentColor = Palette.surfaceBase,
            disabledContainerColor = Palette.surfaceInset,
            disabledContentColor = Palette.textTertiary,
        ),
    ) {
        Icon(icon, contentDescription = null, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(8.dp))
        Text(label, style = NoopType.body)
    }
}

@Composable
private fun Checkline(text: String) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(Icons.Filled.Check, contentDescription = null, tint = Palette.statusPositive, modifier = Modifier.size(17.dp))
        Text(text, style = NoopType.subhead, color = Palette.textSecondary, modifier = Modifier.weight(1f))
    }
}

@Composable
private fun IconBadge(icon: ImageVector, tint: Color, size: Int) {
    Box(
        modifier = Modifier
            .size(size.dp)
            .clip(CircleShape)
            .background(tint.copy(alpha = 0.13f))
            .border(1.dp, tint.copy(alpha = 0.28f), CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size((size * 0.42f).dp))
    }
}

@Composable
private fun IconSquare(icon: ImageVector, tint: Color) {
    Box(
        modifier = Modifier
            .size(42.dp)
            .clip(RoundedCornerShape(11.dp))
            .background(tint.copy(alpha = 0.13f))
            .border(1.dp, tint.copy(alpha = 0.22f), RoundedCornerShape(11.dp)),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(20.dp))
    }
}

@Composable
private fun ProfileStepperRow(
    label: String,
    value: String,
    unit: String,
    accessibility: String,
    onMinus: () -> Unit,
    onPlus: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 44.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Overline(label, color = Palette.textTertiary)
            Text("$value $unit", style = NoopType.bodyNumber, color = Palette.textPrimary)
        }
        StepperButtons(accessibility = accessibility, onMinus = onMinus, onPlus = onPlus)
    }
}

@Composable
private fun StepperButtons(accessibility: String, onMinus: () -> Unit, onPlus: () -> Unit) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.semantics { contentDescription = accessibility },
    ) {
        StepperButton(symbol = "-", label = "Decrease $accessibility", onClick = onMinus)
        StepperButton(symbol = "+", label = "Increase $accessibility", onClick = onPlus)
    }
}

@Composable
private fun StepperButton(symbol: String, label: String, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .size(34.dp)
            .clip(RoundedCornerShape(9.dp))
            .background(Palette.surfaceInset)
            .border(1.dp, Palette.hairline, RoundedCornerShape(9.dp))
            .clickable(onClick = onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Text(symbol, style = NoopType.body.copy(fontWeight = FontWeight.SemiBold), color = Palette.textPrimary)
    }
}

@Composable
private fun ProfileSliderRow(
    label: String,
    value: Double,
    display: String,
    valueRange: ClosedFloatingPointRange<Float>,
    onValueChange: (Float) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Overline(label, color = Palette.textTertiary)
            Spacer(Modifier.weight(1f))
            Text(display, style = NoopType.bodyNumber, color = Palette.textPrimary, modifier = Modifier.widthIn(min = 82.dp))
        }
        Slider(
            value = value.toFloat().coerceIn(valueRange.start, valueRange.endInclusive),
            onValueChange = onValueChange,
            valueRange = valueRange,
            colors = SliderDefaults.colors(
                thumbColor = Palette.accent,
                activeTrackColor = Palette.accent,
                inactiveTrackColor = Palette.hairline,
            ),
        )
    }
}

@Composable
private fun ThinDivider() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(1.dp)
            .background(Palette.hairline),
    )
}

private data class OnboardingSexOption(val tag: String, val label: String)

private val ONBOARDING_SEX_OPTIONS = listOf(
    OnboardingSexOption("male", "Male"),
    OnboardingSexOption("female", "Female"),
    OnboardingSexOption("nonbinary", "Other"),
)
