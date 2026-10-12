import AppKit
import GooglyShared
import SwiftUI

/// The research report card. It shows up while he researches, then previews the first few lines.
/// Click it to expand; it stays on screen until you press the minus button.
@MainActor
final class ReportPanel {
    private var panel: NSPanel?
    private let model = ReportModel()

    func showLoading(_ question: String) {
        model.question = question
        model.report = nil
        model.error = nil
        model.expanded = false
        show()
    }

    func show(_ report: ResearchReport) {
        model.report = report
        model.error = nil
        show()
    }

    func showError(_ message: String) {
        model.error = message
        show()
    }

    /// Saves a picture of the card (for checking its look) and calls back when done.
    func snapshot(expanded: Bool, to path: String) {
        if model.expanded != expanded { toggle() }
        guard let view = panel?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func show() {
        if panel == nil { makePanel() }
        layout(animated: false)
        panel?.orderFrontRegardless()
    }

    private func makePanel() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)  // above his cursor overlay
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        let host = NSHostingView(rootView: ReportCard(model: model,
                                                      onToggle: { [weak self] in self?.toggle() },
                                                      onClose: { [weak self] in self?.close() }))
        panel.contentView = host
        self.panel = panel
    }

    private func toggle() {
        model.expanded.toggle()
        layout(animated: true)
    }

    /// Sits in the top-right corner of the main screen, out of the way of what he points at.
    private func layout(animated: Bool) {
        guard let panel, let screen = NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let width: CGFloat = model.expanded ? 520 : 400
        let height: CGFloat
        if model.expanded, let report = model.report {
            // Roughly fit the text (about 58 characters a line), up to most of the screen; it scrolls past that.
            let lines = report.paragraphs.reduce(0) { $0 + Int(ceil(Double($1.count) / 58)) }
            let content = CGFloat(lines) * 21 + CGFloat(report.paragraphs.count) * 12
                + (report.sources.isEmpty ? 0 : 30 + CGFloat(report.sources.count) * 22)
            height = min(visible.height * 0.75, 110 + content)
        } else {
            height = model.report == nil ? 140 : 190
        }
        let frame = NSRect(x: visible.maxX - width - 24, y: visible.maxY - height - 24, width: width, height: height)
        panel.setFrame(frame, display: true, animate: animated)
    }
}

final class ReportModel: ObservableObject {
    @Published var question = ""
    @Published var report: ResearchReport?
    @Published var error: String?
    @Published var expanded = false
}

private struct ReportCard: View {
    @ObservedObject var model: ReportModel
    var onToggle: () -> Void
    var onClose: () -> Void

    private let primaryBrand = Color(red: 0.30, green: 0.42, blue: 0.94)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let report = model.report {
                if model.expanded {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(report.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                                Text(paragraph)
                                    .font(.system(size: 14))
                                    .lineSpacing(4)
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if !report.sources.isEmpty {
                                Text("SOURCES & CITATIONS")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 6)
                                ForEach(Array(report.sources.enumerated()), id: \.offset) { _, source in
                                    Link(destination: source.url) {
                                        HStack(spacing: 6) {
                                            Image(systemName: "link")
                                                .font(.system(size: 10))
                                            Text(source.title)
                                                .font(.system(size: 12, weight: .medium))
                                                .lineLimit(1)
                                        }
                                        .foregroundStyle(primaryBrand)
                                        .padding(.vertical, 2)
                                    }
                                }
                            }
                        }
                        .padding(.trailing, 6)
                    }
                } else {
                    Text(report.paragraphs.joined(separator: " "))
                        .font(.system(size: 13.5))
                        .lineSpacing(3)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                    HStack(spacing: 4) {
                        Text("Click to expand report")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(primaryBrand)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(primaryBrand)
                    }
                }
            } else if let error = model.error {
                Text(error)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.red)
            } else {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Synthesizing research on \u{201C}\(model.question)\u{201D}…")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.vertical, 8)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 18, x: 0, y: 8)
        .padding(4)
        .contentShape(Rectangle())
        .onTapGesture { if model.report != nil, !model.expanded { onToggle() } }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: model.report == nil && model.error == nil ? "sparkles" : "doc.text.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(primaryBrand)
            Text(model.report?.title ?? (model.error == nil ? "Researching" : "Research"))
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(model.expanded ? 3 : 1)
            Spacer(minLength: 4)
            if model.expanded {
                circleButton("chevron.up", action: onToggle)
            }
            circleButton("xmark", action: onClose)
        }
    }

    private func circleButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }
}
