#include "capsule_protocol.hpp"

#include <cctype>
#include <cstdlib>
#include <sstream>

#include "buffer_protocol.hpp"

namespace rimes::capsule {
namespace {

void SkipWs(std::string_view json, std::size_t* pos) {
    while (*pos < json.size() && std::isspace(static_cast<unsigned char>(json[*pos])) != 0) {
        ++*pos;
    }
}

bool FindKey(std::string_view json, std::string_view key, std::size_t* value_pos) {
    const std::string needle = std::string("\"") + std::string(key) + "\"";
    std::size_t search = 0;
    while (search < json.size()) {
        const auto found = json.find(needle, search);
        if (found == std::string_view::npos) {
            return false;
        }
        std::size_t pos = found + needle.size();
        SkipWs(json, &pos);
        if (pos < json.size() && json[pos] == ':') {
            ++pos;
            SkipWs(json, &pos);
            *value_pos = pos;
            return true;
        }
        search = found + 1;
    }
    return false;
}

bool ParseStringValue(std::string_view json, std::size_t pos, std::string* output) {
    if (pos >= json.size() || json[pos] != '"') {
        return false;
    }
    ++pos;
    std::string raw;
    while (pos < json.size()) {
        const char ch = json[pos];
        if (ch == '"') {
            return rimes::buffer::JsonUnescape(raw, output);
        }
        raw.push_back(ch);
        if (ch == '\\' && pos + 1 < json.size()) {
            raw.push_back(json[pos + 1]);
            pos += 2;
            continue;
        }
        ++pos;
    }
    return false;
}

int ReadInt(std::string_view json, std::string_view key, int fallback) {
    std::size_t pos = 0;
    if (!FindKey(json, key, &pos)) {
        return fallback;
    }
    char* end = nullptr;
    const auto value = std::strtol(json.data() + pos, &end, 10);
    if (end == json.data() + pos) {
        return fallback;
    }
    return static_cast<int>(value);
}

std::string ReadString(std::string_view json, std::string_view key) {
    std::size_t pos = 0;
    std::string value;
    if (!FindKey(json, key, &pos)) {
        return {};
    }
    if (!ParseStringValue(json, pos, &value)) {
        return {};
    }
    return value;
}

}  // namespace

Snapshot MakeSnapshot(const CapsuleModel& model) {
    Snapshot snapshot;
    snapshot.generation = model.generation();
    snapshot.visible = model.visible();
    snapshot.armed = model.armed();
    snapshot.password_field = model.password_field();
    snapshot.tab = TabRaw(model.tab());
    snapshot.query = model.query();
    snapshot.hint = model.hint();
    snapshot.last_copied = model.last_copied();
    snapshot.copy_seq = model.copy_seq();
    snapshot.selected = model.selected();
    snapshot.cards = model.cards();
    snapshot.count = static_cast<int>(snapshot.cards.size());
    if (const auto* card = model.Selected()) {
        snapshot.selected_id = card->id;
        snapshot.selected_title = card->title;
        snapshot.selected_preview = card->preview;
    }
    return snapshot;
}

std::string EncodeSnapshot(const Snapshot& value) {
    auto snapshot = value;
    if (snapshot.password_field) {
        snapshot.visible = false; snapshot.armed = false;
        snapshot.query.clear(); snapshot.last_copied.clear(); snapshot.cards.clear();
        snapshot.selected_id.clear(); snapshot.selected_title.clear(); snapshot.selected_preview.clear();
        snapshot.count = 0; snapshot.selected = 0;
        snapshot.hint = "受保护输入，内容已隐藏";
    }
    std::ostringstream out;
    out << "{\"v\":" << kProtocolVersion
        << ",\"generation\":" << snapshot.generation
        << ",\"visible\":" << (snapshot.visible ? "true" : "false")
        << ",\"armed\":" << (snapshot.armed ? "true" : "false")
        << ",\"password_field\":" << (snapshot.password_field ? "true" : "false")
        << ",\"theme\":" << rimes::buffer::JsonEscape(snapshot.theme)
        << ",\"tab\":" << rimes::buffer::JsonEscape(snapshot.tab)
        << ",\"query\":" << rimes::buffer::JsonEscape(snapshot.query)
        << ",\"hint\":" << rimes::buffer::JsonEscape(snapshot.hint)
        << ",\"last_copied\":" << rimes::buffer::JsonEscape(snapshot.last_copied)
        << ",\"copy_seq\":" << snapshot.copy_seq
        << ",\"selected_id\":" << rimes::buffer::JsonEscape(snapshot.selected_id)
        << ",\"selected_title\":" << rimes::buffer::JsonEscape(snapshot.selected_title)
        << ",\"selected_preview\":" << rimes::buffer::JsonEscape(snapshot.selected_preview)
        << ",\"selected\":" << snapshot.selected
        << ",\"count\":" << snapshot.count
        << ",\"ui_clients\":" << snapshot.ui_clients
        << ",\"cards\":[";
    for (std::size_t i = 0; i < snapshot.cards.size(); ++i) {
        const auto& card = snapshot.cards[i];
        if (i > 0) {
            out << ',';
        }
        out << "{\"id\":" << rimes::buffer::JsonEscape(card.id)
            << ",\"kind\":" << rimes::buffer::JsonEscape(KindRaw(card.kind))
            << ",\"title\":" << rimes::buffer::JsonEscape(card.title)
            << ",\"preview\":" << rimes::buffer::JsonEscape(card.preview) << '}';
    }
    out << "]}";
    return out.str();
}

bool ReadBool(std::string_view json, std::string_view key) {
    std::size_t pos = 0;
    if (!FindKey(json, key, &pos)) {
        return false;
    }
    return json.compare(pos, 4, "true") == 0;
}

bool DecodeSnapshot(std::string_view json, Snapshot* snapshot) {
    if (snapshot == nullptr || json.find("\"visible\"") == std::string_view::npos) {
        return false;
    }
    snapshot->generation = static_cast<std::uint64_t>(ReadInt(json, "generation", 0));
    snapshot->visible = ReadBool(json, "visible");
    snapshot->armed = ReadBool(json, "armed");
    snapshot->password_field = ReadBool(json, "password_field");
    const auto theme = ReadString(json, "theme");
    snapshot->theme = theme == "day" || theme == "quiet" || theme == "rasta" || theme == "liquidGlass" ? theme : "night";
    snapshot->tab = ReadString(json, "tab");
    snapshot->query = ReadString(json, "query");
    snapshot->hint = ReadString(json, "hint");
    snapshot->last_copied = ReadString(json, "last_copied");
    snapshot->copy_seq = static_cast<std::uint64_t>(ReadInt(json, "copy_seq", 0));
    snapshot->selected_id = ReadString(json, "selected_id");
    snapshot->selected_title = ReadString(json, "selected_title");
    snapshot->selected_preview = ReadString(json, "selected_preview");
    snapshot->selected = ReadInt(json, "selected", 0);
    snapshot->count = ReadInt(json, "count", 0);
    snapshot->ui_clients = ReadInt(json, "ui_clients", 0);
    snapshot->cards.clear();
    const auto cards_key = json.find("\"cards\"");
    if (cards_key == std::string_view::npos) {
        return true;
    }
    auto pos = json.find('[', cards_key);
    if (pos == std::string_view::npos) {
        return true;
    }
    ++pos;
    while (pos < json.size()) {
        while (pos < json.size() && json[pos] != '{' && json[pos] != ']') {
            ++pos;
        }
        if (pos >= json.size() || json[pos] == ']') {
            break;
        }
        const auto end = json.find('}', pos);
        if (end == std::string_view::npos) {
            break;
        }
        const auto object = json.substr(pos, end - pos + 1);
        Card card;
        card.id = ReadString(object, "id");
        card.title = ReadString(object, "title");
        card.preview = ReadString(object, "preview");
        card.kind = KindFromRaw(ReadString(object, "kind"));
        snapshot->cards.push_back(std::move(card));
        pos = end + 1;
    }
    return true;
}

bool ParseCommand(std::string_view json, Command* command, std::string* error) {
    if (command == nullptr) {
        return false;
    }
    const auto op = ReadString(json, "op");
    command->text = ReadString(json, "text");
    command->index = ReadInt(json, "index", -1);
    if (op == "hello") {
        command->op = CommandOp::Hello;
    } else if (op == "status") {
        command->op = CommandOp::Status;
    } else if (op == "toggle") {
        command->op = CommandOp::Toggle;
    } else if (op == "show") {
        command->op = CommandOp::Show;
    } else if (op == "close") {
        command->op = CommandOp::Close;
    } else if (op == "next") {
        command->op = CommandOp::Next;
    } else if (op == "prev") {
        command->op = CommandOp::Prev;
    } else if (op == "select") {
        command->op = CommandOp::Select;
    } else if (op == "tab") {
        command->op = CommandOp::Tab;
        if (command->text.empty()) {
            command->text = ReadString(json, "tab");
        }
    } else if (op == "activate") {
        command->op = CommandOp::Activate;
    } else if (op == "copy") {
        command->op = CommandOp::Copy;
    } else if (op == "search") {
        command->op = CommandOp::Search;
    } else {
        command->op = CommandOp::Unknown;
        if (error != nullptr) {
            *error = "unknown op";
        }
        return false;
    }
    return true;
}

}  // namespace rimes::capsule
