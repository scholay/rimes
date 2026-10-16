#include <jni.h>
#include <rime_api.h>
#include <algorithm>
#include <codecvt>
#include <locale>
#include <filesystem>
#include <stdexcept>
#include <string>
#include <vector>

// JNI's modified UTF-8 is not standard UTF-8. Use explicit UTF-16 conversions,
// including surrogate pairs; Rime's caret offsets count UTF-8 bytes.
static std::u16string utf16(const std::string& s) {
    std::wstring_convert<std::codecvt_utf8_utf16<char16_t>, char16_t> converter;
    return converter.from_bytes(s);
}
static std::string utf8(JNIEnv* env, jstring value) {
    if (!value) return {};
    const jchar* chars = env->GetStringChars(value, nullptr);
    std::u16string text(reinterpret_cast<const char16_t*>(chars), env->GetStringLength(value));
    env->ReleaseStringChars(value, chars);
    std::wstring_convert<std::codecvt_utf8_utf16<char16_t>, char16_t> converter;
    return converter.to_bytes(text);
}
static jstring string(JNIEnv* env, const std::string& s) {
    auto value = utf16(s);
    return env->NewString(reinterpret_cast<const jchar*>(value.data()), static_cast<jsize>(value.size()));
}
static RimeApi* api() { return rime_get_api(); }
static bool initialized = false;
static std::string shared_path, user_path, build_path;
extern "C" const char* rimes_lua_last_error();
extern "C" void rimes_lua_clear_error();
static const char* modules[] = {"default", "lua", "deployer", nullptr};
static void initialize(const std::string& shared, const std::string& user) {
    if (initialized && shared_path == shared && user_path == user) return;
    if (initialized) { api()->finalize(); initialized = false; }
    shared_path = shared; user_path = user; build_path = shared_path + "/build";
    RIME_STRUCT(RimeTraits, traits);
    traits.shared_data_dir = shared_path.c_str(); traits.user_data_dir = user_path.c_str();
    traits.prebuilt_data_dir = build_path.c_str(); traits.staging_dir = build_path.c_str();
    traits.app_name = "rime.rimes_android"; traits.modules = modules;
    api()->setup(&traits); api()->initialize(&traits); initialized = true;
}
#define JNI(name) Java_org_scholay_rimes_android_NativeRimeEngine_##name
extern "C" JNIEXPORT void JNICALL JNI(initializeNative)(JNIEnv* env, jclass, jstring shared, jstring user) {
    try { initialize(utf8(env, shared), utf8(env, user)); }
    catch (...) {
        if (initialized) { api()->finalize(); initialized = false; }
        if (auto type = env->FindClass("java/lang/IllegalStateException"))
            env->ThrowNew(type, "The Rime environment could not be initialized");
    }
    // Runtime never deploys on first key. Import compilation runs in the separate
    // settings import process; built-in dictionaries remain precompiled assets.
}
extern "C" JNIEXPORT jlong JNICALL JNI(createNative)(JNIEnv*, jclass) { return api()->create_session(); }
extern "C" JNIEXPORT void JNICALL JNI(destroyNative)(JNIEnv*, jclass, jlong session) { api()->destroy_session(session); }
extern "C" JNIEXPORT jboolean JNICALL JNI(schemaNative)(JNIEnv* env, jclass, jlong session, jstring schema) {
    rimes_lua_clear_error();
    const bool selected = api()->select_schema(session, utf8(env, schema).c_str());
    return selected && (!rimes_lua_last_error() || !rimes_lua_last_error()[0]);
}
extern "C" JNIEXPORT jstring JNICALL JNI(deployNative)(JNIEnv* env, jclass, jstring root, jobjectArray schemas) {
    std::string failure;
    std::string resources;
    try {
        resources = utf8(env, root);
        initialize(resources, resources);
        if (!api()->deploy_config_file("default.yaml", "config_version")) throw std::runtime_error("default.yaml deployment failed");
        std::vector<std::string> identifiers;
        const auto count = env->GetArrayLength(schemas);
        if (count < 1 || count > 32) throw std::runtime_error("Invalid schema selection");
        for (jsize i = 0; i < count; ++i) {
            auto value = static_cast<jstring>(env->GetObjectArrayElement(schemas, i));
            auto id = utf8(env, value); env->DeleteLocalRef(value);
            if (id.empty() || id.find("..") != std::string::npos ||
                id.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-") != std::string::npos)
                throw std::runtime_error("Invalid schema identifier");
            identifiers.push_back(id);
            if (!api()->deploy_schema((resources + "/" + id + ".schema.yaml").c_str()))
                throw std::runtime_error("Cannot deploy " + id);
        }
        const auto validation = resources + "/.validation-user";
        std::filesystem::create_directories(validation);
        initialize(resources, validation);
        for (const auto& id : identifiers) {
            rimes_lua_clear_error();
            auto session = api()->create_session();
            bool valid = session && api()->select_schema(session, id.c_str());
            if (valid) {
                api()->set_option(session, "ascii_mode", false);
                for (const auto* sample : {"a", "nihao", "1234567890"}) {
                    for (const char* key = sample; *key; ++key) api()->process_key(session, *key, 0);
                    api()->clear_composition(session);
                }
            }
            if (session) api()->destroy_session(session);
            const std::string error = rimes_lua_last_error() ? rimes_lua_last_error() : "";
            if (!valid || !error.empty()) throw std::runtime_error(id + ": " + (error.empty() ? "Cannot load schema" : error));
        }
    } catch (const std::exception& error) { failure = error.what(); }
      catch (...) { failure = "Rime deployment failed"; }
    if (initialized) { api()->finalize(); initialized = false; }
    std::error_code ignored;
    if (!resources.empty()) std::filesystem::remove_all(resources + "/.validation-user", ignored);
    return failure.empty() ? nullptr : string(env, failure);
}
extern "C" JNIEXPORT jboolean JNICALL JNI(keyNative)(JNIEnv*, jclass, jlong session, jint key) { return api()->process_key(session,key,0); }
extern "C" JNIEXPORT jboolean JNICALL JNI(selectNative)(JNIEnv*, jclass, jlong session, jint index) {
    return index >= 0 && api()->select_candidate(session,static_cast<size_t>(index));
}
extern "C" JNIEXPORT void JNICALL JNI(clearNative)(JNIEnv*, jclass, jlong session) { api()->clear_composition(session); }
extern "C" JNIEXPORT jstring JNICALL JNI(roundTripNative)(JNIEnv* env, jclass, jstring text) { return string(env,utf8(env,text)); }
static jobject candidateSnapshot(JNIEnv* env, bool handled, const std::string& raw, const std::string& preedit,
    int cursor, const std::string& commit, const std::vector<std::string>& candidates,
    const std::vector<std::string>& comments, int start, int highlighted, bool last) {
    jclass strings=env->FindClass("java/lang/String");
    auto texts=env->NewObjectArray(candidates.size(),strings,nullptr);
    auto notes=env->NewObjectArray(comments.size(),strings,nullptr);
    for (size_t i=0;i<candidates.size();++i) {
        auto t=string(env,candidates[i]); auto n=string(env,comments[i]);
        env->SetObjectArrayElement(texts,i,t); env->SetObjectArrayElement(notes,i,n);
        env->DeleteLocalRef(t); env->DeleteLocalRef(n);
    }
    auto cls=env->FindClass("org/scholay/rimes/core/RimeEngine$Snapshot");
    auto constructor=env->GetMethodID(cls,"<init>","(ZLjava/lang/String;Ljava/lang/String;ILjava/lang/String;[Ljava/lang/String;[Ljava/lang/String;IIZ)V");
    return env->NewObject(cls,constructor,handled,string(env,raw),string(env,preedit),cursor,string(env,commit),texts,notes,start,highlighted,static_cast<jboolean>(last));
}
extern "C" JNIEXPORT jobject JNICALL JNI(snapshotNative)(JNIEnv* env, jclass, jlong session, jboolean handled) {
    std::string raw = api()->get_input(session) ? api()->get_input(session) : "";
    std::string commit, preedit;
    RIME_STRUCT(RimeCommit, committed);
    if (api()->get_commit(session,&committed)) { if (committed.text) commit=committed.text; api()->free_commit(&committed); }
    int cursor=0, start=0, highlighted=0; bool last=true;
    std::vector<std::string> candidates, comments;
    RIME_STRUCT(RimeContext, context);
    if (api()->get_context(session,&context)) {
        if (context.composition.preedit) preedit=context.composition.preedit;
        size_t bytes=std::min(preedit.size(),static_cast<size_t>(std::max(0,context.composition.cursor_pos)));
        cursor=static_cast<int>(utf16(preedit.substr(0,bytes)).size());
        start=context.menu.page_no*context.menu.page_size;
        highlighted=start+context.menu.highlighted_candidate_index;
        last=context.menu.is_last_page;
        for (int i=0; i<context.menu.num_candidates; ++i) {
            candidates.emplace_back(context.menu.candidates[i].text ? context.menu.candidates[i].text : "");
            comments.emplace_back(context.menu.candidates[i].comment ? context.menu.candidates[i].comment : "");
        }
        api()->free_context(&context);
    }
    return candidateSnapshot(env,handled,raw,preedit,cursor,commit,candidates,comments,start,highlighted,last);
}

// Enumerate the engine's immutable candidate sequence. This neither changes its
// current page nor invokes custom PageUp/Down bindings or drains pending commits.
extern "C" JNIEXPORT jobject JNICALL JNI(candidatesNative)(JNIEnv* env, jclass, jlong session, jint start, jint count) {
    if (start < 0 || count < 1 || count > 100000) {
        env->ThrowNew(env->FindClass("java/lang/IllegalArgumentException"), "Invalid candidate range"); return nullptr;
    }
    std::string raw = api()->get_input(session) ? api()->get_input(session) : "";
    std::string preedit;
    int cursor = 0;
    RIME_STRUCT(RimeContext, context);
    if (api()->get_context(session, &context)) {
        if (context.composition.preedit) preedit = context.composition.preedit;
        const auto bytes = std::min(preedit.size(), static_cast<size_t>(std::max(0, context.composition.cursor_pos)));
        cursor = static_cast<int>(utf16(preedit.substr(0, bytes)).size());
        api()->free_context(&context);
    }
    std::vector<std::string> candidates, comments;
    bool last = true;
    RimeCandidateListIterator iterator{};
    if (api()->candidate_list_from_index(session, &iterator, start)) {
        struct End { RimeCandidateListIterator* iterator; ~End() { api()->candidate_list_end(iterator); } } end{&iterator};
        while (static_cast<int>(candidates.size()) < count && api()->candidate_list_next(&iterator)) {
            candidates.emplace_back(iterator.candidate.text ? iterator.candidate.text : "");
            comments.emplace_back(iterator.candidate.comment ? iterator.candidate.comment : "");
        }
        last = !api()->candidate_list_next(&iterator);
    }
    return candidateSnapshot(env, false, raw, preedit, cursor, "", candidates, comments, start, 0, last);
}
