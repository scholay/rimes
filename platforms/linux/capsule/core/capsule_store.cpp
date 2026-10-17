#include "capsule_store.hpp"

#include <algorithm>
#include <cctype>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <fstream>
#include <sstream>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

#include "buffer_protocol.hpp"
#include "capsule_hash.hpp"
#include "private_files.hpp"
#include <array>
#include <set>

namespace rimes::capsule {
namespace {

StoreStatus IoFail(std::string* error, const std::string& message) {
    if (error != nullptr) {
        *error = message;
    }
    return StoreStatus::Io;
}

StoreStatus InvalidFail(std::string* error, const std::string& message) {
    if (error != nullptr) {
        *error = message;
    }
    return StoreStatus::Invalid;
}

bool IsRetiredRaw(std::string_view raw) {
    return raw == "prompt" || raw == "memory" || raw == "url";
}

std::string Trim(std::string_view text) {
    std::size_t begin = 0;
    while (begin < text.size() &&
           std::isspace(static_cast<unsigned char>(text[begin])) != 0) {
        ++begin;
    }
    std::size_t end = text.size();
    while (end > begin && std::isspace(static_cast<unsigned char>(text[end - 1])) != 0) {
        --end;
    }
    return std::string(text.substr(begin, end - begin));
}

}  // namespace

std::string JsonQuote(std::string_view text) {
    return rimes::buffer::JsonEscape(text);
}

bool JsonUnquote(std::string_view text, std::string* out) {
    const auto trimmed = Trim(text);
    if (trimmed.size() < 2 || trimmed.front() != '"' || trimmed.back() != '"') {
        return false;
    }
    return rimes::buffer::JsonUnescape(trimmed.substr(1, trimmed.size() - 2), out);
}

Module RecordModule(const Record& record) {
    switch (record.kind) {
    case Kind::Image: case Kind::Video: return Module::Capture;
    case Kind::Pdf: case Kind::Skill: case Kind::Resource: return Module::Resources;
    case Kind::Password: return Module::Passwords;
    default: return Module::Notes;
    }
}
std::string RecordFilter(const Record& record) {
    switch (record.kind) {
    case Kind::Note: return record.note_format == "bullet" ? "bullet" : record.note_format == "rich-text" ? "richText" : "other";
    case Kind::Image: return "image";
    case Kind::Video: return "video";
    case Kind::Pdf: return "reference";
    case Kind::Skill: return "skills";
    case Kind::Resource: return record.resource_type == "document" || record.resource_type == "project" ? record.resource_type : "other";
    default: return "other";
    }
}
std::string RenderMarkdown(const Record& record) {
    std::ostringstream out;
    out << "---\n" << "capsule: " << KindRaw(record.kind) << "\nversion: 1\n"
        << "id: " << JsonQuote(record.id) << "\ntitle: " << JsonQuote(record.title)
        << "\nupdated_at: " << JsonQuote(record.updated_at) << '\n';
    if (!record.summary.empty()) out << "summary: " << JsonQuote(record.summary) << '\n';
    if (record.kind == Kind::Note) out << "capsule_note_format: " << JsonQuote(record.note_format) << '\n';
    if (record.kind == Kind::Resource) out << "capsule_resource_type: " << JsonQuote(record.resource_type) << '\n';
    if (!record.attachment.empty()) out << "capsule_linux_asset: " << JsonQuote(record.attachment) << '\n';
    for (const auto& line : record.extra_header) out << line << '\n';
    out << "---\n\n" << record.content;
    return out.str();
}

bool ParseMarkdown(std::string_view text, Record* out, std::string* error) {
    if (out == nullptr) {
        return false;
    }
    *out = Record{};
    const auto start = text.find("---");
    if (start != 0 || (text.substr(0,4) != "---\n" && text.substr(0,5) != "---\r\n")) {
        if (error != nullptr) {
            *error = "missing front matter";
        }
        return false;
    }
    const auto end = text.find("\n---", 3);
    if (end == std::string_view::npos ||
        (text.substr(end + 4,1) != "\n" && text.substr(end + 4,2) != "\r\n")) {
        if (error != nullptr) {
            *error = "unterminated front matter";
        }
        return false;
    }
    const auto header = text.substr(3, end - 3);
    std::string kind_raw;
    std::string version;
    std::string id;
    std::string title;
    std::string updated;
    std::istringstream lines{std::string(header)};
    std::string line;
    std::set<std::string> keys;
    while (std::getline(lines, line)) {
        if (!line.empty() && line.back() == '\r') {
            line.pop_back();
        }
        if (Trim(line).empty()) continue;
        const auto colon = line.find(':');
        if (colon == std::string::npos) {
            out->extra_header.push_back(line);
            continue;
        }
        const auto key = Trim(line.substr(0, colon));
        const auto value = Trim(line.substr(colon + 1));
        if (!keys.insert(key).second) { if (error) *error = "duplicate header key"; return false; }
        auto scalar = [&] { std::string decoded; return JsonUnquote(value, &decoded) ? decoded : value; };
        if (key == "capsule") {
            kind_raw = value;
        } else if (key == "version") {
            version = value;
        } else if (key == "id") {
            if (!JsonUnquote(value, &id)) {
                id = value;
            }
        } else if (key == "title") {
            if (!JsonUnquote(value, &title)) {
                title = value;
            }
        } else if (key == "updated_at") {
            if (!JsonUnquote(value, &updated)) {
                updated = value;
            }
        } else if (key == "summary") out->summary = scalar();
        else if (key == "capsule_note_format") out->note_format = scalar();
        else if (key == "capsule_resource_type") out->resource_type = scalar();
        else if (key == "capsule_linux_asset") out->attachment = scalar();
        else out->extra_header.push_back(line);
    }
    if (IsRetiredRaw(kind_raw)) {
        if (error != nullptr) {
            *error = "retired";
        }
        return false;
    }
    const auto kind = KindFromRaw(kind_raw);
    if (version != "1" || kind == Kind::Retired || kind == Kind::Password ||
        !LooksLikeUuid(id) || title.empty() ||
        static_cast<int>(title.size()) > kMaxTitleChars) {
        if (error != nullptr) {
            *error = "malformed front matter";
        }
        return false;
    }
    auto body = text.substr(end + 4);
    // After "\n---", consume the rest of that line, then one blank line
    // the way CapsuleContentStore skips an empty line after the closer.
    if (body.size() >= 2 && body[0] == '\r' && body[1] == '\n') {
        body.remove_prefix(2);
    } else if (!body.empty() && body.front() == '\n') {
        body.remove_prefix(1);
    }
    if (body.size() >= 2 && body[0] == '\r' && body[1] == '\n') {
        body.remove_prefix(2);
    } else if (!body.empty() && body.front() == '\n') {
        body.remove_prefix(1);
    }
    if (body.size() > static_cast<std::size_t>(kMaxContentChars) ||
        body.find('\0') != std::string_view::npos || body.empty()) {
        if (error != nullptr) {
            *error = "invalid body";
        }
        return false;
    }
    try { (void)nlohmann::json(std::string(text)).dump(); }
    catch (const std::exception&) { if (error) *error = "invalid UTF-8"; return false; }
    if (text.find('\0') != text.npos || out->summary.size() > 4096) return false;
    out->id = id;
    out->kind = kind;
    out->title = title;
    out->content = std::string(body);
    out->updated_at = updated;
    return true;
}

std::filesystem::path ContentStore::DefaultRoot() {
    if (const char* override_path = std::getenv("RIMES_CAPSULE_ROOT")) {
        if (override_path[0] == '/') {
            return override_path;
        }
    }
    if (const char* user = std::getenv("RIMES_USER_DIR")) {
        if (user[0] == '/') {
            return std::filesystem::path(user) / "capsule";
        }
    }
    if (const char* xdg = std::getenv("XDG_DATA_HOME")) {
        if (xdg[0] == '/') {
            return std::filesystem::path(xdg) / "rimes" / "capsule";
        }
    }
    if (const char* home = std::getenv("HOME")) {
        if (home[0] == '/') {
            return std::filesystem::path(home) / ".local" / "share" / "rimes" / "capsule";
        }
    }
    return {};
}

ContentStore::ContentStore(std::filesystem::path root)
    : root_(std::move(root)),
      entries_(root_ / "entries"),
      seed_(root_ / "content-seed-v1"),
      lock_(root_ / ".lock") {}

StoreStatus ContentStore::WithLock(const std::function<StoreStatus()>& body, std::string* error) const {
    try {
        runtime::PrivateDirectory root(root_);
        runtime::PrivateDirectory entries(entries_);
        auto lock = root.Lock();
        return body();
    } catch (const std::exception&) { return IoFail(error, "Capsule storage is unavailable or its permissions changed"); }
}

StoreStatus ContentStore::SeedIfNeeded(std::string* error) {
    return WithLock([&] {
        runtime::PrivateDirectory files(root_);
        if (files.Read("content-seed-v1", 64)) return StoreStatus::Ok;
        std::vector<Record> records;
        const auto listed = ReadAll(&records, error);
        if (listed != StoreStatus::Ok) return listed;
        if (records.empty()) {
            Record seed;
            seed.id = kDefaultEntryId; seed.title = kDefaultEntryTitle;
            seed.content = kDefaultEntryContent; seed.updated_at = Iso8601UtcNow();
            // Never replace a malformed user file occupying the default UUID.
            runtime::PrivateDirectory entries(entries_);
            if (!entries.Read(EntryPath(seed.id).filename().string(), kMaxDocumentBytes)) {
                const auto status = WriteRecord(seed, error);
                if (status != StoreStatus::Ok) return status;
            }
        }
        files.Write("content-seed-v1", "seeded\n");
        return StoreStatus::Ok;
    }, error);
}
StoreStatus ContentStore::ListAll(std::vector<Record>* out, std::string* error) const {
    if (!out) return InvalidFail(error, "list output is null");
    return WithLock([&] { return ReadAll(out, error); }, error);
}
StoreStatus ContentStore::List(Kind kind, std::vector<Record>* out, std::string* error) const {
    if (!out) return InvalidFail(error, "list output is null");
    const auto result = ListAll(out, error);
    if (result == StoreStatus::Ok) out->erase(std::remove_if(out->begin(), out->end(), [kind](const auto& record) {
        return record.kind != kind;
    }), out->end());
    return result;
}
StoreStatus ContentStore::Get(std::string_view id, Record* out, std::string* error) const {
    if (!out || !LooksLikeUuid(id)) return InvalidFail(error, "invalid id");
    // Writers publish a whole immutable inode by rename. A single-record read
    // therefore observes the old or new revision without waiting on a writer;
    // input-method delivery must never wait for an editor's storage lock.
    return ParseFile(EntryPath(id), out, error);
}
StoreStatus ContentStore::Put(const Record& request, std::string expected_revision, Record* out, std::string* error) {
    if (request.kind == Kind::Retired || request.kind == Kind::Password) return InvalidFail(error, "passwords require the encrypted store");
    if (Trim(request.title).empty() || request.title.size() > kMaxTitleChars || request.content.empty() ||
        request.content.size() > kMaxContentChars || request.title.find('\0') != request.title.npos ||
        request.content.find('\0') != request.content.npos) return InvalidFail(error, "invalid title or content");
    return WithLock([&] {
        Record record = request;
        if (record.id.empty()) record.id = NewUuidV4();
        if (!LooksLikeUuid(record.id)) return InvalidFail(error, "invalid id");
        record.title = Trim(record.title); record.updated_at = Iso8601UtcNow();
        const auto path = EntryPath(record.id);
        Record existing;
        const auto status = ParseFile(path, &existing, error);
        if (status == StoreStatus::Ok) {
            // Editing is always compare-and-swap, including CLI and GUI writers.
            if (expected_revision != existing.revision) return StoreStatus::RevisionConflict;
        } else if (status != StoreStatus::NotFound) return status;
        else if (!expected_revision.empty()) return StoreStatus::RevisionConflict;
        const auto raw = RenderMarkdown(record);
        Record check;
        if (raw.size() > kMaxDocumentBytes || !ParseMarkdown(raw, &check, error)) return StoreStatus::Invalid;
        if (!check.attachment.empty()) {
            std::string bytes;
            if (ReadAttachment(check.attachment, &bytes, error) != StoreStatus::Ok) return StoreStatus::Invalid;
        }
        const auto result = WriteRecord(record, error);
        if (result == StoreStatus::Ok && out) return ParseFile(path, out, error);
        return result;
    }, error);
}
StoreStatus ContentStore::Remove(std::string_view id, std::string_view expected_revision, std::string* error) {
    if (!LooksLikeUuid(id)) return InvalidFail(error, "invalid id");
    return WithLock([&] {
        Record existing;
        const auto status = ParseFile(EntryPath(id), &existing, error);
        if (status != StoreStatus::Ok) return status;
        if (expected_revision != existing.revision) return StoreStatus::RevisionConflict;
        runtime::PrivateDirectory(entries_).Remove(EntryPath(id).filename().string());
        return StoreStatus::Ok;
    }, error);
}
StoreStatus ContentStore::ReadAll(std::vector<Record>* out, std::string* error) const {
    out->clear();
    std::size_t bytes = 0;
    for (const auto& entry : std::filesystem::directory_iterator(entries_)) {
        if (entry.path().extension() != ".md" || !LooksLikeUuid(entry.path().stem().string())) continue;
        Record record;
        if (ParseFile(entry.path(), &record, error) != StoreStatus::Ok) continue;
        if (out->size() >= kMaxRecords) return InvalidFail(error, "too many Capsule entries");
        bytes += record.content.size() + record.title.size() + record.summary.size();
        for(const auto& line:record.extra_header) bytes += line.size();
        if (bytes > 64 * 1024 * 1024) { out->clear(); return InvalidFail(error, "Capsule library exceeds memory budget"); }
        out->push_back(std::move(record));
    }
    std::sort(out->begin(), out->end(), [](const auto& a, const auto& b) {
        return a.updated_at != b.updated_at ? a.updated_at > b.updated_at : a.id < b.id;
    });
    return StoreStatus::Ok;
}
StoreStatus ContentStore::ParseFile(const std::filesystem::path& path, Record* out, std::string* error) const {
    try {
        const auto bytes = runtime::PrivateDirectory(entries_).Read(path.filename().string(), kMaxDocumentBytes);
        if (!bytes) return StoreStatus::NotFound;
        if (!ParseMarkdown(*bytes, out, error) || EntryPath(out->id) != path) return StoreStatus::Invalid;
        out->path = path; out->revision = Sha256Hex(*bytes);
        return StoreStatus::Ok;
    } catch (const std::exception&) { return IoFail(error, "unsafe or unreadable Capsule entry"); }
}
StoreStatus ContentStore::WriteRecord(const Record& record, std::string* error) const {
    try {
        runtime::PrivateDirectory(entries_).Write(EntryPath(record.id).filename().string(), RenderMarkdown(record));
        return StoreStatus::Ok;
    } catch (const std::exception&) { return IoFail(error, "cannot publish Capsule entry"); }
}
std::filesystem::path ContentStore::EntryPath(std::string_view id) const {
    std::string lower(id);
    for (auto& ch : lower) ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    return entries_ / (lower + ".md");
}
StoreStatus ContentStore::ReadAttachment(std::string_view asset, std::string* bytes, std::string* error) const {
    if (!bytes || asset.size() != 64 || !std::all_of(asset.begin(), asset.end(), [](char ch) {
        return (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f');
    })) return InvalidFail(error, "invalid attachment identity");
    try {
        auto raw = runtime::PrivateDirectory(root_ / "assets").Read(std::string(asset) + ".asset", 256 * 1024 * 1024);
        if (!raw) return StoreStatus::NotFound;
        if (runtime::Sha256(*raw) != asset) return InvalidFail(error, "attachment checksum mismatch");
        *bytes = std::move(*raw); return StoreStatus::Ok;
    } catch (const std::exception&) { return IoFail(error, "attachment unavailable"); }
}
StoreStatus ContentStore::ImportAttachment(const std::filesystem::path& source, std::string* asset, std::string* error) {
    if (!asset || !source.is_absolute()) return InvalidFail(error, "absolute attachment path required");
    const int fd = open(source.c_str(), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return IoFail(error, "cannot open attachment");
    struct Owner { int fd; ~Owner() { close(fd); } } owner{fd};
    struct stat before{}, after{};
    constexpr std::size_t limit = 256 * 1024 * 1024;
    if (fstat(fd, &before) || !S_ISREG(before.st_mode) || before.st_size < 0 || static_cast<std::uint64_t>(before.st_size) > limit)
        return InvalidFail(error, "attachment is not a bounded regular file");
    std::string bytes; std::array<char, 65536> chunk{};
    for (;;) {
        const auto count = read(fd, chunk.data(), chunk.size());
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) return IoFail(error, "attachment read failed");
        if (!count) break;
        if (bytes.size() + count > limit) return InvalidFail(error, "attachment exceeds size limit");
        bytes.append(chunk.data(), count);
    }
    if (fstat(fd, &after) || before.st_size != after.st_size || before.st_mtim.tv_sec != after.st_mtim.tv_sec ||
        before.st_mtim.tv_nsec != after.st_mtim.tv_nsec || static_cast<std::uint64_t>(after.st_size) != bytes.size())
        return StoreStatus::RevisionConflict;
    try {
        const auto id = runtime::Sha256(bytes);
        runtime::PrivateDirectory(root_ / "assets").Write(id + ".asset", bytes);
        *asset = id; return StoreStatus::Ok;
    } catch (const std::exception&) { return IoFail(error, "cannot publish attachment"); }
}
} // namespace rimes::capsule
