#include "capsule_hash.hpp"
#include "capsule_store.hpp"
#include "private_files.hpp"

#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <unistd.h>
#include <vector>
#include <sys/stat.h>

namespace {

int g_failures = 0;

void Expect(bool cond, const char* message) {
    if (!cond) {
        std::cerr << "FAIL: " << message << '\n';
        ++g_failures;
    }
}

std::filesystem::path TempRoot() {
    return std::filesystem::temp_directory_path() /
           ("rimes-capsule-store-" + std::to_string(getpid()));
}

}  // namespace

int main() {
    const auto root = TempRoot();
    std::error_code error;
    std::filesystem::remove_all(root, error);
    rimes::capsule::ContentStore store(root);

    std::string store_error;
    Expect(store.SeedIfNeeded(&store_error) == rimes::capsule::StoreStatus::Ok, "seed");
    Expect(std::filesystem::exists(root / "content-seed-v1"), "seed marker");

    std::vector<rimes::capsule::Record> notes;
    Expect(store.List(rimes::capsule::Kind::Note, &notes, &store_error) ==
               rimes::capsule::StoreStatus::Ok,
           "list");
    Expect(notes.size() == 1, "one seed note");
    Expect(notes[0].id == rimes::capsule::kDefaultEntryId, "seed id");
    Expect(notes[0].title == rimes::capsule::kDefaultEntryTitle, "seed title");
    Expect(notes[0].content == rimes::capsule::kDefaultEntryContent, "seed body");

    struct stat st {};
    Expect(stat(root.c_str(), &st) == 0 && (st.st_mode & 0777) == 0700, "root 0700");
    Expect(stat(notes[0].path.c_str(), &st) == 0 && (st.st_mode & 0777) == 0600, "entry 0600");

    const auto first_revision = notes[0].revision;
    Expect(!first_revision.empty(), "revision");
    {
        auto held=rimes::runtime::PrivateDirectory(root).Lock();
        rimes::capsule::Record blocked;
        Expect(store.Get(notes[0].id,&blocked,&store_error)==rimes::capsule::StoreStatus::Ok,"IME reads must not wait for a writer lock");
    }
    Expect(store.SeedIfNeeded(&store_error) == rimes::capsule::StoreStatus::Ok, "seed idempotent");
    notes.clear();
    store.List(rimes::capsule::Kind::Note, &notes, &store_error);
    Expect(notes.size() == 1, "seed does not duplicate");

    rimes::capsule::Record extra;
    extra.kind = rimes::capsule::Kind::Note;
    extra.title = "Second";
    extra.content = "hello capsule";
    rimes::capsule::Record written;
    Expect(store.Put(extra, "", &written, &store_error) == rimes::capsule::StoreStatus::Ok, "put");
    Expect(rimes::capsule::LooksLikeUuid(written.id), "generated uuid");

    rimes::capsule::Record stale = written;
    stale.content = "changed";
    Expect(store.Put(stale, "deadbeef", &written, &store_error) ==
               rimes::capsule::StoreStatus::RevisionConflict,
           "stale revision");

    const auto markdown = rimes::capsule::RenderMarkdown(notes[0]);
    Expect(markdown.find("capsule: note") != std::string::npos, "front matter kind");
    rimes::capsule::Record parsed;
    Expect(rimes::capsule::ParseMarkdown(markdown, &parsed, &store_error), "parse seed markdown");
    Expect(parsed.title == rimes::capsule::kDefaultEntryTitle, "roundtrip title");

    Expect(store.Remove(written.id, written.revision, &store_error) ==
               rimes::capsule::StoreStatus::Ok,
           "remove");
    notes.clear();
    store.List(rimes::capsule::Kind::Note, &notes, &store_error);
    Expect(notes.size() == 1, "remove left the seed");

    // Native metadata survives a Linux read/edit/write, including opaque
    // rich-text references. Missing revisions never overwrite existing files.
    extra.note_format="bullet"; extra.summary="摘要"; extra.extra_header={"future_key: \"native value\""};
    Expect(store.Put(extra,"",&written,&store_error)==rimes::capsule::StoreStatus::Ok,"write metadata");
    auto changed=written; changed.content="new content";
    Expect(store.Put(changed,"",nullptr,&store_error)==rimes::capsule::StoreStatus::RevisionConflict,"empty revision cannot overwrite");
    Expect(store.Remove(written.id,"",&store_error)==rimes::capsule::StoreStatus::RevisionConflict,"empty revision cannot delete");
    Expect(store.Put(changed,written.revision,&written,&store_error)==rimes::capsule::StoreStatus::Ok,"CAS edit");
    Expect(written.summary=="摘要" && written.note_format=="bullet" && written.extra_header==extra.extra_header,"metadata retained");
    auto duplicate=written; duplicate.extra_header.push_back("title: injected");
    Expect(store.Put(duplicate,written.revision,nullptr,&store_error)==rimes::capsule::StoreStatus::Invalid,"reserved metadata cannot be injected");
    const auto source=root/"sample.pdf"; {std::ofstream out(source);out<<"fixture bytes";}
    std::string asset,bytes;
    Expect(store.ImportAttachment(source,&asset,&store_error)==rimes::capsule::StoreStatus::Ok,"import attachment");
    auto resource=extra;resource.kind=rimes::capsule::Kind::Pdf;resource.content="reference";resource.attachment=asset;
    Expect(store.Put(resource,"",&written,&store_error)==rimes::capsule::StoreStatus::Ok,"persist attachment record");
    Expect(store.Remove(written.id,written.revision,&store_error)==rimes::capsule::StoreStatus::Ok,"remove record");
    Expect(store.ReadAttachment(asset,&bytes,&store_error)==rimes::capsule::StoreStatus::Ok && bytes=="fixture bytes","record removal preserves immutable attachment");
    Expect(store.ReadAttachment("../sample.pdf",&bytes,&store_error)==rimes::capsule::StoreStatus::Invalid,"reject asset traversal");
    std::filesystem::create_symlink(source,root/"linked.pdf");
    Expect(store.ImportAttachment(root/"linked.pdf",&asset,&store_error)!=rimes::capsule::StoreStatus::Ok,"reject symlink import");
    {std::ofstream out(root/"assets"/(resource.attachment+".asset"));out<<"tampered";}
    Expect(store.ReadAttachment(resource.attachment,&bytes,&store_error)==rimes::capsule::StoreStatus::Invalid,"verify asset checksum");
    auto injected=extra;injected.extra_header.push_back("capsule_linux_asset: \""+resource.attachment+"\"");
    Expect(store.Put(injected,"",nullptr,&store_error)==rimes::capsule::StoreStatus::Invalid,"injected asset metadata still validated");
    resource.kind=rimes::capsule::Kind::Password;
    Expect(store.Put(resource,"",nullptr,&store_error)==rimes::capsule::StoreStatus::Invalid,"password plaintext is never stored here");

    std::filesystem::remove_all(root, error);
    if (g_failures != 0) {
        std::cerr << g_failures << " capsule store failures\n";
        return 1;
    }
    std::cout << "ok: capsule store\n";
    return 0;
}
