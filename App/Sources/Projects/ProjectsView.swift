//
//  ProjectsView.swift
//  Slice
//
//  Created by rit3zh CX on 10/2/26.
//

import AVFoundation
import SliceCore
import SwiftUI

struct ProjectsView: View {
    @Environment(AppModel.self) var model
    @State private var search = ""
    @State private var lightsInset: CGFloat?
    @State private var scrolled: CGFloat = 0
    @State private var columns = Self.lastColumns
    @State private var laidOut = false
    /// The grid comes back with the columns it had, so it doesn't reflow under a picture flying back into it.
    private static var lastColumns = 3

    static let barHeight: CGFloat = 52
    private nonisolated static let gutter: CGFloat = 22
    private nonisolated static let margin: CGFloat = 32
    private nonisolated static let minCard: CGFloat = 240

    private var shown: [ProjectBundle] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.projects }
        return model.projects.filter { $0.displayName.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        ZStack(alignment: .top) {
            content
            bar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.window)
        .ignoresSafeArea(.container, edges: .top)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .tint(Theme.accent)
        .onAppear { model.reloadProjects() }
        .task {
            try? await Task.sleep(for: .milliseconds(600))
            laidOut = true
        }
        .dropDestination(for: URL.self) { urls, _ in
            let found = urls.filter(ProjectBundle.isProject)
            if !found.isEmpty {
                model.openFiles(found)
                return true
            }
            // Videos you already have (a Simulator recording among them) start a project of their own.
            let videos = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .movie) ?? false }
            guard !videos.isEmpty else { return false }
            model.importNewProject(videos)
            return true
        }
    }

    // MARK: Bar

    private var bar: some View {
        HStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("Projects")
                    .font(.rounded(15, .semibold))
                if !model.projects.isEmpty {
                    Text("\(model.projects.count)")
                        .font(.rounded(13, .medium))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .contentTransition(.numericText())
                }
            }
            .allowsHitTesting(false)
            Spacer(minLength: 16)
            // Rendered together, the glass pieces merge only where they touch: a wider blend distance left them on the
            // edge of merging as the search field grew, flickering every frame.
            GlassEffectContainer(spacing: 0) {
                HStack(spacing: 8) {
                    if !model.projects.isEmpty { SearchField(text: $search) }
                    Button(action: importVideos) {
                        Label("Import Video…", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(GlassBarButtonStyle(shape: Circle()))
                    .help("Start a project from videos you already have")
                    NewRecordingButton { model.newRecording() }
                }
            }
        }
        .padding(.leading, (lightsInset ?? 14) + 4)
        .padding(.trailing, 16)
        .frame(height: Self.barHeight)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            ScrollEdge(edge: .top, height: Self.barHeight + 36, strength: 0.8, blur: 0.95)
                .frame(height: Self.barHeight + 36, alignment: .top)
                .opacity(scrolled)
                .allowsHitTesting(false)
        }
        .background { DragArea() }
        .background(TrafficLights(height: Self.barHeight, leading: 20) { lightsInset = $0 })
        .animation(Theme.slide, value: model.projects.count)
    }

    // MARK: Grid

    @ViewBuilder private var content: some View {
        let shown = self.shown
        let days = ProjectDay.group(shown)
        if model.projects.isEmpty {
            EmptyProjects(record: { model.newRecording() }, importVideos: importVideos)
        } else if shown.isEmpty {
            VStack(spacing: 4) {
                Text("No results")
                    .font(.system(size: 13, weight: .medium))
                Text("Nothing called “\(search.trimmingCharacters(in: .whitespaces))”.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, Self.barHeight)
            .transition(.opacity)
        } else {
            ScrollView {
                // Plain VStack: a LazyVStack sometimes left an emptied day behind as a blank gap.
                VStack(alignment: .leading, spacing: 34) {
                    ForEach(days) { day in
                        VStack(alignment: .leading, spacing: 14) {
                            Text(day.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 2)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.gutter, alignment: .top),
                                                     count: columns),
                                      alignment: .leading, spacing: 26) {
                                ForEach(day.projects, id: \.url) { bundle in
                                    ProjectCard(bundle: bundle) {
                                        model.open(bundle)
                                    } delete: {
                                        withAnimation(Theme.slide) { model.trash(bundle) }
                                    }
                                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                                }
                            }
                        }
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, Self.margin)
                .padding(.top, 10)
                .padding(.bottom, 40)
                .animation(Theme.slide, value: shown.map(\.url))
            }
            .contentMargins(.top, Self.barHeight, for: .scrollContent)
            .contentMargins(.top, Self.barHeight, for: .scrollIndicators)
            .scrollIndicators(.automatic)
            // The title bar's blur replaces the system's soft edge so the two don't stack.
            .scrollEdgeEffectHidden(true, for: .all)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                min(max((geometry.contentOffset.y + geometry.contentInsets.top) / 24, 0), 1)
            } action: { _, amount in
                withAnimation(.smooth(duration: 0.18)) { scrolled = amount }
            }
            .onGeometryChange(for: Int.self) { geometry in
                let room = geometry.size.width - Self.margin * 2
                return max(1, Int((room + Self.gutter) / (Self.minCard + Self.gutter)))
            } action: { count in
                guard count != columns else { return }
                Self.lastColumns = count
                if laidOut {
                    withAnimation(.smooth(duration: 0.38)) { columns = count }
                } else {
                    columns = count
                }
            }
            .overlay(alignment: .bottom) {
                ScrollEdge(edge: .bottom, height: 56, strength: 0.6).allowsHitTesting(false)
            }
        }
    }

    private func importVideos() {
        if let urls = chooseVideos() { model.importNewProject(urls) }
    }
}

// MARK: - Scroll edge

private struct ScrollEdge: View {
    let edge: VerticalEdge
    let height: CGFloat
    var strength: Double = 0.75
    var blur: Double = 0.45

    var body: some View {
        let start: UnitPoint = edge == .top ? .top : .bottom
        let end: UnitPoint = edge == .top ? .bottom : .top
        let fade = LinearGradient(gradient: Self.eased(Theme.window.opacity(strength), Theme.window.opacity(0), curve: .easeInOut),
                                  startPoint: start, endPoint: end)
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(blur)
                .mask(LinearGradient(gradient: Self.eased(.black, .clear, curve: .easeOut), startPoint: start, endPoint: end))
            fade
        }
        .frame(height: height)
        .frame(maxHeight: .infinity, alignment: edge == .top ? .top : .bottom)
    }

    /// Eased stops, so the fade has no visible band where a linear ramp would start or end.
    private static func eased(_ from: Color, _ to: Color, curve: UnitCurve, steps: Int = 32) -> Gradient {
        Gradient(stops: (0...steps).map { i in
            let t = Double(i) / Double(steps)
            return .init(color: from.mix(with: to, by: curve.value(at: t)), location: t)
        })
    }
}

// MARK: - Days

private struct ProjectDay: Identifiable {
    let title: String
    var projects: [ProjectBundle]
    var id: String { title }

    static func group(_ bundles: [ProjectBundle]) -> [ProjectDay] {
        let calendar = Calendar.current
        var days: [ProjectDay] = []
        let dated = bundles.map { ($0, $0.lastModified) }.sorted { $0.1 > $1.1 }
        for (bundle, date) in dated {
            let title = Self.title(for: date, calendar: calendar)
            if let i = days.firstIndex(where: { $0.title == title }) {
                days[i].projects.append(bundle)
            } else {
                days.append(ProjectDay(title: title, projects: [bundle]))
            }
        }
        return days
    }

    private static func title(for date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: Date())).day,
           days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        let thisYear = calendar.isDate(date, equalTo: Date(), toGranularity: .year)
        return thisYear ? date.formatted(.dateTime.month(.wide)) : date.formatted(.dateTime.month(.wide).year())
    }
}
