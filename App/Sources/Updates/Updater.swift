//
//  Updater.swift
//  Slice
//
//  Created by rit3zh CX on 10/24/26.
//

import AppKit
import os
import Sparkle

let updatesLog = Logger(subsystem: "com.abueammar.screenrecorder", category: "Updates")

/// Keeps the app up to date from its GitHub releases. Sparkle reads the signed appcast attached to the latest release,
/// checks the update's EdDSA signature before unpacking it and swaps the app in place; everything the user sees (the
/// card, the Settings rows) is the app's own, driven from here.
@MainActor
@Observable
final class Updater: NSObject {
    static let shared = Updater()

    struct Release: Equatable {
        let version: String
        let build: String
        let notes: [String]
        let date: Date?
        let page: URL?
    }

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        /// `total` is 0 until the size is known, and stays 0 for an update downloading in the background.
        case downloading(Release, received: UInt64, total: UInt64)
        case preparing(Release)
        case ready(Release)
        case installing(Release)
        case failed(String, Release?)
    }

    /// What to do with the update the next check finds, when the user acted without one in hand.
    enum Intent { case none, download, relaunch }

    var phase: Phase = .idle
    var cardShown = false
    var lastChecked: Date?
    private(set) var canCheck = false
    /// Why installing now would cut into something the user is doing; installing waits until it's done.
    private(set) var busyReason: String?

    @ObservationIgnored private(set) var sparkle: SPUUpdater!
    var reply: ((SPUUserUpdateChoice) -> Void)?
    var cancelDownload: (() -> Void)?
    var installNow: (() -> Void)?
    var intent = Intent.none
    /// Whether the user driver is running this download; automatic ones happen without it.
    var userSession = false
    /// Why a download was stopped, shown once Sparkle has wound it down.
    var problem: String?
    var received: UInt64 = 0
    /// Releases the user chose Later for: not offered again until next launch, unless they ask.
    var putOff: Set<String> = []
    @ObservationIgnored private var started = false
    @ObservationIgnored private var busyWatch: Task<Void, Never>?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    static let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    override private init() {
        super.init()
        sparkle = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        lastChecked = sparkle.lastUpdateCheckDate
    }

    /// Starts Sparkle once the app's windows are up, so launching never waits on the network. With automatic checks on,
    /// it checks straight away unless it already did within `SUScheduledCheckInterval`, then on that interval.
    func start() {
        guard !started else { return }
        started = true
        watchBusy()
        canCheckObservation = sparkle.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let can = change.newValue ?? false
            Task { @MainActor in self?.canCheck = can }
        }
        UpdateCardPanel.shared.start()
        do {
            try sparkle.start()
        } catch {
            updatesLog.error("Couldn't start the updater: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Kept by Sparkle, so they're registered with Observation by hand.
    var checksAutomatically: Bool {
        get {
            access(keyPath: \.checksAutomatically)
            return sparkle.automaticallyChecksForUpdates
        }
        set {
            withMutation(keyPath: \.checksAutomatically) { sparkle.automaticallyChecksForUpdates = newValue }
        }
    }

    var downloadsAutomatically: Bool {
        get {
            access(keyPath: \.downloadsAutomatically)
            return sparkle.automaticallyDownloadsUpdates
        }
        set {
            withMutation(keyPath: \.downloadsAutomatically) { sparkle.automaticallyDownloadsUpdates = newValue }
            // An update already on offer starts downloading now, not at the next scheduled check.
            if newValue, case .available = phase, reply == nil, sparkle.canCheckForUpdates {
                sparkle.checkForUpdatesInBackground()
            }
        }
    }

    var canCancel: Bool { cancelDownload != nil }

    // MARK: - Actions

    func checkNow() { check(.none) }

    func updateNow() {
        guard let reply = takeReply(), let release = phase.release else { return check(.download) }
        userSession = true
        phase = .downloading(release, received: 0, total: 0)
        reply(.install)
    }

    func skip() {
        cardShown = false
        guard let reply = takeReply() else { return }
        phase = .idle
        reply(.skip)
    }

    /// Takes the card down; the release stays on offer in Settings and comes back on the next launch.
    func later() {
        cardShown = false
        switch phase {
        case let .available(release), let .ready(release): putOff.insert(release.build)
        default: break
        }
        takeReply()?(.dismiss)
    }

    /// Takes the card down and leaves whatever is running to carry on.
    func hide() { cardShown = false }

    func cancel() { cancelDownload?() }

    func installAndRelaunch() {
        guard busyReason == nil, let release = phase.release else { return }
        intent = .relaunch
        if let reply = takeReply() {
            userSession = true
            phase = .installing(release)
            reply(.install)
        } else if let installNow {
            phase = .installing(release)
            installNow()
        } else {
            check(.relaunch)
        }
    }

    func retry() {
        if case .failed(_, nil) = phase { check(.none) } else { check(.download) }
    }

    private func check(_ next: Intent) {
        guard sparkle.canCheckForUpdates else { return }
        intent = next
        sparkle.checkForUpdates()
    }

    private func takeReply() -> ((SPUUserUpdateChoice) -> Void)? {
        defer { reply = nil }
        return reply
    }

    private func watchBusy() {
        let app = AppModel.shared
        busyWatch = Task { [weak self] in
            for await reason in Observations({ Self.busyReason(app) }) {
                guard let self, reason != busyReason else { continue }
                busyReason = reason
            }
        }
    }

    private static func busyReason(_ app: AppModel) -> String? {
        if app.recording != nil { return "Installs once you stop recording." }
        return app.openEditor?.exportJob?.isRunning == true ? "Installs once the export finishes." : nil
    }
}

extension Updater.Phase {
    var release: Updater.Release? {
        switch self {
        case let .available(release), let .downloading(release, _, _), let .preparing(release), let .ready(release),
             let .installing(release): release
        case let .failed(_, release): release
        case .idle, .checking, .upToDate: nil
        }
    }
}

extension Updater.Release {
    init(_ item: SUAppcastItem) {
        version = item.displayVersionString
        build = item.versionString
        notes = Self.lines(item.itemDescription ?? "", html: item.itemDescriptionFormat == "html")
        date = item.date
        page = item.infoURL
    }

    /// The release notes as short lines, without list markers or headings, for the card's preview.
    static func lines(_ text: String, html: Bool) -> [String] {
        var text = text
        if html {
            text = text.replacingOccurrences(of: "<(br|/p|/li|/h[1-6])[^>]*>", with: "\n", options: .regularExpression)
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
        }
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { $0.replacingOccurrences(of: "^([-*•]|\\d+\\.)\\s+", with: "", options: .regularExpression) }
    }
}
