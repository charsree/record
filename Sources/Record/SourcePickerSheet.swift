import AppKit
import CoreGraphics
import ScreenCaptureKit
import SwiftUI

/// Metadata + thumbnail for one capturable display or window.
struct CaptureSource: Identifiable, Hashable {
    enum Kind { case display, window }
    let id: String
    let kind: Kind
    let target: CaptureTarget
    let title: String
    let subtitle: String
    let thumbnail: NSImage?

    static func == (lhs: CaptureSource, rhs: CaptureSource) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum CaptureSources {
    /// Grabs every shareable display + window from ScreenCaptureKit, renders
    /// a small thumbnail for each, and returns them in a stable order.
    /// Requires the Screen Recording TCC grant.
    static func snapshot() async throws -> [CaptureSource] {
        // excludingDesktopWindows: true → drop wallpaper/desktop icons.
        // onScreenWindowsOnly: true → drop minimized / offscreen windows.
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true
        )
        var results: [CaptureSource] = []

        let selfBundle = Bundle.main.bundleIdentifier ?? "local.record.app"
        let selfApps = content.applications.filter { $0.bundleIdentifier == selfBundle }

        // Displays first.
        for (index, display) in content.displays.enumerated() {
            let filter = SCContentFilter(
                display: display,
                excludingApplications: selfApps,
                exceptingWindows: []
            )
            let thumbnail = try? await thumbnail(for: filter, maxWidth: 480, maxHeight: 300)
            results.append(CaptureSource(
                id: "display-\(display.displayID)",
                kind: .display,
                target: .display(display.displayID),
                title: "Display \(index + 1)",
                subtitle: "\(display.width) × \(display.height)",
                thumbnail: thumbnail
            ))
        }

        // Windows — keep only real, user-facing app windows.
        let filteredWindows = content.windows
            .filter { isRealAppWindow($0, selfBundleID: selfBundle) }
            .compactMap { window -> (SCWindow, String, String)? in
                guard let title = window.title?.trimmingCharacters(in: .whitespaces),
                      !title.isEmpty,
                      let app = window.owningApplication?.applicationName else {
                    return nil
                }
                return (window, "\(app) — \(title)", app)
            }
            .sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }

        for (window, label, app) in filteredWindows {
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let thumbnail = try? await thumbnail(for: filter, maxWidth: 320, maxHeight: 220)
            results.append(CaptureSource(
                id: "window-\(window.windowID)",
                kind: .window,
                target: .window(window.windowID),
                title: label,
                subtitle: app,
                thumbnail: thumbnail
            ))
        }

        return results
    }

    /// Bundle IDs whose windows are just system chrome and should never appear
    /// in a "which window do you want to share?" picker.
    private static let systemChromeBundleIDs: Set<String> = [
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.spotlight",
        "com.apple.WindowManager",
        "com.apple.WindowServer",
        "com.apple.wallpaper.WallpaperAgent",
        "com.apple.wallpaper",
        "com.apple.loginwindow",
        "com.apple.TextInputMenuAgent",
        "com.apple.TextInputSwitcher",
        "com.apple.PressAndHold",
        "com.apple.screencaptureui",
        "com.apple.screensharing",
        "com.apple.CoreLocationAgent",
        "com.apple.universalcontrol",
        "com.apple.controlstrip",
        "com.apple.finder.desktop"
    ]

    private static func isRealAppWindow(_ window: SCWindow, selfBundleID: String) -> Bool {
        guard let app = window.owningApplication else { return false }
        if app.bundleIdentifier == selfBundleID { return false }
        if systemChromeBundleIDs.contains(app.bundleIdentifier) { return false }
        // Normal application windows sit on layer 0. Menu bar items, dock
        // tiles, notification banners, wallpaper, and Control Center overlays
        // are on higher layers.
        guard window.windowLayer == 0 else { return false }
        // Some tiny helper windows (tooltips, status HUDs, offscreen scratch
        // views) still make it through — drop anything smaller than a real,
        // usable window.
        guard window.frame.width >= 200, window.frame.height >= 120 else { return false }
        guard window.isOnScreen else { return false }
        return true
    }

    private static func thumbnail(
        for filter: SCContentFilter,
        maxWidth: Int,
        maxHeight: Int
    ) async throws -> NSImage {
        let configuration = SCStreamConfiguration()
        // Fit the filter's content rect into the requested bounding box.
        let contentSize = filter.contentRect.size
        let widthRatio = contentSize.width > 0 ? Double(maxWidth) / contentSize.width : 1
        let heightRatio = contentSize.height > 0 ? Double(maxHeight) / contentSize.height : 1
        let ratio = min(widthRatio, heightRatio, 1)
        configuration.width = max(64, Int(contentSize.width * ratio))
        configuration.height = max(64, Int(contentSize.height * ratio))
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

/// Screensharing-style source picker. Grid of thumbnails, click to switch.
struct SourcePickerSheet: View {
    @ObservedObject var session: MeetingSession
    @Environment(\.dismiss) private var dismiss

    @State private var sources: [CaptureSource] = []
    @State private var loading = true
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose what to share")
                    .font(.title2.bold())
                Spacer()
                Button {
                    Task { await load() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            if loading && sources.isEmpty {
                ProgressView("Fetching sources…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView(
                    "Can't list sources",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    displaySection
                    windowSection
                }
            }
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 480, idealHeight: 560)
        .task { await load() }
    }

    @ViewBuilder
    private var displaySection: some View {
        let displays = sources.filter { $0.kind == .display }
        if !displays.isEmpty {
            SectionHeader(title: "Displays")
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(displays) { source in
                    SourceTile(
                        source: source,
                        isSelected: matches(source),
                        onSelect: { pick(source) }
                    )
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private var windowSection: some View {
        let windows = sources.filter { $0.kind == .window }
        if !windows.isEmpty {
            SectionHeader(title: "Windows")
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(windows) { source in
                    SourceTile(
                        source: source,
                        isSelected: matches(source),
                        onSelect: { pick(source) }
                    )
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 20)
        }
    }

    private func matches(_ source: CaptureSource) -> Bool {
        switch (source.target, session.selectedCaptureTarget) {
        case (.display(let a), .display(let b)): a == b
        case (.window(let a), .window(let b)): a == b
        case (.display, .primaryDisplay):
            // Primary display is whichever display is first.
            source.id == sources.first(where: { $0.kind == .display })?.id
        default: false
        }
    }

    private func pick(_ source: CaptureSource) {
        Task {
            await session.changeCaptureTarget(source.target)
            dismiss()
        }
    }

    private func load() async {
        loading = true
        errorMessage = nil
        do {
            let fetched = try await CaptureSources.snapshot()
            sources = fetched
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }
}

private struct SectionHeader: View {
    let title: String
    var body: some View {
        HStack {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

private struct SourceTile: View {
    let source: CaptureSource
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    if let thumbnail = source.thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .frame(height: 140)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
                            )
                    } else {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.quaternary)
                            .frame(height: 140)
                            .overlay(Image(systemName: source.kind == .display ? "display" : "macwindow")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary))
                    }
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(8)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(source.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12).fill(.background.opacity(0.001)))
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}
