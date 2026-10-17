#pragma once

#include <cstdint>
#include <string>
#include <string_view>

#include "capsule_model.hpp"

namespace rimes::capsule {

enum class CommandOp {
    Hello,
    Status,
    Toggle,
    Show,
    Close,
    Next,
    Prev,
    Select,
    Tab,
    Activate,
    Copy,
    Search,
    Module,
    Filter,
    Manage,
    Rail,
    Refresh,
    Unknown,
};

struct Command {
    CommandOp op = CommandOp::Unknown;
    std::string text;
    int index = -1;
    std::string id;
};

struct Snapshot {
    std::uint64_t generation = 0;
    bool visible = false;
    bool armed = false;
    bool password_field = false;
    std::string theme = "night";
    std::string module = "notes";
    std::string filter = "all";
    bool managing = false;
    bool loading = false;
    std::vector<Module> modules{Module::Notes};
    std::string tab;
    std::string query;
    std::string hint;
    std::string last_copied;
    std::uint64_t copy_seq = 0;
    std::string selected_id;
    std::string selected_title;
    std::string selected_preview;
    int selected = 0;
    int offset = 0;
    int count = 0;
    int ui_clients = 0;
    std::vector<Card> cards;
};

Snapshot MakeSnapshot(const CapsuleModel& model);
std::string EncodeSnapshot(const Snapshot& snapshot);
bool DecodeSnapshot(std::string_view json, Snapshot* snapshot);
bool ParseCommand(std::string_view json, Command* command, std::string* error);

inline constexpr const char* kProtocolVersion = "1";

}  // namespace rimes::capsule
