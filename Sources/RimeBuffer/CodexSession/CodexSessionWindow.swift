import Cocoa
import SwiftTerm

/// Supplies the right pane's text. Kept a seam rather than a concrete
/// dependency: the only translation service in this app is bound to
/// `AppleTranslationWorkspace`'s job/generation model and to a SwiftUI
/// `TranslationSession`, so making it serve loose strings is an extraction,
/// not a call. Until that lands the pane shows the untranslated event, which
/// is still the whole run rather than one field of it.
protocol CodexEventTranslating: AnyObject {
    func translate(_ text: String,
                   completion: @escaping (String?) -> Void)
}

/// Left: the real codex CLI in a real terminal, untouched. Right: the same
/// run read from its rollout, where prose can be rewritten without disturbing
/// the terminal's own geometry.
///
/// The two panes are not a screen and a copy of that screen. Codex draws a
/// full-screen TUI that repaints, so there is no linear content to mirror, and
/// its layout is column arithmetic that CJK — being double-width — would break
/// the moment anything were translated in place. The rollout carries the same
/// session as structured events, which is what makes a second pane possible.
final class CodexSessionWindowController: NSWindowController {
    static let shared = CodexSessionWindowController()

    private let terminal = LocalProcessTerminalView(
        frame: NSRect(x: 0, y: 0, width: 720, height: 620)
    )
    private let eventTable = NSTableView()
    private let eventScroll = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let watcher = CodexRolloutWatcher()
    private var rows: [CodexSessionRow] = []
    private var workspace: URL = FileManager.default
        .homeDirectoryForCurrentUser
    private var translationHost: NSView?
    var translator: (any CodexEventTranslating)?

    struct CodexSessionRow {
        let item: CodexRolloutItem
        var displayText: String
        var isTranslated: Bool
    }

    private init() {
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Codex 会话"
        panel.isReleasedWhenClosed = false
        panel.appearance = RimeUI.appKitAppearance
        super.init(window: panel)
        buildLayout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    private func buildLayout() {
        eventTable.headerView = nil
        eventTable.rowSizeStyle = .custom
        eventTable.usesAutomaticRowHeights = true
        eventTable.backgroundColor = RimeUI.workbenchChrome
        eventTable.gridStyleMask = []
        eventTable.dataSource = self
        eventTable.delegate = self
        eventTable.intercellSpacing = NSSize(width: 0, height: 4)
        let column = NSTableColumn(identifier: .init("event"))
        column.resizingMask = .autoresizingMask
        eventTable.addTableColumn(column)
        eventScroll.documentView = eventTable
        eventScroll.hasVerticalScroller = true
        eventScroll.drawsBackground = false

        statusLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        statusLabel.textColor = RimeUI.textMuted
        statusLabel.stringValue = "尚未启动"

        let right = NSStackView(views: [statusLabel, eventScroll])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 6
        right.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        eventScroll.translatesAutoresizingMaskIntoConstraints = false
        eventScroll.widthAnchor.constraint(
            equalTo: right.widthAnchor, constant: -20
        ).isActive = true

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(terminal)
        split.addArrangedSubview(right)
        split.autoresizingMask = [.width, .height]
        split.frame = window?.contentView?.bounds ?? .zero
        window?.contentView?.addSubview(split)
        split.setPosition(700, ofDividerAt: 0)
        installTranslator(in: split)
    }

    /// Apple hands a `TranslationSession` only to a SwiftUI view attached to a
    /// live window, so the service's host is mounted here rather than kept
    /// off-screen. It draws nothing.
    private func installTranslator(in container: NSView) {
        guard #available(macOS 15.0, *) else {
            statusLabel.stringValue = "本机 macOS 版本不支持本地翻译"
            return
        }
        let service = AppleTranslationStringService()
        let host = service.makeHostView()
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: 1),
            host.heightAnchor.constraint(equalToConstant: 1),
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        translationHost = host
        translator = CodexAppleTranslator(service: service)
    }

    /// Launches codex in `workspace` and begins following the rollout it
    /// creates. The session cannot be named in advance, so the watcher
    /// identifies it by the `cwd` recorded in its own header.
    func present(workspace: URL) {
        self.workspace = workspace
        rows.removeAll()
        eventTable.reloadData()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let launchedAt = Date()
        let executable = CodexExecutableLocator.resolve()
        guard let executable else {
            statusLabel.stringValue = "未找到 codex 可执行文件（PATH 或 ~/.codex/bin）"
            return
        }
        statusLabel.stringValue = "启动中：\(executable.path)"
        let environment = ProcessInfo.processInfo.environment
        terminal.startProcess(
            executable: executable.path,
            args: [],
            environment: CodexProcessEnvironment.variables(
                base: Terminal.getEnvironmentVariables(
                    termName: "xterm-256color"
                ),
                inheritedPath: environment["PATH"],
                executable: executable,
                workspace: workspace,
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                shell: environment["SHELL"]
            ),
            execName: nil,
            currentDirectory: workspace.path
        )
        watcher.onLocated = { [weak self] location in
            self?.statusLabel.stringValue =
                "会话 \(location.header.sessionID.prefix(8)) · "
                + (location.header.cliVersion.map { "codex \($0)" } ?? "codex")
        }
        watcher.onEvents = { [weak self] events in
            self?.append(events)
        }
        watcher.start(workspace: workspace, launchedAfter: launchedAt)
    }

    func closeSession() {
        watcher.stop()
        window?.orderOut(nil)
    }

    private func append(_ events: [CodexRolloutEvent]) {
        dispatchPrecondition(condition: .onQueue(.main))
        for event in events {
            let text = CodexSessionRowFormatter.summary(for: event.item)
            var row = CodexSessionRow(item: event.item,
                                      displayText: text,
                                      isTranslated: false)
            let index = rows.count
            rows.append(row)
            // Only prose is eligible. A translated command no longer runs and
            // a translated diff no longer applies, so those stay verbatim.
            if let source = CodexEventTranslationRules
                .translatableText(in: event.item), let translator {
                translator.translate(source) { [weak self] translated in
                    guard let self, let translated, !translated.isEmpty,
                          index < self.rows.count else { return }
                    row.displayText = translated
                    row.isTranslated = true
                    self.rows[index] = row
                    self.eventTable.reloadData()
                }
            }
        }
        eventTable.reloadData()
        if rows.count > 0 {
            eventTable.scrollRowToVisible(rows.count - 1)
        }
    }
}

extension CodexSessionWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let entry = rows[row]
        let label = NSTextField(wrappingLabelWithString: entry.displayText)
        label.font = CodexEventTranslationRules.isTranslatable(entry.item)
            ? .systemFont(ofSize: 12)
            : .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = CodexEventTranslationRules.isTranslatable(entry.item)
            ? RimeUI.textPrimary
            : RimeUI.textSecondary
        label.isSelectable = true
        let container = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                           constant: 4),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor,
                                            constant: -4),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor,
                                          constant: -2),
        ])
        return container
    }
}

/// Renders a structural event as one readable line. Commands, paths and tool
/// calls are shown as themselves; only their framing is ours.
enum CodexSessionRowFormatter {
    static func summary(for item: CodexRolloutItem) -> String {
        switch item {
        case let .agentMessage(text, _): return text
        case let .reasoning(summary): return "· \(summary)"
        case let .userMessage(text): return "› \(text)"
        case let .plan(text): return text
        case let .commandExecution(command, _, exitCode, status):
            let suffix = exitCode.map { " → \($0)" }
                ?? status.map { " · \($0)" } ?? ""
            return "$ \(command)\(suffix)"
        case let .fileChange(paths, _):
            let names = paths.map { ($0 as NSString).lastPathComponent }
            return "± \(names.joined(separator: ", "))"
        case let .toolCall(server, tool, status):
            let origin = server.map { "\($0)/" } ?? ""
            return "⚙ \(origin)\(tool)\(status.map { " · \($0)" } ?? "")"
        case let .other(kind): return "· \(kind)"
        }
    }
}

/// Adapts the shared string translator to the pane's contract. Failures
/// resolve to nil so the row keeps its original text: an untranslated line is
/// readable, an error message in its place is not.
@available(macOS 15.0, *)
private final class CodexAppleTranslator: CodexEventTranslating {
    private let service: AppleTranslationStringService

    init(service: AppleTranslationStringService) { self.service = service }

    func translate(_ text: String,
                   completion: @escaping (String?) -> Void) {
        service.translate(text) { result in
            switch result {
            case let .success(translated): completion(translated)
            case .failure: completion(nil)
            }
        }
    }
}

enum CodexExecutableLocator {
    /// Mirrors how the text connector finds the CLI: an explicit install
    /// under ~/.codex/bin, then the usual package prefixes. `PATH` from a
    /// GUI-launched agent does not contain a user's shell additions.
    static func resolve(fileManager: FileManager = .default) -> URL? {
        var candidates = [
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent("codex")
            }
        }
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}
