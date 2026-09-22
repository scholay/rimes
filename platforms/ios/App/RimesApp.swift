import SwiftUI
import UniformTypeIdentifiers
import RimesCore

@main
struct RimesApp: App {
    @StateObject private var model = SettingsModel()
    var body: some Scene { WindowGroup { HomeView().environmentObject(model).tint(.teal).task {
        #if DEBUG
        await DevelopmentSmoke.runIfRequested()
        #endif
    } } }
}
@MainActor final class SettingsModel: ObservableObject {
    @Published var value = ConfigurationStore().load()
    @Published var error: String?
    func save() { do { try ConfigurationStore().save(value) } catch { self.error = error.localizedDescription } }
}
struct HomeView: View {
    @EnvironmentObject private var model: SettingsModel
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("RIMES").font(.system(size: 38, weight: .bold, design: .rounded))
                        Text(L("把想法，写得顺一点。", "A little more flow, in every word.")).font(.title3)
                        Text(L("离线中文输入 · 滑动并击 · 可选 AI", "Offline Chinese · Slide chords · Optional AI")).font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 16)
                }.listRowBackground(Color.teal.opacity(0.08))
                Section(L("开始使用", "Get started")) {
                    NavigationLink { SetupView() } label: { Label(L("启用 RIMES 键盘", "Enable RIMES keyboard"), systemImage: "keyboard") }
                    NavigationLink { PlaygroundView() } label: { Label(L("输入体验", "Try typing"), systemImage: "square.and.pencil") }
                }
                Section(L("你的输入方式", "Your typing")) {
                    Picker(L("默认方案", "Default scheme"), selection: $model.value.scheme) { ForEach(InputScheme.allCases) { Text($0.title).tag($0) } }.onChange(of: model.value.scheme) { _,_ in model.value.schemeSelectionRevision = UUID(); model.save() }
                    NavigationLink { ChordProfilesView() } label: { Label(L("滑动并击与键位", "Slide chords & mappings"), systemImage: "hand.draw") }
                    NavigationLink { TranslationSetupView() } label: { Label(L("苹果翻译语言包", "Apple translation languages"), systemImage: "translate") }
                    NavigationLink { ProvidersView() } label: { Label(L("AI 服务", "AI services"), systemImage: "sparkles") }
                }
                Section {
                    NavigationLink(L("隐私与第三方许可", "Privacy & licenses")) { PrivacyView() }
                    Text("RIMES " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")).font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle(L("欢迎", "Welcome"))
            .alert(L("无法保存", "Could not save"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        }
    }
}
struct SetupView: View {
    var body: some View {
        List {
            Section(L("添加键盘", "Add the keyboard")) {
                Text(L("1. 打开系统设置 → 通用 → 键盘 → 键盘。\n2. 点击“添加新键盘”，选择 RIMES。\n3. 回到输入框，长按地球按钮切换至 RIMES。", "1. Open Settings → General → Keyboard → Keyboards.\n2. Tap Add New Keyboard and choose RIMES.\n3. In a text field, hold the globe key and choose RIMES."))
                Button(L("打开设置", "Open Settings")) { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            }
            Section(L("完全访问是可选的", "Full Access is optional")) {
                Text(L("普通输入与 Buffer 可以离线使用。只有键盘内 AI 需要完全访问；AI 还会在发送前单独征求同意。", "Typing and Buffer work offline. Only AI in the keyboard needs Full Access; sending text also requires separate consent."))
                Text(L("密码等安全输入框、禁止第三方键盘的 App 将使用系统键盘。", "Secure fields and apps that disallow third-party keyboards use the system keyboard."))
            }
        }.navigationTitle(L("启用键盘", "Enable keyboard"))
    }
}
struct PlaygroundView: View {
    @State private var text = ""
    @State private var second = ""
    var body: some View {
        Form {
            Section(L("使用系统地球键切换至 RIMES", "Switch to RIMES using the globe key")) { TextEditor(text: $text).frame(minHeight: 170).accessibilityIdentifier("playground.primary") }
            Section(L("另一个输入框", "Another field")) { TextField(L("测试切换输入目标", "Test switching fields"), text: $second).accessibilityIdentifier("playground.secondary") }
            #if DEBUG
            NavigationLink(L("本地引擎检查", "Local engine check")) { EngineCheckView() }
            #endif
        }.navigationTitle(L("输入体验", "Try typing"))
    }
}
struct EngineCheckView: View {
    @State private var text = "nihao"
    @State private var scheme: InputScheme = .pinyin
    @State private var candidates = [String]()
    private let engine = MobileEngine()
    var body: some View {
        Form {
            Picker("Scheme", selection: $scheme) { ForEach([InputScheme.pinyin,.ziranma,.wubi86]) { Text($0.title).tag($0) } }
            TextField("Code",text:$text).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button(L("检查候选", "Check candidates")) {
                guard engine.select(schema: scheme.schemaID) else { candidates = ["Engine unavailable"]; return }
                var snapshot = EngineSnapshot(); for c in text.unicodeScalars { snapshot = engine.process(key: Int32(c.value)) }; candidates = snapshot.candidates
            }
            ForEach(Array(candidates.enumerated()),id:\.offset) { Text($0.element) }
        }.navigationTitle(L("引擎检查", "Engine check"))
    }
}
struct ProvidersView: View {
    @EnvironmentObject private var model: SettingsModel
    @State private var editing: ProviderConfiguration?
    var body: some View {
        List {
            Section {
                ForEach(model.value.providers) { p in
                    Button { editing = p } label: { HStack { VStack(alignment:.leading) { Text(p.name); Text(p.model).font(.caption).foregroundStyle(.secondary) }; Spacer(); if model.value.selectedProvider == p.id { Image(systemName:"checkmark.circle.fill") } } }
                    .swipeActions { Button(role:.destructive) { do { try KeychainStore().delete(p.id); model.value.providers.removeAll { $0.id == p.id }; if model.value.selectedProvider == p.id { model.value.selectedProvider = nil }; model.save() } catch { model.error = error.localizedDescription } } label: { Label("Delete",systemImage:"trash") } }
                }
                Button { editing = ProviderConfiguration() } label: { Label(L("添加服务", "Add service"),systemImage:"plus") }
            } footer: { Text(L("使用自己的 API Key。支持 HTTPS OpenAI 兼容 Chat Completions 接口。Key 仅保存在本设备 Keychain。", "Bring your own API key. Supports HTTPS OpenAI-compatible Chat Completions. Keys stay in this device's Keychain.")) }
        }.navigationTitle(L("AI 服务", "AI services"))
        .sheet(item:$editing) { ProviderEditor(provider:$0).environmentObject(model) }
    }
}
struct ProviderEditor: View {
    @EnvironmentObject private var model: SettingsModel
    @Environment(\.dismiss) private var dismiss
    @State var provider: ProviderConfiguration
    @State private var key = ""
    @State private var consent = false
    @State private var models = [String]()
    @State private var message = ""
    @State private var probing = false
    var body: some View {
        NavigationStack {
            Form {
                Section(L("连接信息", "Connection")) {
                    TextField(L("名称", "Name"),text:$provider.name)
                    TextField("https://api.example.com/v1",text:$provider.baseURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().onChange(of:provider.baseURL) { _,_ in consent = false }
                    SecureField("API Key",text:$key).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Model ID",text:$provider.model).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(probing ? L("查询中…", "Loading…") : L("查询模型列表", "Fetch models")) {
                        probing = true; message = ""
                        Task { do { models = try await AIClient().models(provider:provider,key:key); message = models.isEmpty ? L("列表为空，可手动填写模型 ID", "No models returned; enter a model ID manually") : "" } catch { message = L("查询失败，可手动填写模型 ID", "Lookup failed; enter a model ID manually") }; probing = false }
                    }.disabled(probing || key.isEmpty || (try? provider.endpoint("models")) == nil)
                    Text(L("查询模型列表会将 API Key 发送到上方地址，不发送 Buffer 文本。查询失败不影响手动填写和保存。", "Fetching models sends the API key to the address above, without Buffer text. You can enter and save a model ID even if lookup fails.")).font(.caption).foregroundStyle(.secondary)
                    if !models.isEmpty { Picker("Models",selection:$provider.model) { Text(provider.model).tag(provider.model); ForEach(models.filter { $0 != provider.model },id:\.self) { Text($0).tag($0) } } }
                }
                Section(L("发送许可", "Sending permission")) {
                    Text(provider.consentIdentity.isEmpty ? L("填写有效地址后显示接收方", "Enter a valid endpoint to see the recipient") : provider.consentIdentity).font(.caption).textSelection(.enabled)
                    Toggle(L("允许将主动提交的 Buffer 文本发送到此服务", "Allow explicitly submitted Buffer text to be sent to this service"),isOn:$consent)
                    Text(L("不会自动发送打字记录、宿主全文或剪贴板。服务方的数据处理政策适用；不同意也可以保存配置并使用离线输入。", "No typing history, host documents or clipboard are sent automatically. The provider's data policy applies. You may save without consent and keep typing offline.")).font(.caption)
                }
                if !message.isEmpty { Text(message).foregroundStyle(.red) }
            }.navigationTitle(L("AI 配置", "AI configuration"))
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button(L("取消", "Cancel")) { dismiss() } }; ToolbarItem(placement:.confirmationAction) { Button(L("保存并选用", "Save & select")) { save() } } }
            .onAppear { do { key = try KeychainStore().read(provider.id); consent = model.value.consents.contains(provider.consentIdentity) } catch { message = L("无法读取密钥", "Could not read key") } }
        }
    }
    private func save() {
        do {
            _ = try provider.endpoint("chat/completions")
            guard !provider.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, !provider.model.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { message = L("请填写名称和模型 ID", "Enter a name and model ID"); return }
            try KeychainStore().save(key,id:provider.id)
            var next = model.value
            let old = next.providers.first { $0.id == provider.id }
            next.providers.removeAll { $0.id == provider.id }; next.providers.append(provider); next.selectedProvider = provider.id
            if let old { next.consents.removeAll { $0 == old.consentIdentity } }
            if consent { next.consents.append(provider.consentIdentity) }
            try ConfigurationStore().save(next); model.value = next; dismiss()
        } catch { message = error.localizedDescription }
    }
}
struct ChordProfilesView: View {
    @EnvironmentObject private var model: SettingsModel
    @State private var importing = false
    @State private var editing: ChordProfile?
    var body: some View {
        List {
            Section { Text(L("每手：起点＋终点。途中经过的键不计入；双手全部松开时提交。划回起点恢复单键。", "Each hand selects start + end. Passed keys do not count. Release both hands to submit; return to the start for a single key.")) }
            Section(L("当前方案", "Active profile")) {
                ForEach([ChordProfile.builtIn] + model.value.profiles) { p in
                    HStack { Button(p.id == ChordProfile.builtIn.id ? L("默认并击", "Default chord") : p.name) { model.value.chord = p; model.save() }; Spacer(); if model.value.chord.id == p.id { Image(systemName:"checkmark").foregroundStyle(.teal) }; Button { editing = p.id == "builtin.flyyao" ? p.copy() : p } label: { Image(systemName:"pencil") } }
                    .contextMenu { Button(L("复制方案", "Duplicate profile")) { editing = p.copy() } }
                }
            }
            Button(L("复制默认并击", "Copy default chord")) { editing = ChordProfile.builtIn.copy() }
            Button(L("导入 JSON", "Import JSON")) { importing = true }
        }.navigationTitle(L("滑动并击", "Slide chords"))
        .fileImporter(isPresented:$importing,allowedContentTypes:[.json]) { result in
            do { let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }; editing = try ChordProfile.imported(Data(contentsOf:url,options:.mappedIfSafe)) } catch { model.error = error.localizedDescription }
        }.sheet(item:$editing) { ChordEditor(profile:$0).environmentObject(model) }
    }
}
struct JSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(_ data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents:data) }
}
struct ChordEditor: View {
    @EnvironmentObject private var model: SettingsModel
    @Environment(\.dismiss) private var dismiss
    @State var profile: ChordProfile
    @State private var search = ""
    @State private var message = ""
    @State private var exporting = false
    @State private var document = JSONDocument(Data())
    var body: some View {
        NavigationStack {
            Form {
                TextField(L("名称", "Name"),text:$profile.name)
                TextField(L("左区字母", "Left keys"),text:$profile.leftKeys).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField(L("右区字母", "Right keys"),text:$profile.rightKeys).textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker(L("输出编码", "Output encoding"),selection:$profile.outputEncoding) { Text("全拼").tag(ChordOutputEncoding.fullPinyin); Text("自然码").tag(ChordOutputEncoding.ziranma) }
                Picker(L("音节边界", "Syllable boundaries"),selection:$profile.boundaryPolicy) { Text(L("每批次", "Each batch")).tag(ChordBoundaryPolicy.legacyBatches); Text(L("按映射类型", "By mapping kind")).tag(ChordBoundaryPolicy.explicitSyllables) }
                Section(L("映射", "Mappings")) {
                    TextField(L("查找键或拼音", "Find keys or pinyin"),text:$search).textInputAutocapitalization(.never)
                    ForEach(profile.mappings.indices.filter { search.isEmpty || profile.mappings[$0].keys.contains(search) || profile.mappings[$0].output.contains(search) },id:\.self) { i in
                        HStack {
                            TextField("keys",text:$profile.mappings[i].keys).frame(width:65)
                            TextField("pinyin",text:$profile.mappings[i].output)
                            Picker("Kind",selection:$profile.mappings[i].kind) { Text(L("音节", "Syllable")).tag(ChordMappingKind.syllable); Text(L("片段", "Fragment")).tag(ChordMappingKind.fragment) }.labelsHidden()
                        }.textInputAutocapitalization(.never).autocorrectionDisabled()
                    }.onDelete { offsets in let indices = profile.mappings.indices.filter { search.isEmpty || profile.mappings[$0].keys.contains(search) || profile.mappings[$0].output.contains(search) }; for i in offsets.map({ indices[$0] }).sorted(by:>) { profile.mappings.remove(at:i) } }
                    Button(L("添加映射", "Add mapping")) { profile.mappings.append(.init(keys:"",output:"",kind:.syllable)); search = "" }
                }
                Button(L("导出 JSON", "Export JSON")) { do { _ = try profile.validated(); document = JSONDocument(try JSONEncoder().encode(profile)); exporting = true } catch { message = error.localizedDescription } }
                Button(L("另存为副本", "Save a copy")) { profile = profile.copy(); message = L("已创建副本，点击“保存并应用”完成。", "Copy created. Choose Save & apply to keep it.") }
                if !message.isEmpty { Text(message).foregroundStyle(.red) }
            }.navigationTitle(L("键位方案", "Chord profile"))
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button(L("取消", "Cancel")) { dismiss() } }; ToolbarItem(placement:.confirmationAction) { Button(L("保存并应用", "Save & apply")) { do { profile = try profile.validated(); var next = model.value; next.profiles.removeAll { $0.id == profile.id }; next.profiles.append(profile); next.chord = profile; try ConfigurationStore().save(next); model.value = next; dismiss() } catch { message = error.localizedDescription } } } }
            .fileExporter(isPresented:$exporting,document:document,contentType:.json,defaultFilename:"rimes-chord") { _ in }
        }
    }
}
struct PrivacyView: View {
    var body: some View {
        List {
            Section(L("本机输入", "On-device typing")) { Text(L("词频只保存在设备。无账户、遥测或输入正文日志。Buffer 草稿不会落盘；键盘会话结束时清除。", "Learning stays on your device. No account, telemetry or text logs. Buffer drafts are not saved to disk and are cleared when the keyboard session ends.")) }
            Section("AI") { Text(L("只发送你主动提交的 Buffer 文本到你配置并同意的服务；API Key 保存在仅限本设备的 Keychain 中。请求不会跟随重定向。", "Only explicitly submitted Buffer text goes to your configured, consented service. API keys stay in this device's Keychain. Requests never follow redirects.")) }
            Section(L("苹果翻译", "Apple translation")) { Text(L("翻译在设备上使用已下载的苹果语言模型。下载语言包可能需要联网；翻译不可用时不会自动改用 AI 服务。", "Translation uses downloaded Apple language models on your device. Preparing languages may need a network connection. Unavailable translations never fall back to an AI service automatically.")) }
            Section {
                Link(L("隐私政策", "Privacy policy"), destination: URL(string: "https://scholay.github.io/rimes/ios/privacy/")!)
                Link(L("使用帮助与联系", "Help & contact"), destination: URL(string: "https://scholay.github.io/rimes/ios/support/")!)
            }
            Section(L("第三方声明", "Third-party notices")) { Text(Bundle.main.url(forResource:"THIRD_PARTY",withExtension:"txt").flatMap { try? String(contentsOf:$0,encoding:.utf8) } ?? L("许可文件缺失", "License file missing")).font(.caption).textSelection(.enabled) }
        }.navigationTitle(L("隐私与许可", "Privacy & licenses"))
    }
}
