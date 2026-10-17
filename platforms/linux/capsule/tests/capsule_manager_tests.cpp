#include "capsule_manager.hpp"
#include "capsule_hash.hpp"
#include "official_catalog.hpp"
#include "private_files.hpp"
#include <chrono>
#include <filesystem>
#include <iostream>
#include <thread>
#include <unistd.h>
using namespace rimes::capsule;
using Json=nlohmann::json;
static void Check(bool value,const char* message) {if(!value) throw std::runtime_error(message);}
static GtkWidget* Find(GtkWidget* root,const char* name) {
    if(std::string_view(gtk_widget_get_name(root))==name) return root;
    if(!GTK_IS_CONTAINER(root)) return nullptr;
    auto* children=gtk_container_get_children(GTK_CONTAINER(root));GtkWidget* found=nullptr;
    for(auto* node=children;node && !found;node=node->next) found=Find(GTK_WIDGET(node->data),name);
    g_list_free(children);return found;
}
static void Wait(const std::function<bool()>& condition) {
    const auto end=std::chrono::steady_clock::now()+std::chrono::seconds(8);
    do {
        while(gtk_events_pending()) gtk_main_iteration();
        if(condition()) return;
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    } while(std::chrono::steady_clock::now()<end);
    throw std::runtime_error("GTK condition timed out");
}
static std::string Text(GtkWidget* view) {
    auto* buffer=gtk_text_view_get_buffer(GTK_TEXT_VIEW(view));GtkTextIter a{},b{};
    gtk_text_buffer_get_bounds(buffer,&a,&b);auto* raw=gtk_text_buffer_get_text(buffer,&a,&b,FALSE);
    std::string value=raw;g_free(raw);return value;
}
int main(int argc,char** argv) {
    const auto root=std::filesystem::temp_directory_path()/("xsime-capsule-manager-"+std::to_string(getpid()));
    try {
        std::filesystem::remove_all(root);setenv("RIMES_USER_DIR",root.c_str(),1);
        gtk_init(&argc,&argv);
        ContentStore store(ContentStore::DefaultRoot());std::string error;
        Check(store.SeedIfNeeded(&error)==StoreStatus::Ok,"seed failed");
        rimes::plugins::PackageStore packages(root/"plugins",rimes::plugins::OfficialCatalog(),rimes::plugins::BundledPackages(),
            rimes::plugins::CompiledAdapters(),RIMES_PRODUCT_VERSION);
        CapsuleModel model;model.set_visible(true);model.set_managing(true);
        std::vector<Record> records;store.ListAll(&records,&error);model.LoadCards(records);
        ManagerWindow* manager=nullptr;int refreshed=0;
        ManagerWindow window([&](const std::string& raw) {
            const auto command=Json::parse(raw);
            if(command.at("op")=="refresh") {
                ++refreshed;store.ListAll(&records,&error);model.LoadCards(records);manager->Apply(MakeSnapshot(model));
            }
        });manager=&window;window.Apply(MakeSnapshot(model));
        auto get=[&](const char* name){auto* widget=Find(window.Root(),name);Check(widget,"missing UI control");return widget;};
        auto* title=get("capsule-title");auto* body=get("capsule-body");auto* save=get("capsule-save");
        auto layout=[&](int width,int height) {
            if(gtk_widget_get_allocated_width(window.Root())!=width || gtk_widget_get_allocated_height(window.Root())!=height) return false;
            const int list_width=std::clamp(static_cast<int>(width*0.24),170,286);
            const int editor_x=142+list_width+27;
            auto bounds=[&](const char* name,int x,int y,int w,int h) {
                GtkAllocation rect{};gtk_widget_get_allocation(get(name),&rect);
                return rect.x==x && rect.y==y && rect.width==w && rect.height==h;
            };
            return bounds("capsule-modules",14,56,118,height-86) &&
                bounds("capsule-list",142,90,list_width,height-120) &&
                bounds("capsule-editor",editor_x,56,width-editor_x-14,height-86);
        };
        auto contents=[&](const char* value){gtk_text_buffer_set_text(gtk_text_view_get_buffer(GTK_TEXT_VIEW(body)),value,-1);};
        Wait([&]{return std::string(gtk_entry_get_text(GTK_ENTRY(title)))==kDefaultEntryTitle;});
        Wait([&]{return layout(940,660);});
        gtk_entry_set_text(GTK_ENTRY(title),"保存标题");contents("saved body");gtk_button_clicked(GTK_BUTTON(save));
        Wait([&]{return refreshed==1 && Text(body)=="saved body";});
        gtk_window_resize(GTK_WINDOW(window.Window()),620,430);
        Wait([&]{return layout(620,430);});
        gtk_window_resize(GTK_WINDOW(window.Window()),940,660);
        Wait([&]{return layout(940,660);});
        Record saved;Check(store.Get(kDefaultEntryId,&saved,&error)==StoreStatus::Ok && saved.title=="保存标题" && saved.content=="saved body","GUI save did not persist");
        contents("unsaved draft");
        auto locked=MakeSnapshot(model);locked.password_field=true;locked.visible=false;window.Apply(locked);
        Check(!gtk_widget_get_visible(window.Window()) && Text(body).empty(),"protected window retained visible plaintext");
        window.Apply(MakeSnapshot(model));
        Check(Text(body)=="unsaved draft","protection lost unsaved draft");
        auto note=packages.Inspect("builtin.capsule.notes");packages.Enable(note.id,false,note.grant);
        gtk_button_clicked(GTK_BUTTON(save));
        Check(store.Get(saved.id,&saved,&error)==StoreStatus::Ok && saved.content=="saved body","disabled module wrote through stale UI");
        Check(Text(body)=="unsaved draft","revocation lost draft");
        note=packages.Inspect(note.id);packages.Enable(note.id,true,note.grant);
        gtk_button_clicked(GTK_BUTTON(save));Wait([&]{return refreshed==2 && Text(body)=="unsaved draft";});
        Check(store.Get(saved.id,&saved,&error)==StoreStatus::Ok && saved.content=="unsaved draft","current grant could not save");
        auto external=saved;external.content="external revision";Check(store.Put(external,saved.revision,&saved,&error)==StoreStatus::Ok,"external update");
        contents("conflicting local draft");gtk_button_clicked(GTK_BUTTON(save));
        Wait([&]{return std::string(gtk_label_get_text(GTK_LABEL(get("capsule-status")))).find("条目已被修改")!=std::string::npos;});
        Check(Text(body)=="conflicting local draft","conflict lost draft");
        Check(store.Get(saved.id,&saved,&error)==StoreStatus::Ok && saved.content=="external revision","conflict overwrote external edit");
        // A clean editor can start a new entry without a subsequent harmless
        // host refresh restoring the previously selected saved entry.
        {
            store.ListAll(&records,&error);model.LoadCards(records);
            ManagerWindow fresh([](const std::string&){});fresh.Apply(MakeSnapshot(model));
            auto* fresh_title=Find(fresh.Root(),"capsule-title");
            Wait([&]{return std::string(gtk_entry_get_text(GTK_ENTRY(fresh_title)))==saved.title;});
            gtk_button_clicked(GTK_BUTTON(Find(fresh.Root(),"capsule-new")));
            fresh.Apply(MakeSnapshot(model));
            Check(std::string(gtk_entry_get_text(GTK_ENTRY(fresh_title))).empty(),"host refresh discarded the new-note editor");
        }
        {
            std::vector<Record> many(400,saved);
            for(auto& record:many) record.id=NewUuidV4();
            CapsuleModel paged; paged.LoadCards(many); paged.set_visible(true); paged.set_managing(true);
            ManagerWindow* receiver=nullptr;
            ManagerWindow library([&](const std::string& raw) {
                auto command=Json::parse(raw);
                if(command.at("op")=="select") { paged.Select(command.at("index")); receiver->Apply(MakeSnapshot(paged)); }
            },true);receiver=&library;library.Apply(MakeSnapshot(paged));
            auto* scroll=Find(library.Root(),"capsule-list");
            auto* viewport=gtk_bin_get_child(GTK_BIN(scroll));
            auto* rows=gtk_bin_get_child(GTK_BIN(viewport));
            auto* children=gtk_container_get_children(GTK_CONTAINER(rows));
            gtk_widget_grab_focus(GTK_WIDGET(children->data));g_list_free(children);
            GdkEventKey key{};key.type=GDK_KEY_PRESS;key.keyval=GDK_KEY_End;gboolean handled=FALSE;
            g_signal_emit_by_name(library.Window(),"key-press-event",&key,&handled);
            Check(handled && paged.selected()==399,"manager could not navigate beyond the first transport window");
            key.keyval=GDK_KEY_Page_Up;handled=FALSE;
            g_signal_emit_by_name(library.Window(),"key-press-event",&key,&handled);
            Check(handled && paged.selected()==391,"manager lost list focus while replacing transport window");
        }
        std::cout<<"GTK manager save, protected draft recovery, revocation and concurrent-edit conflict passed\n";
    } catch(const std::exception& error) {std::cerr<<error.what()<<'\n';std::filesystem::remove_all(root);return 1;}
    std::filesystem::remove_all(root);return 0;
}
