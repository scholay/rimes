import Carbon.HIToolbox
import CryptoKit
import Foundation

extension Notification.Name {
    /// Presentation-only notification. Consumers may refresh controls and
    /// status labels, but must never infer or request page text from it.
    static let builtInBufferActionWorkspaceDidChange = Notification.Name(
        "RimeBuffer.BuiltInBufferActionWorkspace.didChange"
    )
}

/// A compact, text-free description of a trusted action shown in the expanded
/// workbench shelf. Built-in actions import content into `BufferModel`; they do
/// not become delivery sources and never receive an IMK client.
struct BuiltInBufferActionPresentation: Equatable {
    let title: String
    let symbolName: String
    let statusText: String
    let toolTip: String
    let isRunning: Bool
    let isEnabled: Bool
}

struct BuiltInBufferActionOption: Equatable {
    let identifier: String
    let title: String
}

/// Optional, non-text configuration rendered immediately beside a built-in
/// workbench action. The value stays in the owning workspace; the shelf only
/// presents stable identifiers and titles.
struct BuiltInBufferActionOptionPresentation: Equatable {
    let options: [BuiltInBufferActionOption]
    let selectedIdentifier: String
    let toolTip: String
    let isEnabled: Bool
}

protocol BuiltInBufferActionWorkspace: AnyObject {
    var workspacePluginKey: PluginKey { get }
    var workbenchDisplayName: String { get }
    var actionPresentation: BuiltInBufferActionPresentation { get }
    var optionPresentation: BuiltInBufferActionOptionPresentation? { get }

    @discardableResult func invoke() -> Bool
    @discardableResult func requestRefresh() -> Bool
    @discardableResult func selectOption(identifier: String) -> Bool
    func setOwnerActive(_ active: Bool)
    func setProtected(_ protected: Bool)
    func workbenchWillPause()
}

extension BuiltInBufferActionWorkspace {
    var optionPresentation: BuiltInBufferActionOptionPresentation? { nil }

    @discardableResult
    func selectOption(identifier _: String) -> Bool { false }
}

/// Built-in import actions deliberately stay separate from
/// `DerivedBufferWorkspaceRouter`: a successful import becomes ordinary staged
/// content, so it must subsequently travel through the normal explicit
/// `BufferDeliveryCoordinator -> Delivery.insert` path.
enum BuiltInBufferActionWorkspaceRouter {
    private static var all: [any BuiltInBufferActionWorkspace] {
        [RemarkableWorkspace.shared]
    }

    static var selectedWorkspace: (any BuiltInBufferActionWorkspace)? {
        guard let activeKey = BufferPluginSelectionStore.shared.activeKey else {
            return nil
        }
        return all.first { $0.workspacePluginKey == activeKey }
    }

    static func setProtectedOnAll(_ protected: Bool) {
        all.forEach { $0.setProtected(protected) }
    }

    static func activeSelectionDidChange() {
        let activeKey = BufferPluginSelectionStore.shared.activeKey
        all.forEach { $0.setOwnerActive($0.workspacePluginKey == activeKey) }
    }
}

struct RemarkableSSHTarget: Equatable {
    static let defaultsKey = "plugins.remarkable.sshTarget.v1"
    static let defaultDestination = "root@10.11.99.1"

    let destination: String
    let username: String?
    let host: String
    /// A path reference only. The password itself is never copied into a pull
    /// request, argv, stdin, or an environment value.
    let passwordCredentialURL: URL?

    init(validating destination: String) throws {
        guard Self.isValid(destination) else {
            throw RemarkablePullError.invalidTarget
        }
        self.destination = destination
        let components = destination.split(
            separator: "@",
            omittingEmptySubsequences: false
        )
        if components.count == 2 {
            username = String(components[0])
            host = String(components[1])
        } else {
            username = nil
            host = destination
        }
        passwordCredentialURL = nil
    }

    init(username: String,
         host: String,
         passwordCredentialURL: URL? = nil) throws {
        guard Self.isValidUsername(username),
              Self.isValidHostOrAlias(host) else {
            throw RemarkablePullError.invalidTarget
        }
        self.username = username
        self.host = host
        destination = "\(username)@\(host)"
        self.passwordCredentialURL =
            passwordCredentialURL?.standardizedFileURL
    }

    static func configured(in defaults: UserDefaults) throws -> RemarkableSSHTarget {
        let value = defaults.object(forKey: defaultsKey) == nil
            ? defaultDestination
            : (defaults.string(forKey: defaultsKey) ?? "")
        return try RemarkableSSHTarget(validating: value)
    }

    private static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 255,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.hasPrefix("-"),
              value.unicodeScalars.allSatisfy(\.isASCII) else {
            return false
        }

        let components = value.split(separator: "@",
                                     omittingEmptySubsequences: false)
        switch components.count {
        case 1:
            return isValidHostOrAlias(String(components[0]))
        case 2:
            return isValidUsername(String(components[0]))
                && isValidHostOrAlias(String(components[1]))
        default:
            return false
        }
    }

    static func isValidUsername(_ value: String) -> Bool {
        value.range(
            of: #"^[A-Za-z_][A-Za-z0-9._-]{0,63}$"#,
            options: .regularExpression
        ) != nil
    }

    static func isValidHostOrAlias(_ value: String) -> Bool {
        guard value.count <= 253,
              value.range(
                of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#,
                options: .regularExpression
              ) != nil,
              !value.contains(".."),
              !value.hasSuffix("."),
              !value.hasSuffix("-") else {
            return false
        }
        return true
    }
}

struct RemarkablePageSnapshot: Equatable {
    let documentID: String
    let pageID: String
    let pageIndex: Int
    let pageCount: Int
    let data: Data
    let pdfData: Data
}

protocol RemarkablePagePulling: AnyObject {
    @discardableResult
    func pullLatestPage(from target: RemarkableSSHTarget,
                        completion: @escaping (Result<RemarkablePageSnapshot,
                                                       RemarkablePullError>) -> Void)
        -> any AITextCancellable
}

enum RemarkablePullStage: String, Equatable {
    case locator
    case content
    case firstPageRead
    case secondPageRead
    case pdfExport
    case finalPageRead

    var userFacingName: String {
        switch self {
        case .locator: return "文档索引"
        case .content: return "页面目录"
        case .firstPageRead, .secondPageRead, .finalPageRead: return "页面"
        case .pdfExport: return "PDF 导出"
        }
    }
}

enum RemarkablePullError: LocalizedError, Equatable {
    case invalidTarget
    case launchFailed
    case passwordAuthenticationUnavailable
    case hostKeyNotTrusted
    case hostKeyChanged
    case authenticationFailed
    case connectionFailed
    case timedOut
    case cancelled
    case outputTooLarge(RemarkablePullStage)
    case remoteDataUnavailable(RemarkablePullStage)
    case remoteCommandFailed(RemarkablePullStage)
    case noRecentlyOpenedDocument
    case invalidDocumentLocator
    case invalidDocumentContent
    case pageNotFound
    case pageMappingMismatch
    case pdfExportUnavailable
    case invalidPDFExport
    case pageChangedWhileReading

    var errorDescription: String? {
        switch self {
        case .invalidTarget:
            return "SSH 目标格式无效，请填写主机别名或 user@host"
        case .launchFailed:
            return "无法启动系统 SSH"
        case .passwordAuthenticationUnavailable:
            return "无法启动 reMarkable 密码认证助手"
        case .hostKeyNotTrusted:
            return "SSH 尚未信任这台 reMarkable，请先核对主机指纹并加入 known_hosts"
        case .hostKeyChanged:
            return "reMarkable 的 SSH 主机密钥已变化，请先核对设备身份再更新 known_hosts"
        case .authenticationFailed:
            return "reMarkable SSH 认证失败，请检查用户名、密码、密钥或 ssh-agent"
        case .connectionFailed:
            return "无法连接 reMarkable，请检查 USB、网络地址和设备状态"
        case .timedOut:
            return "连接 reMarkable 超时，请确认设备仍在线"
        case .cancelled:
            return "拉取已取消"
        case let .outputTooLarge(stage):
            return "\(stage.userFacingName)数据过大，已停止拉取"
        case let .remoteDataUnavailable(stage):
            return "\(stage.userFacingName)在读取时发生变化或暂不可用，请重试"
        case .remoteCommandFailed:
            return "SSH 读取失败，请确认设备连接、用户名、密码或密钥和已知主机配置"
        case .noRecentlyOpenedDocument:
            return "没有找到最近打开的 reMarkable 文档"
        case .invalidDocumentLocator:
            return "最近打开的文档信息无效"
        case .invalidDocumentContent:
            return "无法识别 reMarkable 的页面目录"
        case .pageNotFound:
            return "没有找到最近打开的页面"
        case .pageMappingMismatch:
            return "reMarkable 导出页与当前页面目录不一致，请重试"
        case .pdfExportUnavailable:
            return "无法从 reMarkable 导出 PDF，请确认 USB Web Interface 已开启"
        case .invalidPDFExport:
            return "reMarkable 导出的 PDF 不完整或无效，请稍后重试"
        case .pageChangedWhileReading:
            return "页面仍在写入，请稍后重试"
        }
    }

    var logCode: String {
        switch self {
        case .invalidTarget: return "invalid-target"
        case .launchFailed: return "launch-failed"
        case .passwordAuthenticationUnavailable:
            return "password-authentication-unavailable"
        case .hostKeyNotTrusted: return "host-key-not-trusted"
        case .hostKeyChanged: return "host-key-changed"
        case .authenticationFailed: return "authentication-failed"
        case .connectionFailed: return "connection-failed"
        case .timedOut: return "timeout"
        case .cancelled: return "cancelled"
        case let .outputTooLarge(stage): return "output-too-large-\(stage.rawValue)"
        case let .remoteDataUnavailable(stage):
            return "remote-data-unavailable-\(stage.rawValue)"
        case let .remoteCommandFailed(stage): return "remote-failed-\(stage.rawValue)"
        case .noRecentlyOpenedDocument: return "no-document"
        case .invalidDocumentLocator: return "invalid-locator"
        case .invalidDocumentContent: return "invalid-content"
        case .pageNotFound: return "page-not-found"
        case .pageMappingMismatch: return "page-mapping-mismatch"
        case .pdfExportUnavailable: return "pdf-export-unavailable"
        case .invalidPDFExport: return "invalid-pdf-export"
        case .pageChangedWhileReading: return "page-changed"
        }
    }
}

final class RemarkableSSHPagePuller: RemarkablePagePulling {
    // Page identity reads, a device-side PDF export, and final revalidation all
    // share one explicit-action budget. The USB exporter may need several
    // seconds and a bounded retry while Xochitl finishes its current write.
    static let defaultTotalTimeout: TimeInterval = 60

    private let runner: any AITextCLIProcessRunning
    private let environment: [String: String]
    private let askPassExecutableURL: URL?
    private let totalTimeout: TimeInterval
    private let pdfValidator: (Data, Int, Int) -> Bool

    init(runner: any AITextCLIProcessRunning = AITextFoundationCLIProcessRunner(),
         processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
         askPassExecutableURL: URL? = Bundle.main.executableURL,
         totalTimeout: TimeInterval = defaultTotalTimeout,
         pdfValidator: @escaping (Data, Int, Int) -> Bool = {
             RemarkablePDFKitDocumentValidator.isValid(
                 data: $0,
                 pageIndex: $1,
                 expectedPageCount: $2
             )
         }) {
        self.runner = runner
        environment = Self.allowedEnvironment(from: processEnvironment)
        self.askPassExecutableURL = askPassExecutableURL?.standardizedFileURL
        self.totalTimeout = totalTimeout.isFinite && totalTimeout > 0
            ? totalTimeout
            : Self.defaultTotalTimeout
        self.pdfValidator = pdfValidator
    }

    @discardableResult
    func pullLatestPage(from target: RemarkableSSHTarget,
                        completion: @escaping (Result<RemarkablePageSnapshot,
                                                       RemarkablePullError>) -> Void)
        -> any AITextCancellable {
        let operation = RemarkableSSHPullOperation(
            runner: runner,
            environment: environment,
            askPassExecutableURL: askPassExecutableURL,
            totalTimeout: totalTimeout,
            target: target,
            pdfValidator: pdfValidator,
            completion: completion
        )
        operation.start()
        return operation
    }

    private static func allowedEnvironment(from environment: [String: String])
        -> [String: String] {
        let allowedKeys = ["HOME", "SSH_AUTH_SOCK", "LANG", "PATH"]
        return allowedKeys.reduce(into: [:]) { result, key in
            guard let value = environment[key], !value.isEmpty else { return }
            result[key] = value
        }
    }
}

private final class RemarkableCancellationRelay: AITextCancellable {
    private let lock = NSLock()
    private var downstream: (any AITextCancellable)?
    private var cancelled = false

    func install(_ task: any AITextCancellable) {
        lock.lock()
        if cancelled {
            lock.unlock()
            task.cancel()
            return
        }
        downstream = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = downstream
        downstream = nil
        lock.unlock()
        task?.cancel()
    }
}

private final class RemarkableSSHPullOperation: AITextCancellable {
    private struct Locator {
        let documentID: String
        let legacyPageIndex: Int?
        let legacyPageID: String?
    }

    private struct PageSelection: Equatable {
        let pageID: String
        let pageIndex: Int
        let pageCount: Int
    }

    private static let xochitlRoot =
        "/home/root/.local/share/remarkable/xochitl"
    private static let locatorOutputLimit = 8 * 1_024
    private static let contentOutputLimit = 2 * 1_024 * 1_024
    private static let pageOutputLimit = 8 * 1_024 * 1_024
    private static let pdfOutputLimit = 32 * 1_024 * 1_024
    private static let maximumPDFExportAttempts = 3
    private static let pdfExportRetryDelays: [TimeInterval] = [0.75, 1.5]

    /// This command is a fixed, read-only program. The SSH destination is a
    /// separately validated argv element and is never interpolated here.
    private static let locateRecentlyOpenedDocumentCommand = #"""
    root='/home/root/.local/share/remarkable/xochitl'
    best_opened=''
    best_doc=''
    best_page=''
    for file in "$root"/*.metadata; do
      [ -f "$file" ] || continue
      opened=$(sed -n 's/.*"lastOpened"[[:space:]]*:[[:space:]]*"\{0,1\}\([0-9][0-9]*\)"\{0,1\}.*/\1/p' "$file" | head -n 1)
      case "$opened" in ''|*[!0-9]*) continue ;; esac
      doc=${file##*/}
      doc=${doc%.metadata}
      page=$(sed -n 's/.*"lastOpenedPage"[[:space:]]*:[[:space:]]*"\{0,1\}\([^",}]*\)"\{0,1\}.*/\1/p' "$file" | head -n 1)
      if [ -z "$best_opened" ] || [ "$opened" -gt "$best_opened" ]; then
        best_opened=$opened
        best_doc=$doc
        best_page=$page
      fi
    done
    if [ -n "$best_doc" ]; then
      printf '%s\t%s\n' "$best_doc" "$best_page"
    fi
    exit 0
    """#

    private let runner: any AITextCLIProcessRunning
    private let environment: [String: String]
    private let askPassExecutableURL: URL?
    private let totalTimeout: TimeInterval
    private let target: RemarkableSSHTarget
    private let pdfValidator: (Data, Int, Int) -> Bool
    private let completion: (Result<RemarkablePageSnapshot,
                                    RemarkablePullError>) -> Void
    private let queue = DispatchQueue(
        label: "RimeBuffer.RemarkableSSHPagePuller",
        qos: .userInitiated
    )
    private var deadline = Date.distantPast
    private var currentTask: (any AITextCancellable)?
    private var watchdog: DispatchWorkItem?
    private var cancelled = false
    private var finished = false

    init(runner: any AITextCLIProcessRunning,
         environment: [String: String],
         askPassExecutableURL: URL?,
         totalTimeout: TimeInterval,
         target: RemarkableSSHTarget,
         pdfValidator: @escaping (Data, Int, Int) -> Bool,
         completion: @escaping (Result<RemarkablePageSnapshot,
                                         RemarkablePullError>) -> Void) {
        self.runner = runner
        self.environment = environment
        self.askPassExecutableURL = askPassExecutableURL
        self.totalTimeout = totalTimeout
        self.target = target
        self.pdfValidator = pdfValidator
        self.completion = completion
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.deadline = Date().addingTimeInterval(self.totalTimeout)
            let watchdog = DispatchWorkItem { [weak self] in
                guard let self, !self.finished else { return }
                self.currentTask?.cancel()
                self.currentTask = nil
                self.finish(.failure(.timedOut))
            }
            self.watchdog = watchdog
            self.queue.asyncAfter(
                deadline: .now() + self.totalTimeout,
                execute: watchdog
            )
            self.readLocator()
        }
    }

    func cancel() {
        // Capture the operation strongly until cancellation reaches its serial
        // queue. The workspace intentionally drops its task reference
        // immediately after tombstoning the generation.
        queue.async {
            guard !self.finished else { return }
            self.cancelled = true
            self.currentTask?.cancel()
            self.currentTask = nil
            self.finish(.failure(.cancelled))
        }
    }

    private func readLocator() {
        run(stage: .locator,
            remoteCommand: Self.locateRecentlyOpenedDocumentCommand,
            maximumOutputBytes: Self.locatorOutputLimit) { result in
            guard case let .success(data) = result else {
                if case let .failure(error) = result {
                    self.finish(.failure(error))
                }
                return
            }
            do {
                let locator = try Self.parseLocator(data)
                self.readContent(locator: locator)
            } catch let error as RemarkablePullError {
                self.finish(.failure(error))
            } catch {
                self.finish(.failure(.invalidDocumentLocator))
            }
        }
    }

    private func readContent(locator: Locator) {
        let command = "cat '\(Self.xochitlRoot)/\(locator.documentID).content'"
        run(stage: .content,
            remoteCommand: command,
            maximumOutputBytes: Self.contentOutputLimit) { result in
            switch result {
            case let .failure(error):
                self.finish(.failure(error))
            case let .success(data):
                do {
                    let selection = try Self.resolvePageSelection(
                        contentData: data,
                        locator: locator
                    )
                    self.readPageFirst(
                        documentID: locator.documentID,
                        selection: selection
                    )
                } catch let error as RemarkablePullError {
                    self.finish(.failure(error))
                } catch {
                    self.finish(.failure(.invalidDocumentContent))
                }
            }
        }
    }

    private func readPageFirst(documentID: String,
                               selection: PageSelection) {
        let command = Self.pageReadCommand(
            documentID: documentID,
            pageID: selection.pageID
        )
        run(stage: .firstPageRead,
            remoteCommand: command,
            maximumOutputBytes: Self.pageOutputLimit) { result in
            switch result {
            case let .failure(error):
                self.finish(.failure(error))
            case let .success(firstData):
                self.readPageSecond(
                    documentID: documentID,
                    selection: selection,
                    firstData: firstData
                )
            }
        }
    }

    private func readPageSecond(documentID: String,
                                selection: PageSelection,
                                firstData: Data) {
        let command = Self.pageReadCommand(
            documentID: documentID,
            pageID: selection.pageID
        )
        run(stage: .secondPageRead,
            remoteCommand: command,
            maximumOutputBytes: Self.pageOutputLimit) { result in
            switch result {
            case let .failure(error):
                self.finish(.failure(error))
            case let .success(secondData):
                guard firstData == secondData else {
                    self.finish(.failure(.pageChangedWhileReading))
                    return
                }
                self.exportPDF(
                    documentID: documentID,
                    selection: selection,
                    stablePageData: secondData,
                    attempt: 0
                )
            }
        }
    }

    private func exportPDF(documentID: String,
                           selection: PageSelection,
                           stablePageData: Data,
                           attempt: Int) {
        let command =
            "/usr/bin/wget -Y off -qO- "
            + "'http://10.11.99.1/download/\(documentID)/pdf'"
        run(stage: .pdfExport,
            remoteCommand: command,
            maximumOutputBytes: Self.pdfOutputLimit) { result in
            switch result {
            case let .failure(error):
                guard error == .remoteDataUnavailable(.pdfExport)
                        || error == .remoteCommandFailed(.pdfExport) else {
                    self.finish(.failure(error))
                    return
                }
                self.retryPDFExport(
                    documentID: documentID,
                    selection: selection,
                    stablePageData: stablePageData,
                    attempt: attempt,
                    finalError: .pdfExportUnavailable
                )
            case let .success(pdfData):
                guard self.pdfValidator(
                    pdfData,
                    selection.pageIndex,
                    selection.pageCount
                ) else {
                    self.retryPDFExport(
                        documentID: documentID,
                        selection: selection,
                        stablePageData: stablePageData,
                        attempt: attempt,
                        finalError: .invalidPDFExport
                    )
                    return
                }
                self.revalidateLocator(
                    expectedDocumentID: documentID,
                    expectedSelection: selection,
                    stablePageData: stablePageData,
                    pdfData: pdfData
                )
            }
        }
    }

    private func retryPDFExport(documentID: String,
                                selection: PageSelection,
                                stablePageData: Data,
                                attempt: Int,
                                finalError: RemarkablePullError) {
        let nextAttempt = attempt + 1
        guard nextAttempt < Self.maximumPDFExportAttempts else {
            finish(.failure(finalError))
            return
        }
        let delay = Self.pdfExportRetryDelays[min(
            attempt,
            Self.pdfExportRetryDelays.count - 1
        )]
        guard deadline.timeIntervalSinceNow > delay else {
            finish(.failure(.timedOut))
            return
        }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.cancelled, !self.finished else { return }
            self.exportPDF(
                documentID: documentID,
                selection: selection,
                stablePageData: stablePageData,
                attempt: nextAttempt
            )
        }
    }

    private func revalidateLocator(expectedDocumentID: String,
                                   expectedSelection: PageSelection,
                                   stablePageData: Data,
                                   pdfData: Data) {
        run(stage: .locator,
            remoteCommand: Self.locateRecentlyOpenedDocumentCommand,
            maximumOutputBytes: Self.locatorOutputLimit) { result in
            switch result {
            case let .failure(error):
                self.finish(.failure(error))
            case let .success(data):
                do {
                    let locator = try Self.parseLocator(data)
                    guard locator.documentID == expectedDocumentID else {
                        self.finish(.failure(.pageChangedWhileReading))
                        return
                    }
                    self.revalidateContent(
                        locator: locator,
                        expectedSelection: expectedSelection,
                        stablePageData: stablePageData,
                        pdfData: pdfData
                    )
                } catch let error as RemarkablePullError {
                    self.finish(.failure(error))
                } catch {
                    self.finish(.failure(.invalidDocumentLocator))
                }
            }
        }
    }

    private func revalidateContent(locator: Locator,
                                   expectedSelection: PageSelection,
                                   stablePageData: Data,
                                   pdfData: Data) {
        let command =
            "cat '\(Self.xochitlRoot)/\(locator.documentID).content'"
        run(stage: .content,
            remoteCommand: command,
            maximumOutputBytes: Self.contentOutputLimit) { result in
            switch result {
            case let .failure(error):
                self.finish(.failure(error))
            case let .success(data):
                do {
                    let currentSelection = try Self.resolvePageSelection(
                        contentData: data,
                        locator: locator
                    )
                    guard currentSelection == expectedSelection else {
                        self.finish(.failure(.pageChangedWhileReading))
                        return
                    }
                    self.readPageFinal(
                        documentID: locator.documentID,
                        selection: currentSelection,
                        stablePageData: stablePageData,
                        pdfData: pdfData
                    )
                } catch let error as RemarkablePullError {
                    self.finish(.failure(error))
                } catch {
                    self.finish(.failure(.invalidDocumentContent))
                }
            }
        }
    }

    private func readPageFinal(documentID: String,
                               selection: PageSelection,
                               stablePageData: Data,
                               pdfData: Data) {
        let command = Self.pageReadCommand(
            documentID: documentID,
            pageID: selection.pageID
        )
        run(stage: .finalPageRead,
            remoteCommand: command,
            maximumOutputBytes: Self.pageOutputLimit) { result in
            switch result {
            case let .failure(error):
                self.finish(.failure(error))
            case let .success(finalData):
                guard finalData == stablePageData else {
                    self.finish(.failure(.pageChangedWhileReading))
                    return
                }
                self.finish(.success(RemarkablePageSnapshot(
                    documentID: documentID,
                    pageID: selection.pageID,
                    pageIndex: selection.pageIndex,
                    pageCount: selection.pageCount,
                    data: stablePageData,
                    pdfData: pdfData
                )))
            }
        }
    }

    private func run(stage: RemarkablePullStage,
                     remoteCommand: String,
                     maximumOutputBytes: Int,
                     completion: @escaping (Result<Data, RemarkablePullError>) -> Void) {
        guard !cancelled, !finished else { return }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            completion(.failure(.timedOut))
            return
        }

        let relay = RemarkableCancellationRelay()
        currentTask = relay
        var processEnvironment = environment
        var authenticationArguments = ["-o", "BatchMode=yes"]
        if let credentialURL = target.passwordCredentialURL {
            guard let askPassExecutableURL,
                  askPassExecutableURL.isFileURL,
                  askPassExecutableURL.path.hasPrefix("/") else {
                completion(.failure(.passwordAuthenticationUnavailable))
                return
            }
            authenticationArguments = [
                "-o", "BatchMode=no",
                "-o", "NumberOfPasswordPrompts=1",
                "-o", "PubkeyAuthentication=no",
                "-o",
                "PreferredAuthentications=keyboard-interactive,password",
            ]
            processEnvironment["SSH_ASKPASS"] = askPassExecutableURL.path
            processEnvironment["SSH_ASKPASS_REQUIRE"] = "force"
            // OpenSSH still checks DISPLAY on some macOS releases even when
            // SSH_ASKPASS_REQUIRE=force. This is a marker, not a socket target.
            processEnvironment["DISPLAY"] = "RimeBuffer:0"
            processEnvironment[
                RemarkableSSHAskPassHandler.requestEnvironmentKey
            ] = "1"
            processEnvironment[
                RemarkableSSHAskPassHandler.credentialPathEnvironmentKey
            ] = credentialURL.path
            processEnvironment[
                RemarkableSSHAskPassHandler.destinationEnvironmentKey
            ] = target.destination
        }
        let spec = AITextCLIProcessSpec(
            executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: [
                "-T",
            ] + authenticationArguments + [
                "-o", "StrictHostKeyChecking=yes",
                "-o", "ConnectTimeout=5",
                "-o", "ConnectionAttempts=1",
                "-o", "ClearAllForwardings=yes",
                "-o", "PermitLocalCommand=no",
                "--",
                target.destination,
                remoteCommand,
            ],
            standardInput: Data(),
            currentDirectoryURL: URL(fileURLWithPath: "/", isDirectory: true),
            environment: processEnvironment,
            timeout: remaining,
            maximumOutputBytes: maximumOutputBytes,
            maximumStandardErrorBytes: 8 * 1_024
        )
        let task = runner.run(spec, onStandardOutput: { _ in }) {
            [weak self, weak relay] result in
            self?.queue.async {
                guard let self, !self.cancelled, !self.finished else { return }
                if let relay, self.currentTask === relay {
                    self.currentTask = nil
                }
                if result.cancelled {
                    completion(.failure(.cancelled))
                } else if result.timedOut {
                    completion(.failure(.timedOut))
                } else if result.outputTooLarge {
                    completion(.failure(.outputTooLarge(stage)))
                } else if result.terminationStatus == -1 {
                    completion(.failure(.launchFailed))
                } else if result.terminationStatus != 0 {
                    completion(.failure(Self.classifySSHFailure(
                        terminationStatus: result.terminationStatus,
                        standardError: result.standardError,
                        stage: stage
                    )))
                } else {
                    completion(.success(result.standardOutput))
                }
            }
        }
        relay.install(task)
    }

    private static func classifySSHFailure(
        terminationStatus: Int32,
        standardError: Data,
        stage: RemarkablePullStage
    ) -> RemarkablePullError {
        guard terminationStatus == 255 else {
            return .remoteDataUnavailable(stage)
        }
        let message = String(
            decoding: standardError.prefix(8 * 1_024),
            as: UTF8.self
        ).lowercased()
        if message.contains("remote host identification has changed") {
            return .hostKeyChanged
        }
        if message.contains("host key verification failed")
            || (message.contains("host key is known")
                && message.contains("no ")) {
            return .hostKeyNotTrusted
        }
        if message.contains("permission denied")
            || message.contains("authentication failed")
            || message.contains("no supported authentication methods") {
            return .authenticationFailed
        }
        let connectionMarkers = [
            "connection refused",
            "connection reset",
            "connection closed",
            "could not resolve hostname",
            "name or service not known",
            "no route to host",
            "network is unreachable",
            "operation timed out",
            "connection timed out",
        ]
        if connectionMarkers.contains(where: message.contains) {
            return .connectionFailed
        }
        return .remoteCommandFailed(stage)
    }

    private func finish(_ result: Result<RemarkablePageSnapshot,
                                        RemarkablePullError>) {
        guard !finished else { return }
        finished = true
        watchdog?.cancel()
        watchdog = nil
        currentTask = nil
        completion(result)
    }

    private static func parseLocator(_ data: Data) throws -> Locator {
        guard !data.isEmpty else {
            throw RemarkablePullError.noRecentlyOpenedDocument
        }
        guard data.count <= locatorOutputLimit,
              let output = String(data: data, encoding: .utf8),
              !output.contains("\0") else {
            throw RemarkablePullError.invalidDocumentLocator
        }
        let line = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else {
            throw RemarkablePullError.noRecentlyOpenedDocument
        }
        let fields = line.split(separator: "\t",
                                maxSplits: 1,
                                omittingEmptySubsequences: false)
        guard fields.count == 2 else {
            throw RemarkablePullError.invalidDocumentLocator
        }
        let documentID = String(fields[0])
        guard isCanonicalUUID(documentID) else {
            throw RemarkablePullError.invalidDocumentLocator
        }

        let legacyValue = String(fields[1])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let legacyPageIndex: Int?
        let legacyPageID: String?
        if legacyValue.isEmpty {
            legacyPageIndex = nil
            legacyPageID = nil
        } else if let value = Int(legacyValue),
                  value >= 0,
                  value <= 100_000 {
            legacyPageIndex = value
            legacyPageID = nil
        } else if isCanonicalUUID(legacyValue) {
            legacyPageIndex = nil
            legacyPageID = legacyValue
        } else {
            throw RemarkablePullError.invalidDocumentLocator
        }
        return Locator(documentID: documentID,
                       legacyPageIndex: legacyPageIndex,
                       legacyPageID: legacyPageID)
    }

    private static func resolvePageSelection(
        contentData: Data,
        locator: Locator
    ) throws -> PageSelection {
        guard !contentData.isEmpty,
              contentData.count <= contentOutputLimit,
              let object = try? JSONSerialization.jsonObject(with: contentData),
              let content = object as? [String: Any] else {
            throw RemarkablePullError.invalidDocumentContent
        }

        if let modern = content["cPages"] as? [String: Any] {
            let pages = try pageIDs(from: modern["pages"])
            let lastOpenedValue = (modern["lastOpened"] as? [String: Any])?["value"]
            return try resolveSelection(
                pages: pages,
                preferredValue: lastOpenedValue,
                fallbackIndex: pageIndex(from: content["lastOpenedPage"])
                    ?? locator.legacyPageIndex,
                fallbackPageID: locator.legacyPageID
            )
        }

        let legacyPages = try pageIDs(from: content["pages"])
        return try resolveSelection(
            pages: legacyPages,
            preferredValue: nil,
            fallbackIndex: pageIndex(from: content["lastOpenedPage"])
                ?? locator.legacyPageIndex,
            fallbackPageID: locator.legacyPageID
        )
    }

    private static func resolveSelection(
        pages: [String],
        preferredValue: Any?,
        fallbackIndex: Int?,
        fallbackPageID: String?
    ) throws -> PageSelection {
        guard !pages.isEmpty else {
            throw RemarkablePullError.pageNotFound
        }
        if let pageID = pageID(from: preferredValue) {
            guard let index = pages.firstIndex(of: pageID) else {
                throw RemarkablePullError.pageMappingMismatch
            }
            return PageSelection(
                pageID: pageID,
                pageIndex: index,
                pageCount: pages.count
            )
        }
        if let index = pageIndex(from: preferredValue) {
            guard pages.indices.contains(index) else {
                throw RemarkablePullError.pageMappingMismatch
            }
            return PageSelection(
                pageID: pages[index],
                pageIndex: index,
                pageCount: pages.count
            )
        }
        if let fallbackIndex {
            guard pages.indices.contains(fallbackIndex) else {
                throw RemarkablePullError.pageMappingMismatch
            }
            return PageSelection(
                pageID: pages[fallbackIndex],
                pageIndex: fallbackIndex,
                pageCount: pages.count
            )
        }
        if let fallbackPageID {
            guard let index = pages.firstIndex(of: fallbackPageID) else {
                throw RemarkablePullError.pageMappingMismatch
            }
            return PageSelection(
                pageID: fallbackPageID,
                pageIndex: index,
                pageCount: pages.count
            )
        }
        if pages.count == 1 {
            return PageSelection(
                pageID: pages[0],
                pageIndex: 0,
                pageCount: 1
            )
        }
        throw RemarkablePullError.pageNotFound
    }

    private static func pageIDs(from value: Any?) throws -> [String] {
        guard let entries = value as? [Any],
              !entries.isEmpty,
              entries.count <= 100_000 else {
            throw RemarkablePullError.invalidDocumentContent
        }
        var pages: [String] = []
        pages.reserveCapacity(entries.count)
        for entry in entries {
            let candidate: String?
            if let stringID = entry as? String,
               isCanonicalUUID(stringID) {
                candidate = stringID
            } else if let dictionary = entry as? [String: Any],
                      let dictionaryID = dictionary["id"] as? String,
                      isCanonicalUUID(dictionaryID) {
                candidate = dictionaryID
            } else {
                candidate = nil
            }
            guard let candidate else {
                throw RemarkablePullError.invalidDocumentContent
            }
            pages.append(candidate)
        }
        guard Set(pages).count == pages.count else {
            throw RemarkablePullError.pageMappingMismatch
        }
        return pages
    }

    private static func pageID(from value: Any?) -> String? {
        guard let value = value as? String,
              isCanonicalUUID(value) else { return nil }
        return value
    }

    private static func pageIndex(from value: Any?) -> Int? {
        if let value = value as? Int, value >= 0, value <= 100_000 {
            return value
        }
        if let value = value as? NSNumber {
            let intValue = value.intValue
            guard value.doubleValue == Double(intValue),
                  intValue >= 0,
                  intValue <= 100_000 else { return nil }
            return intValue
        }
        if let value = value as? String,
           let index = Int(value),
           index >= 0,
           index <= 100_000 {
            return index
        }
        return nil
    }

    private static func pageReadCommand(documentID: String,
                                        pageID: String) -> String {
        // Both values have already passed `isCanonicalUUID`, so interpolating
        // them into this fixed path template cannot introduce shell syntax.
        "cat '\(xochitlRoot)/\(documentID)/\(pageID).rm'"
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#,
            options: .regularExpression
        ) != nil
    }
}

enum RemarkableWorkspacePhase: Equatable {
    case idle
    case running
    case succeeded
    case failed(String)
}

final class RemarkableWorkspace: BuiltInBufferActionWorkspace {
    static let shared = RemarkableWorkspace()
    static let pluginKey = PluginKey(domain: .builtIn,
                                     rawID: BuiltInPluginID.remarkable)

    var workspacePluginKey: PluginKey { Self.pluginKey }
    let workbenchDisplayName = "Remarkable"

    private struct PageRecognitionIdentity: Hashable {
        let sourceDestination: String
        let documentID: String
        let pageID: String
        let language: RemarkableOCRLanguageMode
    }

    private let defaults: UserDefaults
    private let credentialStore: RemarkableCredentialStore?
    private let bufferModel: BufferModel
    private let puller: any RemarkablePagePulling
    private let textRecognizer: any RemarkablePDFTextRecognizing
    private let notificationCenter: NotificationCenter
    private let selectionPredicate: () -> Bool
    private let secureInputEnabled: () -> Bool
    private var observers: [NSObjectProtocol] = []
    private var started = false
    private var ownerActive = false
    private var protectedSession = false
    private var generation: UInt64 = 0
    private var currentTask: (any AITextCancellable)?
    private var stagedDigests: [PageRecognitionIdentity: SHA256Digest] = [:]
    private var lastSucceededCharacterCount = 0
    private var lastStatusOverride: String?
    private(set) var phase: RemarkableWorkspacePhase = .idle

    init(defaults: UserDefaults = .standard,
         credentialStore: RemarkableCredentialStore? = .shared,
         bufferModel: BufferModel = .shared,
         puller: any RemarkablePagePulling = RemarkableSSHPagePuller(),
         textRecognizer: any RemarkablePDFTextRecognizing =
             RemarkableAppleVisionOCR(),
         notificationCenter: NotificationCenter = .default,
         isSelected: @escaping () -> Bool = {
             BufferPluginSelectionStore.shared.isSelected(RemarkableWorkspace.pluginKey)
         },
         secureInputEnabled: @escaping () -> Bool = {
             IsSecureEventInputEnabled()
         }) {
        self.defaults = defaults
        self.credentialStore = credentialStore
        self.bufferModel = bufferModel
        self.puller = puller
        self.textRecognizer = textRecognizer
        self.notificationCenter = notificationCenter
        selectionPredicate = isSelected
        self.secureInputEnabled = secureInputEnabled
    }

    var actionPresentation: BuiltInBufferActionPresentation {
        let status: String
        switch phase {
        case .idle:
            status = lastStatusOverride
                ?? "打开要识别的页面，然后在 Mac 本地识别手写内容"
        case .running:
            status = "正在导出当前页并在 Mac 本地识别"
        case .succeeded:
            status = lastStatusOverride
                ?? "本地识别已加入缓冲区（\(lastSucceededCharacterCount) 字，请核对）"
        case let .failed(message):
            status = message
        }
        let enabled = started
            && ownerActive
            && bufferModel.active
            && !protectedSession
            && !secureInputEnabled()
            && phase != .running
        return BuiltInBufferActionPresentation(
            title: phase == .running ? "识别中…" : "识别当前页",
            symbolName: phase == .running ? "hourglass" : "arrow.down.doc",
            statusText: status,
            toolTip: enabled
                ? "只读导出 reMarkable 当前页，并用 Apple Vision 在 Mac 本地识别"
                : status,
            isRunning: phase == .running,
            isEnabled: enabled
        )
    }

    var optionPresentation: BuiltInBufferActionOptionPresentation? {
        let selected = RemarkableOCRLanguageMode.configured(in: defaults)
        let enabled = started
            && ownerActive
            && bufferModel.active
            && !protectedSession
            && !secureInputEnabled()
        return BuiltInBufferActionOptionPresentation(
            options: RemarkableOCRLanguageMode.allCases.map {
                BuiltInBufferActionOption(
                    identifier: $0.rawValue,
                    title: $0.workbenchDisplayName
                )
            },
            selectedIdentifier: selected.rawValue,
            toolTip: "首选识别语言：\(selected.displayName)",
            isEnabled: enabled
        )
    }

    func start() {
        guard !started else { return }
        started = true
        observers.append(notificationCenter.addObserver(
            forName: .activeBufferPluginDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.setOwnerActive(self?.selectionPredicate() == true)
        })
        observers.append(notificationCenter.addObserver(
            forName: .remarkableConfigurationDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.started else { return }
            self.invalidate(nextPhase: .idle)
            self.notifyChange()
        })
        setOwnerActive(selectionPredicate())
    }

    func stop() {
        guard started else { return }
        started = false
        observers.forEach(notificationCenter.removeObserver)
        observers.removeAll()
        invalidate(nextPhase: .idle)
        ownerActive = false
        notifyChange()
    }

    @discardableResult
    func invoke() -> Bool {
        if secureInputEnabled() {
            setProtected(true)
            return false
        }
        guard started,
              ownerActive,
              bufferModel.active,
              !protectedSession,
              phase != .running else {
            return false
        }

        let target: RemarkableSSHTarget
        let language: RemarkableOCRLanguageMode
        do {
            if let credentialStore {
                target = try credentialStore.configuredTarget(
                    fallingBackTo: defaults
                )
            } else {
                target = try RemarkableSSHTarget.configured(in: defaults)
            }
            language = RemarkableOCRLanguageMode.configured(in: defaults)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? RemarkablePullError.invalidTarget.localizedDescription
            phase = .failed(message)
            lastStatusOverride = nil
            IMELog.write("remarkable pull rejected code=invalid-configuration")
            notifyChange()
            return false
        }

        generation &+= 1
        let jobGeneration = generation
        let requestStartedAt = ProcessInfo.processInfo.systemUptime
        phase = .running
        lastStatusOverride = nil
        notifyChange()
        IMELog.write("remarkable pull started")

        let relay = RemarkableCancellationRelay()
        currentTask = relay
        let task = puller.pullLatestPage(from: target) {
            [weak self, weak relay] result in
            guard let relay else { return }
            switch result {
            case let .failure(error):
                DispatchQueue.main.async {
                    self?.finishFailure(error,
                                        jobGeneration: jobGeneration,
                                        requestStartedAt: requestStartedAt,
                                        relay: relay)
                }
            case let .success(snapshot):
                // Hashing and Vision stay off the IMK/AppKit main thread. The
                // generation is revalidated on main before OCR starts and
                // again before any recognized text reaches BufferModel.
                DispatchQueue.global(qos: .userInitiated).async {
                    let digest = SHA256.hash(data: snapshot.data)
                    DispatchQueue.main.async {
                        self?.startRecognition(
                            snapshot,
                            digest: digest,
                            language: language,
                            target: target,
                            jobGeneration: jobGeneration,
                            requestStartedAt: requestStartedAt,
                            relay: relay
                        )
                    }
                }
            }
        }
        relay.install(task)
        return true
    }

    @discardableResult
    func requestRefresh() -> Bool {
        let available = started
            && ownerActive
            && bufferModel.active
            && !protectedSession
            && !secureInputEnabled()
        invalidate(nextPhase: .idle)
        notifyChange()
        return available
    }

    @discardableResult
    func selectOption(identifier: String) -> Bool {
        guard started,
              ownerActive,
              bufferModel.active,
              !protectedSession,
              !secureInputEnabled(),
              let language = RemarkableOCRLanguageMode(
                  rawValue: identifier
              ) else {
            return false
        }
        let previous = RemarkableOCRLanguageMode.configured(in: defaults)
        guard previous != language else { return true }

        // A workbench language switch is an explicit request to replace an
        // in-flight OCR interpretation. The configuration notification
        // tombstones the old result before a fresh pull can begin.
        let shouldRestartRecognition = phase == .running
        defaults.set(
            language.rawValue,
            forKey: RemarkableOCRLanguageMode.defaultsKey
        )
        notificationCenter.post(
            name: .remarkableConfigurationDidChange,
            object: self
        )
        notificationCenter.post(
            name: .pluginConfigurationDidChange,
            object: nil,
            userInfo: [
                PluginConfigurationNotificationKey.pluginID:
                    BuiltInPluginID.remarkable,
                PluginConfigurationNotificationKey.changedFieldIDs: [
                    RemarkablePluginConfigurationFieldID.ocrLanguage,
                ],
            ]
        )

        if shouldRestartRecognition {
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      RemarkableOCRLanguageMode.configured(
                          in: self.defaults
                      ) == language else {
                    return
                }
                _ = self.invoke()
            }
        }
        return true
    }

    func setOwnerActive(_ active: Bool) {
        guard ownerActive != active else { return }
        ownerActive = active
        if !active {
            invalidate(nextPhase: .idle)
        }
        notifyChange()
    }

    func setProtected(_ protected: Bool) {
        guard protectedSession != protected else { return }
        protectedSession = protected
        if protected {
            invalidate(nextPhase: .idle)
        }
        notifyChange()
    }

    func workbenchWillPause() {
        invalidate(nextPhase: .idle)
        notifyChange()
    }

    private func accepts(jobGeneration: UInt64,
                         relay: RemarkableCancellationRelay) -> Bool {
        guard started,
              ownerActive,
              !protectedSession,
              generation == jobGeneration,
              currentTask === relay,
              phase == .running else {
            return false
        }
        if secureInputEnabled() {
            protectedSession = true
            invalidate(nextPhase: .idle)
            notifyChange()
            return false
        }
        guard bufferModel.active else {
            invalidate(nextPhase: .idle)
            notifyChange()
            return false
        }
        return true
    }

    private func finishFailure(_ error: RemarkablePullError,
                               jobGeneration: UInt64,
                               requestStartedAt: TimeInterval,
                               relay: RemarkableCancellationRelay) {
        guard accepts(jobGeneration: jobGeneration, relay: relay) else {
            return
        }
        currentTask = nil
        phase = .failed(error.localizedDescription)
        lastStatusOverride = nil
        IMELog.write(
            "remarkable pull failed code=\(error.logCode) "
                + "totalMs=\(Self.elapsedMilliseconds(since: requestStartedAt))"
        )
        notifyChange()
    }

    private func startRecognition(_ snapshot: RemarkablePageSnapshot,
                                  digest: SHA256Digest,
                                  language: RemarkableOCRLanguageMode,
                                  target: RemarkableSSHTarget,
                                  jobGeneration: UInt64,
                                  requestStartedAt: TimeInterval,
                                  relay: RemarkableCancellationRelay) {
        guard accepts(jobGeneration: jobGeneration, relay: relay) else {
            return
        }

        let identity = PageRecognitionIdentity(
            sourceDestination: target.destination,
            documentID: snapshot.documentID,
            pageID: snapshot.pageID,
            language: language
        )
        if stagedDigests[identity] == digest {
            currentTask = nil
            phase = .succeeded
            lastStatusOverride = "这一页没有变化，未重复加入缓冲区"
            IMELog.write(
                "remarkable pull duplicate bytes=\(snapshot.data.count) "
                    + "totalMs="
                    + "\(Self.elapsedMilliseconds(since: requestStartedAt))"
            )
            notifyChange()
            return
        }

        let recognitionStartedAt = ProcessInfo.processInfo.systemUptime
        let task = textRecognizer.recognizeText(
            in: snapshot.pdfData,
            pageIndex: snapshot.pageIndex,
            expectedPageCount: snapshot.pageCount,
            language: language
        ) { [weak self, weak relay] result in
            guard let relay else { return }
            DispatchQueue.main.async {
                self?.finishRecognition(
                    snapshot,
                    digest: digest,
                    result: result,
                    language: language,
                    target: target,
                    jobGeneration: jobGeneration,
                    requestStartedAt: requestStartedAt,
                    recognitionStartedAt: recognitionStartedAt,
                    relay: relay
                )
            }
        }
        relay.install(task)
    }

    private func finishRecognition(
        _ snapshot: RemarkablePageSnapshot,
        digest: SHA256Digest,
        result: Result<RemarkableOCRResult, RemarkableLocalOCRError>,
        language: RemarkableOCRLanguageMode,
        target: RemarkableSSHTarget,
        jobGeneration: UInt64,
        requestStartedAt: TimeInterval,
        recognitionStartedAt: TimeInterval,
        relay: RemarkableCancellationRelay
    ) {
        guard accepts(jobGeneration: jobGeneration, relay: relay) else {
            return
        }
        currentTask = nil
        guard case let .success(recognition) = result else {
            let error: RemarkableLocalOCRError
            if case let .failure(recognitionError) = result {
                error = recognitionError
            } else {
                error = .recognitionFailed
            }
            phase = .failed(error.localizedDescription)
            lastStatusOverride = nil
            IMELog.write(
                "remarkable local ocr failed code=\(error.logCode) "
                    + "pageBytes=\(snapshot.data.count) "
                    + "pdfBytes=\(snapshot.pdfData.count) "
                    + "ocrMs="
                    + "\(Self.elapsedMilliseconds(since: recognitionStartedAt)) "
                    + "totalMs="
                    + "\(Self.elapsedMilliseconds(since: requestStartedAt))"
            )
            notifyChange()
            return
        }
        let text = recognition.text
        let recognitionValidationError: RemarkableLocalOCRError?
        if text.utf8.count > RemarkableAppleVisionOCR.maximumOutputBytes {
            recognitionValidationError = .outputTooLarge
        } else if text.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty || text.unicodeScalars.contains(where: {
            $0.value == 0
        }) {
            recognitionValidationError = .invalidText
        } else {
            recognitionValidationError = nil
        }
        if let recognitionValidationError {
            phase = .failed(recognitionValidationError.localizedDescription)
            lastStatusOverride = nil
            IMELog.write(
                "remarkable local ocr rejected code="
                    + "\(recognitionValidationError.logCode) "
                    + "pageBytes=\(snapshot.data.count) "
                    + "pdfBytes=\(snapshot.pdfData.count) "
                    + "ocrMs="
                    + "\(Self.elapsedMilliseconds(since: recognitionStartedAt)) "
                    + "totalMs="
                    + "\(Self.elapsedMilliseconds(since: requestStartedAt))"
            )
            notifyChange()
            return
        }
        bufferModel.stageExternalSemantic(
            text,
            origin: .ssh(host: target.destination)
        )
        let identity = PageRecognitionIdentity(
            sourceDestination: target.destination,
            documentID: snapshot.documentID,
            pageID: snapshot.pageID,
            language: language
        )
        stagedDigests[identity] = digest
        lastSucceededCharacterCount = text.count
        lastStatusOverride = nil
        phase = .succeeded
        let confidence = recognition.meanConfidence.map {
            String(format: "%.3f", Double($0))
        } ?? "none"
        IMELog.write(
            "remarkable local ocr succeeded "
                + "pageBytes=\(snapshot.data.count) "
                + "pdfBytes=\(snapshot.pdfData.count) "
                + "observations=\(recognition.observationCount) "
                + "confidence=\(confidence) characters=\(text.count) "
                + "ocrMs="
                + "\(Self.elapsedMilliseconds(since: recognitionStartedAt)) "
                + "totalMs="
                + "\(Self.elapsedMilliseconds(since: requestStartedAt))"
        )
        notifyChange()
    }

    private static func elapsedMilliseconds(
        since start: TimeInterval
    ) -> Int {
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - start)
        return Int((elapsed * 1_000).rounded())
    }

    private func invalidate(nextPhase: RemarkableWorkspacePhase) {
        generation &+= 1
        currentTask?.cancel()
        currentTask = nil
        phase = nextPhase
        lastStatusOverride = nil
    }

    private func notifyChange() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.notifyChange() }
            return
        }
        notificationCenter.post(
            name: .builtInBufferActionWorkspaceDidChange,
            object: self
        )
    }
}
