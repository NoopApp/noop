package com.noop.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.CompareArrows
import androidx.compose.material.icons.automirrored.filled.TrendingUp
import androidx.compose.material.icons.filled.Air
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Explore
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.FitnessCenter
import androidx.compose.material.icons.filled.HealthAndSafety
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Insights
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.Sensors
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Spa
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.Timeline
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.NavigationDrawerItem
import androidx.compose.material3.NavigationDrawerItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberDrawerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.noop.BuildConfig
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavDestination.Companion.hierarchy
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import kotlinx.coroutines.launch

// MARK: - Navigation model
//
// The macOS app's sidebar holds many sections; on Android we mirror that with a
// ModalNavigationDrawer (hamburger in the top bar) for the full grouped list, plus a
// bottom NavigationBar for the four everyday screens (Today/Trends/Live/Sleep) with a
// "More" sheet that reuses the same groups — both routes reach every destination.
// Destinations are grouped exactly as the sidebar groups them. Routes whose screens
// belong to later waves point at a ComingSoon placeholder so the app compiles today.

/** A single drawer destination: stable route, display title, sidebar icon. */
private enum class Destination(
    val route: String,
    val title: String,
    val icon: ImageVector,
) {
    // Group: Today
    Today("today", "Today", Icons.Filled.Home),
    Intelligence("intelligence", "Intelligence", Icons.Filled.Psychology),

    // Group: Live
    Live("live", "Live", Icons.Filled.FavoriteBorder),
    Intervals("intervals", "Intervals", Icons.Filled.Timeline),

    // Group: Recovery
    Sleep("sleep", "Sleep", Icons.Filled.Bedtime),
    Breathe("breathe", "Breathe", Icons.Filled.Air),
    Stress("stress", "Stress", Icons.Filled.Spa),

    // Group: Activity
    Workouts("workouts", "Workouts", Icons.Filled.FitnessCenter),
    Trends("trends", "Trends", Icons.AutoMirrored.Filled.TrendingUp),

    // Group: Insight
    Coach("coach", "Coach", Icons.Filled.AutoAwesome),
    Insights("insights", "Insights", Icons.Filled.Insights),
    Explore("explore", "Explore", Icons.Filled.Explore),
    Compare("compare", "Compare", Icons.AutoMirrored.Filled.CompareArrows),

    // Group: Health
    Health("health", "Health", Icons.Filled.MonitorHeart),
    AppleHealth("apple_health", "Apple Health", Icons.Filled.HealthAndSafety),

    // Group: System
    Automations("automations", "Automations", Icons.Filled.Bolt),
    DataSources("data_sources", "Data Sources", Icons.Filled.Storage),
    Notifications("notifications", "Notifications", Icons.Filled.Notifications),
    Support("support", "Support", Icons.Filled.Tune),
    Settings("settings", "Settings", Icons.Filled.Settings);

    companion object {
        /** Resolve the destination owning the current back-stack route (defaults to Today). */
        fun forRoute(route: String?): Destination =
            entries.firstOrNull { it.route == route } ?: Today
    }
}

/** Sidebar groups, mirroring the macOS section ordering. */
private data class DrawerGroup(val header: String, val items: List<Destination>)

private val drawerGroups: List<DrawerGroup> = listOf(
    DrawerGroup("Overview", listOf(Destination.Today, Destination.Intelligence)),
    DrawerGroup("Live", listOf(Destination.Live, Destination.Intervals)),
    DrawerGroup("Recovery", listOf(Destination.Sleep, Destination.Breathe, Destination.Stress)),
    DrawerGroup("Activity", listOf(Destination.Workouts, Destination.Trends)),
    DrawerGroup("Insight", listOf(
        Destination.Coach, Destination.Insights, Destination.Explore, Destination.Compare,
    )),
    DrawerGroup("Health", listOf(Destination.Health, Destination.AppleHealth)),
    DrawerGroup("System", listOf(
        Destination.Automations, Destination.DataSources,
        Destination.Notifications, Destination.Support, Destination.Settings,
    )),
)

/** The four everyday screens that earn a permanent bottom tab; everything else lives in More. */
private val bottomTabs = listOf(
    Destination.Today, Destination.Trends, Destination.Live, Destination.Sleep,
)

/**
 * App shell: a bottom [NavigationBar] (Today/Trends/Live/Sleep + a "More" sheet) and a
 * [ModalNavigationDrawer] (hamburger in a [TopAppBar] titled with the current screen),
 * both driving one [NavHost]. A single [AppViewModel] is created here and shared with
 * every screen, so the BLE connection and cached metrics stay app-wide singletons.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AppRoot(viewModel: AppViewModel = viewModel()) {
    val nav = rememberNavController()
    val drawerState = rememberDrawerState(DrawerValue.Closed)
    val scope = rememberCoroutineScope()

    val backStack by nav.currentBackStackEntryAsState()
    val currentRoute = backStack?.destination?.route
    val current = Destination.forRoute(currentRoute)
    var showMoreSheet by remember { mutableStateOf(false) }

    ModalNavigationDrawer(
        drawerState = drawerState,
        drawerContent = {
            ModalDrawerSheet(
                drawerContainerColor = Palette.surfaceRaised,
                drawerContentColor = Palette.textPrimary,
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .verticalScroll(rememberScrollState())
                        .padding(horizontal = 12.dp, vertical = 16.dp),
                ) {
                    Overline(
                        "Strand",
                        modifier = Modifier.padding(start = 16.dp, bottom = 4.dp),
                        color = Palette.accent,
                    )
                    Text(
                        "Instrument",
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                        modifier = Modifier.padding(start = 16.dp, bottom = 12.dp),
                    )

                    drawerGroups.forEachIndexed { index, group ->
                        if (index > 0) {
                            HorizontalDivider(
                                color = Palette.hairline,
                                modifier = Modifier.padding(vertical = 8.dp),
                            )
                        }
                        Overline(
                            group.header,
                            modifier = Modifier.padding(start = 16.dp, top = 4.dp, bottom = 6.dp),
                            color = Palette.textTertiary,
                        )
                        group.items.forEach { dest ->
                            val selected = backStack?.destination?.hierarchy
                                ?.any { it.route == dest.route } == true
                            NavigationDrawerItem(
                                selected = selected,
                                onClick = {
                                    scope.launch { drawerState.close() }
                                    if (dest.route != currentRoute) {
                                        nav.navigateTopLevel(dest.route)
                                    }
                                },
                                icon = { Icon(dest.icon, contentDescription = null) },
                                label = { Text(dest.title, style = NoopType.body) },
                                colors = NavigationDrawerItemDefaults.colors(
                                    selectedContainerColor = Palette.accentMuted,
                                    unselectedContainerColor = Palette.surfaceRaised,
                                    selectedIconColor = Palette.accent,
                                    unselectedIconColor = Palette.textSecondary,
                                    selectedTextColor = Palette.textPrimary,
                                    unselectedTextColor = Palette.textSecondary,
                                ),
                                modifier = Modifier.padding(NavigationDrawerItemDefaults.ItemPadding),
                            )
                        }
                    }
                }
            }
        },
    ) {
        Scaffold(
            containerColor = Palette.surfaceBase,
            topBar = {
                TopAppBar(
                    title = {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(current.title, style = NoopType.title2, color = Palette.textPrimary)
                            if (BuildConfig.ENABLE_DEMO) {
                                Spacer(Modifier.width(10.dp))
                                Text(
                                    "DEMO",
                                    style = NoopType.footnote,
                                    color = Palette.surfaceBase,
                                    modifier = Modifier
                                        .background(Palette.accent, RoundedCornerShape(6.dp))
                                        .padding(horizontal = 8.dp, vertical = 2.dp),
                                )
                            }
                        }
                    },
                    navigationIcon = {
                        IconButton(onClick = { scope.launch { drawerState.open() } }) {
                            Icon(
                                Icons.Filled.Menu,
                                contentDescription = "Open navigation",
                                tint = Palette.textPrimary,
                            )
                        }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(
                        containerColor = Palette.surfaceBase,
                        titleContentColor = Palette.textPrimary,
                        navigationIconContentColor = Palette.textPrimary,
                    ),
                )
            },
            bottomBar = {
                // One-thumb navigation for the four everyday screens. The drawer stays — same
                // destinations, grouped — so nothing moved for existing users; the bar is additive.
                NavigationBar(containerColor = Palette.surfaceRaised) {
                    bottomTabs.forEach { dest ->
                        NavigationBarItem(
                            selected = current == dest,
                            onClick = {
                                if (dest.route != currentRoute) nav.navigateTopLevel(dest.route)
                            },
                            icon = { Icon(dest.icon, contentDescription = dest.title) },
                            label = { Text(dest.title, style = NoopType.footnote) },
                            colors = navBarItemColors(),
                        )
                    }
                    NavigationBarItem(
                        // Lights up whenever the current screen ISN'T one of the four tabs, so the
                        // bar never looks like you're nowhere.
                        selected = bottomTabs.none { it == current },
                        onClick = { showMoreSheet = true },
                        icon = { Icon(Icons.Filled.GridView, contentDescription = "More screens") },
                        label = { Text("More", style = NoopType.footnote) },
                        colors = navBarItemColors(),
                    )
                }
            },
        ) { inner ->
            NavHost(
                navController = nav,
                startDestination = Destination.Today.route,
                modifier = Modifier.padding(inner),
            ) {
                // --- Live, working screens (existing waves) ---
                composable(Destination.Today.route) {
                    TodayScreen(
                        viewModel = viewModel,
                        onSupport = { nav.navigateTopLevel(Destination.Support.route) },
                    )
                }
                composable(Destination.Live.route) { LiveScreen(viewModel) }
                composable(Destination.Sleep.route) { SleepScreen(viewModel) }
                composable(Destination.Intervals.route) { IntervalsScreen(viewModel) }
                composable(Destination.Breathe.route) { BreatheScreen(viewModel) }
                composable(Destination.Coach.route) { CoachScreen() }
                composable(Destination.Explore.route) { TrendsExploreScreen(viewModel) }
                composable(Destination.Automations.route) { AutomationsScreen(viewModel) }
                composable(Destination.Workouts.route) { WorkoutsScreen(viewModel) }
                composable(Destination.Support.route) { SupportScreen() }
                composable(Destination.Intelligence.route) { IntelligenceScreen(viewModel) }

                // --- Placeholder routes (later waves fill these in) ---
                composable(Destination.Stress.route) { StressScreen(viewModel) }
                composable(Destination.Trends.route) { TrendsScreen(viewModel) }
                composable(Destination.Insights.route) { InsightsScreen(viewModel) }
                composable(Destination.Compare.route) { CompareScreen(viewModel) }
                composable(Destination.Health.route) { HealthScreen(viewModel) }
                composable(Destination.AppleHealth.route) { AppleHealthScreen(viewModel) }
                composable(Destination.DataSources.route) { DataSourcesScreen(viewModel) }
                composable(Destination.Notifications.route) { NotificationsSettingsScreen(viewModel) }
                composable(Destination.Settings.route) { SettingsScreen(viewModel) }
            }
        }

        // "More" — every destination, grouped exactly like the drawer, one thumb away. The drawer
        // itself stays for anyone used to the hamburger; both routes lead to the same screens.
        if (showMoreSheet) {
            ModalBottomSheet(
                onDismissRequest = { showMoreSheet = false },
                containerColor = Palette.surfaceRaised,
                contentColor = Palette.textPrimary,
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .verticalScroll(rememberScrollState())
                        .padding(horizontal = 12.dp)
                        .padding(bottom = 24.dp),
                ) {
                    drawerGroups.forEachIndexed { index, group ->
                        if (index > 0) {
                            HorizontalDivider(
                                color = Palette.hairline,
                                modifier = Modifier.padding(vertical = 8.dp),
                            )
                        }
                        Overline(
                            group.header,
                            modifier = Modifier.padding(start = 16.dp, top = 4.dp, bottom = 6.dp),
                            color = Palette.textTertiary,
                        )
                        group.items.forEach { dest ->
                            val selected = backStack?.destination?.hierarchy
                                ?.any { it.route == dest.route } == true
                            NavigationDrawerItem(
                                selected = selected,
                                onClick = {
                                    showMoreSheet = false
                                    if (dest.route != currentRoute) {
                                        nav.navigateTopLevel(dest.route)
                                    }
                                },
                                icon = { Icon(dest.icon, contentDescription = null) },
                                label = { Text(dest.title, style = NoopType.body) },
                                colors = NavigationDrawerItemDefaults.colors(
                                    selectedContainerColor = Palette.accentMuted,
                                    unselectedContainerColor = Palette.surfaceRaised,
                                    selectedIconColor = Palette.accent,
                                    unselectedIconColor = Palette.textSecondary,
                                    selectedTextColor = Palette.textPrimary,
                                    unselectedTextColor = Palette.textSecondary,
                                ),
                                modifier = Modifier.padding(NavigationDrawerItemDefaults.ItemPadding),
                            )
                        }
                    }
                }
            }
        }
    }
}

/** Bottom-bar item colours, matching the drawer's accent-on-raised selection treatment. */
@Composable
private fun navBarItemColors() = NavigationBarItemDefaults.colors(
    selectedIconColor = Palette.accent,
    selectedTextColor = Palette.textPrimary,
    indicatorColor = Palette.accentMuted,
    unselectedIconColor = Palette.textSecondary,
    unselectedTextColor = Palette.textSecondary,
)

/** Navigate to a top-level destination with single-top + state save/restore. */
private fun NavHostController.navigateTopLevel(route: String) {
    navigate(route) {
        popUpTo(graph.findStartDestination().id) { saveState = true }
        launchSingleTop = true
        restoreState = true
    }
}

/**
 * Placeholder screen for routes later waves will build. Uses [ScreenScaffold] so the
 * dark, instrument-grade chrome is already correct when a real screen replaces it.
 */
@Composable
fun ComingSoon(text: String, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .padding(28.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        NoopCard(padding = 28.dp) {
            Column(
                modifier = Modifier.fillMaxWidth(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(
                    Icons.Filled.Sensors,
                    contentDescription = null,
                    tint = Palette.textTertiary,
                )
                Spacer(Modifier.height(4.dp))
                Text(text, style = NoopType.title2, color = Palette.textPrimary, textAlign = TextAlign.Center)
                Overline("Coming soon", color = Palette.textSecondary)
                Text(
                    "This section is on the way.",
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                    textAlign = TextAlign.Center,
                )
            }
        }
    }
}
