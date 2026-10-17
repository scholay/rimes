#include "official_catalog.hpp"
#include "official_plugin_catalog.hpp"

namespace rimes::plugins {
std::map<std::string, Descriptor> CompiledAdapters() {
    // An entry is added only with its native implementation and acceptance
    // tests. Platform declarations are a separate required gate in PackageStore.
    return {{"builtin.capsule.notes", {"builtin.capsule.notes", "笔记", "1.1.0",
        Kind::Capsule, {"capsule.navigate"}}},
        {"builtin.apple-translation", {"builtin.apple-translation", "实时翻译", "2.3.0",
        Kind::Buffer, {"buffer.read", "translation.generate"}}}};
}
Json OfficialCatalog() { return Json::parse(linuxruntime::official::kCatalogJSON); }
std::map<std::string, std::string> BundledPackages() {
    std::map<std::string, std::string> result;
    for (const auto& entry : linuxruntime::official::kPackages) result.emplace(entry.id, entry.bytes);
    return result;
}
} // namespace rimes::plugins
