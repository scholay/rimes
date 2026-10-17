#include "capsule_protocol.hpp"

#include <iostream>

namespace {

int g_failures = 0;

void Expect(bool cond, const char* message) {
    if (!cond) {
        std::cerr << "FAIL: " << message << '\n';
        ++g_failures;
    }
}

}  // namespace

int main() {
    rimes::capsule::CapsuleModel model;
    rimes::capsule::Record note;
    note.id = rimes::capsule::kDefaultEntryId;
    note.kind = rimes::capsule::Kind::Note;
    note.title = rimes::capsule::kDefaultEntryTitle;
    note.content = rimes::capsule::kDefaultEntryContent;
    model.LoadCards({note});
    model.set_visible(true);
    model.set_armed(true);
    const auto json = rimes::capsule::EncodeSnapshot(rimes::capsule::MakeSnapshot(model));
    Expect(json.find("\"visible\":true") != std::string::npos, "visible");
    Expect(json.find(rimes::capsule::kDefaultEntryTitle) != std::string::npos, "title");
    Expect(json.find("\"payload\"") == std::string::npos, "no full payload on the wire");

    rimes::capsule::Snapshot decoded;
    Expect(rimes::capsule::DecodeSnapshot(json, &decoded), "decode");
    Expect(decoded.visible && decoded.armed, "decoded flags");
    Expect(decoded.cards.size() == 1, "decoded card");
    Expect(decoded.cards[0].title == rimes::capsule::kDefaultEntryTitle, "decoded title");

    model.set_last_copied("private-clipboard");
    model.set_query("private-query");
    model.set_password_field(true);
    const auto protected_json = rimes::capsule::EncodeSnapshot(rimes::capsule::MakeSnapshot(model));
    Expect(protected_json.find("private-") == std::string::npos, "protected clipboard and query leaked");
    Expect(protected_json.find(rimes::capsule::kDefaultEntryTitle) == std::string::npos, "protected card title leaked");
    Expect(rimes::capsule::DecodeSnapshot(protected_json, &decoded) && decoded.cards.empty() &&
           !decoded.visible && !decoded.armed, "protected snapshot still actionable");

    rimes::capsule::Command command;
    std::string error;
    Expect(rimes::capsule::ParseCommand(R"({"v":1,"op":"activate"})", &command, &error),
           "parse activate");
    Expect(command.op == rimes::capsule::CommandOp::Activate, "activate op");
    Expect(!rimes::capsule::ParseCommand(R"({"v":1,"op":"nope"})", &command, &error),
           "unknown op");

    if (g_failures != 0) {
        std::cerr << g_failures << " capsule protocol failures\n";
        return 1;
    }
    std::cout << "ok: capsule protocol\n";
    return 0;
}
