#include <rime_api.h>
#include <cstdio>
#include <string>
#include <filesystem>
int main(int argc, char** argv) {
    if (argc != 3) return 2;
    const std::string shared = argv[1], user = argv[2], compiled = shared + "/build";
    std::filesystem::create_directories(user);
    RIME_STRUCT(RimeTraits, traits);
    traits.shared_data_dir = shared.c_str(); traits.user_data_dir = user.c_str();
    traits.prebuilt_data_dir = compiled.c_str(); traits.staging_dir = compiled.c_str();
    traits.app_name = "rime.rimes_ios_smoke";
    auto api = rime_get_api(); api->setup(&traits); api->initialize(&traits);
    const auto session = api->create_session();
    struct Case { const char* schema; const char* code; const char* expected; };
    Case cases[] = {{"rimes_pinyin","nihao","你好"},{"rimes_ziranma","nihk","你好"},{"rimes_wubi","wq","你"}};
    int failures = 0;
    for (const auto& c : cases) {
        if (!api->select_schema(session,c.schema)) { std::printf("FAIL schema %s\n",c.schema); ++failures; continue; }
        for (const char* key=c.code; *key; ++key) api->process_key(session,*key,0);
        RimeCandidateListIterator it = {}; int index=0; bool found=false;
        if (api->candidate_list_begin(session,&it)) {
            while (index<60 && api->candidate_list_next(&it)) {
                if (it.candidate.text && std::string(it.candidate.text)==c.expected) { found=true; break; }
                ++index;
            }
            api->candidate_list_end(&it);
        }
        if (found) {
            api->select_candidate(session,index); RIME_STRUCT(RimeCommit, commit);
            found=api->get_commit(session,&commit) && commit.text && std::string(commit.text)==c.expected;
            api->free_commit(&commit);
        }
        std::printf("%s %s / %s\n",found?"PASS":"FAIL",c.schema,c.code);
        if (!found) ++failures; api->clear_composition(session);
    }
    api->destroy_session(session); api->finalize(); return failures ? 1 : 0;
}
