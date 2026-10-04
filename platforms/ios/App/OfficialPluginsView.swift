import SwiftUI
import RimesCore

struct OfficialPluginsView: View {
    @State private var store: OfficialPluginStore?
    @State private var revision = 0
    @State private var installing: String?
    @State private var error: String?
    var body: some View {
        let _ = revision
        List {
            if let store {
                ForEach(store.entries) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L(entry.nameZH, entry.nameEN)).font(.headline)
                            Spacer()
                            Text(entry.version).font(.caption).foregroundStyle(.secondary)
                        }
                        if store.state(entry.id)?.installed == true {
                            Toggle(L("启用", "Enabled"), isOn: Binding(get: {
                                _ = revision
                                return store.state(entry.id)?.enabled == true
                            }, set: { enabled in
                                change { try store.setEnabled(enabled, id: entry.id) }
                            }))
                            Button(L("卸载", "Uninstall"), role: .destructive) {
                                change { try store.uninstall(entry.id) }
                            }
                        } else {
                            Button {
                                installing = entry.id
                                Task { @MainActor in
                                    defer { installing = nil; revision += 1 }
                                    do { try await store.install(entry.id) } catch { self.error = error.localizedDescription }
                                }
                            } label: {
                                if installing == entry.id { ProgressView() }
                                else { Text(entry.platforms["ios"]?.distribution == "bundled" ? L("恢复安装", "Restore") : L("下载安装", "Download")) }
                            }.disabled(installing != nil)
                        }
                    }.padding(.vertical, 4)
                }
                Section { Text(L("下载后默认停用。启用插件不会自动选择它或发送原文；卸载保留你的配置、词库和文档。", "Downloads start disabled. Enabling a plugin does not select it or send text. Uninstalling keeps settings, dictionaries and documents.")).font(.footnote).foregroundStyle(.secondary) }
            }
        }.navigationTitle(L("官方插件", "Official plugins"))
        .task {
            do { let store = try MobileOfficialPlugins.makeStore(); try store.bootstrap(); self.store = store }
            catch { self.error = error.localizedDescription }
        }
        .alert(L("插件操作未完成", "Plugin operation failed"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
    private func change(_ action: () throws -> Void) {
        do { try action(); revision += 1 } catch { self.error = error.localizedDescription }
    }
}
