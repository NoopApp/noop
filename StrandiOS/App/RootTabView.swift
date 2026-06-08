#if os(iOS)
import SwiftUI
import StrandDesign

/// iOS navigation shell. macOS uses a `NavigationSplitView` sidebar (`RootView`); on iPhone the
/// natural analogue is a `TabView` with the most-used screens as tabs and everything else under a
/// "More" list. Every screen is the same `StrandDesign`-built view the macOS app uses.
struct RootTabView: View {
    @EnvironmentObject private var repo: Repository

    var body: some View {
        TabView {
            tab(TodayView(), "Today", "circle.hexagongrid.fill")
            tab(TrendsView(), "Trends", "chart.xyaxis.line")
            tab(LiveView(), "Live", "waveform.path.ecg")
            tab(SleepView(), "Sleep", "bed.double.fill")
            moreTab
        }
        .tint(StrandPalette.accent)
        .preferredColorScheme(.dark)
        .task { await repo.refresh() }
    }

    private func tab<V: View>(_ view: V, _ title: LocalizedStringKey, _ icon: String) -> some View {
        view
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .tabItem { Label(title, systemImage: icon) }
    }

    private var moreTab: some View {
        NavigationStack {
            List {
                Section("Insights") {
                    link("Intelligence", "brain.head.profile") { IntelligenceView() }
                    link("Coach", "sparkles") { CoachView() }
                    link("Insights", "lightbulb.fill") { InsightsView() }
                    link("Explore", "square.grid.2x2.fill") { MetricExplorerView() }
                    link("Compare", "rectangle.split.2x1.fill") { CompareView() }
                }
                Section("Body") {
                    link("Workouts", "figure.run") { WorkoutsView() }
                    link("Health", "heart.text.square.fill") { HealthView() }
                    link("Stress", "bolt.heart.fill") { StressView() }
                    link("Breathe", "wind") { BreathingView() }
                    link("Intervals", "timer") { IntervalTimerView() }
                }
                Section("Data") {
                    link("Apple Health", "heart.fill") { AppleHealthView() }
                    link("Data Sources", "externaldrive.fill") { DataSourcesView() }
                }
                Section("App") {
                    link("Automations", "wand.and.stars") { AutomationsView() }
                    link("Settings", "gearshape.fill") { SettingsView() }
                    link("Support", "hands.clap.fill") { SupportView() }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("More")
        }
        .tabItem { Label("More", systemImage: "ellipsis.circle.fill") }
    }

    private func link<V: View>(_ title: LocalizedStringKey, _ icon: String, @ViewBuilder _ dest: @escaping () -> V) -> some View {
        NavigationLink {
            dest()
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(StrandPalette.surfaceBase, for: .navigationBar)
        } label: {
            Label(title, systemImage: icon)
        }
        .listRowBackground(StrandPalette.surfaceRaised)
    }
}
#endif
