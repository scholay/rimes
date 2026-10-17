#include "capsule_manager.hpp"
#include "background_jobs.hpp"
#include "desktop.hpp"
#include "private_files.hpp"
#include "official_catalog.hpp"
#include <optional>
#include <algorithm>
#include <filesystem>
#include <utility>
namespace rimes::capsule {
using namespace rimes::desktop;
namespace {
void Post(std::function<void()> work) {
    g_idle_add_full(G_PRIORITY_DEFAULT, +[](gpointer raw) -> gboolean {
        auto& fn = *static_cast<std::function<void()>*>(raw); fn(); return G_SOURCE_REMOVE;
    }, new std::function<void()>(std::move(work)), +[](gpointer raw) { delete static_cast<std::function<void()>*>(raw); });
}
std::string Text(GtkWidget* text) {
    auto* buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(text));
    GtkTextIter begin{}, end{}; gtk_text_buffer_get_bounds(buffer, &begin, &end);
    auto* value = gtk_text_buffer_get_text(buffer, &begin, &end, FALSE);
    std::string result = value; g_free(value); return result;
}
GtkWidget* Scroll(GtkWidget* child) {
    auto* scroll = gtk_scrolled_window_new(nullptr,nullptr);
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll),GTK_POLICY_NEVER,GTK_POLICY_AUTOMATIC);
    gtk_container_add(GTK_CONTAINER(scroll),child); return scroll;
}
}
struct ManagerWindow::Impl {
    Send send;
    GtkWidget *window, *root, *header, *modules, *modules_scroll, *toolbar, *list, *list_scroll, *editor;
    GtkWidget *count, *search, *create, *hint, *title, *summary, *format, *body, *status, *save, *remove, *divider, *heading;
    GtkCssProvider* css = gtk_css_provider_new();
    Snapshot state;
    Record draft;
    bool dirty = false, updating = false, preview = false, writing = false;
    int layout_width = 0, layout_height = 0;
    std::string detail_key, theme;
    runtime::BackgroundJobs jobs;
    std::shared_ptr<std::atomic<bool>> alive = std::make_shared<std::atomic<bool>>(true);
    std::shared_ptr<std::atomic<bool>> read_cancel, write_cancel;
    std::unique_ptr<plugins::PackageStore> packages;
    std::optional<Record> suspended_draft;
    std::string suspended_key;
    Record CaptureDraft() const {
        Record value=draft;
        value.title=gtk_entry_get_text(GTK_ENTRY(title)); value.summary=gtk_entry_get_text(GTK_ENTRY(summary)); value.content=Text(body);
        value.note_format=gtk_combo_box_get_active(GTK_COMBO_BOX(format))==1?"bullet":draft.note_format=="rich-text"?"rich-text":"other";
        return value;
    }
    void FillDraft() {
        updating=true;
        gtk_entry_set_text(GTK_ENTRY(title),draft.title.c_str());
        gtk_entry_set_text(GTK_ENTRY(summary),draft.summary.c_str());
        gtk_combo_box_set_active(GTK_COMBO_BOX(format),draft.note_format=="bullet"?1:draft.note_format=="rich-text"?2:0);
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(GTK_TEXT_VIEW(body)),draft.content.c_str(),-1);
        updating=false;
        gtk_label_set_text(GTK_LABEL(heading),draft.id.empty()?"新建笔记":"编辑笔记"); Controls();
    }
    Impl(Send callback, bool fixture) : send(std::move(callback)), preview(fixture) {
        if (!preview) packages=std::make_unique<plugins::PackageStore>(runtime::UserRoot()/"plugins", plugins::OfficialCatalog(), plugins::BundledPackages(), plugins::CompiledAdapters(), RIMES_PRODUCT_VERSION);
        window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
        gtk_window_set_title(GTK_WINDOW(window), "Capsule");
        gtk_window_set_decorated(GTK_WINDOW(window),FALSE);
        gtk_window_set_default_size(GTK_WINDOW(window),940,660);
        GdkGeometry geometry{}; geometry.min_width=620; geometry.min_height=430;
        gtk_window_set_geometry_hints(GTK_WINDOW(window),nullptr,&geometry,GDK_HINT_MIN_SIZE);
        root = Class(gtk_layout_new(nullptr,nullptr),"capsule-manager"); gtk_container_add(GTK_CONTAINER(window),root);
        g_signal_connect(root,"draw",G_CALLBACK(+[](GtkWidget* widget,cairo_t* cr,gpointer)->gboolean {
            gtk_render_background(gtk_widget_get_style_context(widget),cr,0,0,gtk_widget_get_allocated_width(widget),gtk_widget_get_allocated_height(widget)); return FALSE;
        }),nullptr);
        header = Row(9); auto* caption=Label("Capsule","capsule-heading"); Add(header,caption);
        count=Label("0 ITEMS","capsule-count"); Add(header,count); Add(header,gtk_label_new(""),true);
        Add(header,Button("Capsule 插件…",[this] { g_spawn_command_line_async("rimes-settings",nullptr); },"capsule-link"));
        Add(header,Class(IconButton("gearshape","返回 Capsule 底栏",[this] { Navigate({{"v",1},{"op","rail"}}); }),"capsule-gear"));
        Add(header,Class(IconButton("xmark","关闭 Capsule",[this] { Navigate({{"v",1},{"op","close"}}); }),"capsule-close"));
        modules=Column(3); modules_scroll=Class(Scroll(modules),"capsule-modules");
        gtk_widget_set_margin_start(modules,8); gtk_widget_set_margin_end(modules,8);
        gtk_widget_set_margin_top(modules,10); gtk_widget_set_margin_bottom(modules,10);
        toolbar=Row(8); search=gtk_search_entry_new(); gtk_entry_set_placeholder_text(GTK_ENTRY(search),"搜索标题或内容");
        gtk_widget_set_tooltip_text(search,"搜索 Capsule"); Add(toolbar,search,true);
        create=Button("＋ 新建",[this] { NewNote(); }); Add(toolbar,create);
        list=Column(1); list_scroll=Class(Scroll(list),"capsule-list"); divider=Class(gtk_separator_new(GTK_ORIENTATION_VERTICAL),"capsule-divider");
        gtk_widget_set_margin_top(list,10); gtk_widget_set_margin_start(list,16); gtk_widget_set_margin_end(list,16);
        editor=Class(Column(8),"capsule-editor");
        auto* form=Column(10); gtk_widget_set_margin_start(form,16); gtk_widget_set_margin_end(form,16);
        gtk_widget_set_margin_top(form,16); gtk_widget_set_margin_bottom(form,16);
        heading=Label("新建笔记","capsule-form-heading"); Add(form,heading);
        auto field=[&](const char* name,GtkWidget* widget,bool expands=false) {
            auto* stack=Column(5); Add(stack,Label(name,"capsule-field-label")); Add(stack,widget,expands); Add(form,stack,expands);
        };
        title=Class(gtk_entry_new(),"capsule-field"); gtk_entry_set_placeholder_text(GTK_ENTRY(title),"标题"); field("标题",title);
        summary=Class(gtk_entry_new(),"capsule-field"); gtk_entry_set_placeholder_text(GTK_ENTRY(summary),"一句话说明，显示在卡片上（可选）"); field("摘要",summary);
        format=gtk_combo_box_text_new();
        for (const auto* name:{"其他","Bullet","富文本"}) gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(format),name);
        field("笔记类型",format);
        body=gtk_text_view_new(); gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(body),GTK_WRAP_WORD_CHAR);
        gtk_text_view_set_left_margin(GTK_TEXT_VIEW(body),14); gtk_text_view_set_right_margin(GTK_TEXT_VIEW(body),14);
        gtk_text_view_set_top_margin(GTK_TEXT_VIEW(body),10); gtk_text_view_set_bottom_margin(GTK_TEXT_VIEW(body),10);
        auto* area=Class(Scroll(body),"capsule-text"); gtk_widget_set_size_request(area,-1,220); field("内容",area,true);
        auto* writing_hint=Label("写法：「- 标签：值」是字段，复制时只复制值；「## 标题」分组；其余每行单独复制。","capsule-writing-hint");
        gtk_label_set_line_wrap(GTK_LABEL(writing_hint),TRUE); gtk_label_set_max_width_chars(GTK_LABEL(writing_hint),1); Add(form,writing_hint);
        Add(editor,Scroll(form),true);
        auto* actions=Row(8); gtk_widget_set_margin_start(actions,16); gtk_widget_set_margin_end(actions,16); gtk_widget_set_margin_bottom(actions,12);
        status=Label("选择一条 Capsule 内容","capsule-status"); Add(actions,status,true);
        remove=Button("删除",[this] { Remove(); },"capsule-link"); Add(actions,remove);
        save=Button("保存",[this] { Save(); }); Add(actions,save); Add(editor,actions);
        for(const auto& item:std::initializer_list<std::pair<GtkWidget*,const char*>>{
            {title,"capsule-title"},{summary,"capsule-summary"},{body,"capsule-body"},{format,"capsule-format"},
            {save,"capsule-save"},{remove,"capsule-delete"},{create,"capsule-new"},{status,"capsule-status"},
            {modules_scroll,"capsule-modules"},{list_scroll,"capsule-list"},{editor,"capsule-editor"},
            {header,"capsule-header"},{toolbar,"capsule-toolbar"}})
            gtk_widget_set_name(item.first,item.second);
        hint=Label("管理本机 Capsule","capsule-hint"); gtk_label_set_xalign(GTK_LABEL(hint),0);
        for (auto* child : {header,modules_scroll,toolbar,list_scroll,divider,editor,hint}) gtk_layout_put(GTK_LAYOUT(root),child,0,0);
        g_signal_connect(root,"size-allocate",G_CALLBACK(+[](GtkWidget*,GtkAllocation* bounds,gpointer data) {
            auto* self=static_cast<Impl*>(data);
            if(self->layout_width==bounds->width && self->layout_height==bounds->height) return;
            self->layout_width=bounds->width; self->layout_height=bounds->height;
            // GtkLayout allocates its children before emitting this signal.
            // Queue the geometry change outside that allocation, so GTK can
            // honor the new child requests without imposing a minimum window
            // size based on the previous (larger) allocation.
            auto life=self->alive;
            Post([self,life] { if(life->load()) self->Layout(self->layout_width,self->layout_height); });
        }),this);
        g_signal_connect(search,"search-changed",G_CALLBACK(+[](GtkSearchEntry* entry,gpointer data) {
            auto* self=static_cast<Impl*>(data);
            if (!self->updating) self->Navigate({{"v",1},{"op","search"},{"text",gtk_entry_get_text(GTK_ENTRY(entry))}});
        }),this);
        g_signal_connect(summary,"changed",G_CALLBACK(+[](GtkEditable*,gpointer data) { static_cast<Impl*>(data)->Changed(); }),this);
        g_signal_connect(format,"changed",G_CALLBACK(+[](GtkComboBox*,gpointer data) { static_cast<Impl*>(data)->Changed(); }),this);
        g_signal_connect(title,"changed",G_CALLBACK(+[](GtkEditable*,gpointer data) { static_cast<Impl*>(data)->Changed(); }),this);
        g_signal_connect(gtk_text_view_get_buffer(GTK_TEXT_VIEW(body)),"changed",G_CALLBACK(+[](GtkTextBuffer*,gpointer data) { static_cast<Impl*>(data)->Changed(); }),this);
        g_signal_connect(window,"delete-event",G_CALLBACK(+[](GtkWidget*,GdkEvent*,gpointer data)->gboolean {
            static_cast<Impl*>(data)->Navigate({{"v",1},{"op","close"}}); return TRUE;
        }),this);
        g_signal_connect(window,"key-press-event",G_CALLBACK(+[](GtkWidget*,GdkEventKey* event,gpointer data)->gboolean {
            auto* self=static_cast<Impl*>(data);
            if (event->keyval==GDK_KEY_Escape) { self->Navigate({{"v",1},{"op","rail"}}); return TRUE; }
            if ((event->state&GDK_CONTROL_MASK) && event->keyval==GDK_KEY_s) { self->Save(); return TRUE; }
            auto* focused=gtk_window_get_focus(GTK_WINDOW(self->window));
            if(focused && gtk_widget_is_ancestor(focused,self->list)) {
                const int current=self->state.offset+self->state.selected;
                int next=current;
                switch(event->keyval) {
                case GDK_KEY_Up: next=current-1; break;
                case GDK_KEY_Down: next=current+1; break;
                case GDK_KEY_Home: next=0; break;
                case GDK_KEY_End: next=self->state.count-1; break;
                case GDK_KEY_Page_Up: next=current-8; break;
                case GDK_KEY_Page_Down: next=current+8; break;
                default: return FALSE;
                }
                if(self->state.count) self->Navigate({{"v",1},{"op","select"},{"index",std::clamp(next,0,self->state.count-1)}});
                return TRUE;
            }
            return FALSE;
        }),this);
        SetTheme("night"); ClearDraft();
    }
    ~Impl() {
        alive->store(false); jobs.Shutdown();
        g_signal_handlers_disconnect_by_data(window,this);
        gtk_widget_destroy(window); g_object_unref(css);
    }
    void Layout(int width,int height) {
        gtk_layout_set_size(GTK_LAYOUT(root),width,height);
        const auto& metrics=ModuleContract().at("metrics");
        const int inset=metrics.at("headerInset"); const int module_width=metrics.at("moduleWidth");
        const int list_width=std::clamp(static_cast<int>(width*metrics.at("listFraction").get<double>()),170,286);
        const int list_x=inset+module_width+10, rule_x=list_x+list_width+12, editor_x=rule_x+15;
        auto place=[&](GtkWidget* child,int x,int y,int w,int h) { gtk_layout_move(GTK_LAYOUT(root),child,x,y); gtk_widget_set_size_request(child,std::max(w,1),std::max(h,1)); };
        place(header,inset,12,width-2*inset,30); place(modules_scroll,inset,56,module_width,height-86);
        place(toolbar,list_x,56,list_width,22); place(list_scroll,list_x,90,list_width,height-120);
        place(divider,rule_x,56,1,height-86); place(editor,editor_x,56,width-editor_x-inset,height-86);
        place(hint,inset,height-20,width-2*inset,10);
    }
    void SetTheme(const std::string& name) {
        theme=name; Theme(name,gtk_widget_get_screen(window));
        const auto& palette=Visuals().at("palettes").at(name=="liquidGlass"?"day":name);
        auto c=[&](const char* key){ return palette.at(key).get<std::string>(); };
        const std::string rules=
            ".capsule-manager { background: "+c("bufferBackground")+"; color: "+c("textPrimary")+"; border-radius: 14px; }"
            ".capsule-manager viewport { background: transparent; }"
            ".capsule-heading { font-family: monospace; font-size: 15px; font-weight: bold; }"
            ".capsule-count { font-family: monospace; font-size: 10px; color: "+c("textSecondary")+"; }"
            ".capsule-hint { font-family: monospace; font-size: 9px; color: "+c("textSecondary")+"; }"
            ".capsule-list,.capsule-editor { background: "+c("surfaceSecondary")+"; border: 1px solid "+c("border")+"; border-radius: 6px; }"
            ".capsule-modules { background: transparent; border: 0; }"
            ".capsule-manager textview,.capsule-manager textview text { font-family: monospace; font-size: 12px; background: "+c("surfaceTertiary")+"; color: "+c("textPrimary")+"; }"
            ".capsule-manager entry { min-height: 0; padding: 0 3px; font-family: monospace; font-size: 11px; }"
            ".capsule-manager .capsule-field { border-radius: 0; font-size: 12px; }"
            ".capsule-manager combobox button { min-height: 18px; padding: 0 5px; }"
            ".capsule-manager .capsule-text { border: 1px solid "+c("border")+"; }"
            ".capsule-form-heading,.capsule-field-label { font-family: monospace; font-size: 9px; font-weight: 600; color: "+c("textSecondary")+"; }"
            ".capsule-form-heading { font-size: 10px; color: "+c("accentText")+"; }"
            ".capsule-writing-hint,.capsule-status { font-family: monospace; font-size: 9px; color: "+c("textMuted")+"; }"
            ".capsule-writing-hint { font-size: 10px; }"
            ".capsule-manager .capsule-link label { font-family: monospace; font-size: 9px; font-weight: 600; color: "+c("textSecondary")+"; }"
            ".capsule-module,.capsule-filter,.capsule-link { background: alpha("+c("textSecondary")+",0.10); padding: 0 5px; min-height: 16px; border-radius: 12px; }"
            ".capsule-manager .capsule-gear { min-width: 22px; min-height: 22px; background: alpha("+c("accentGreen")+",0.2); border-radius: 6px; }"
            ".capsule-manager .capsule-close { min-width: 16px; min-height: 16px; }"
            ".capsule-module label { font-size: 12px; font-weight: 500; color: "+c("textPrimary")+"; }"
            ".capsule-module.selected label { font-weight: bold; } .capsule-filter label { font-size: 10px; color: "+c("textSecondary")+"; }"
            ".capsule-filter.selected label { color: "+c("accentText")+"; font-weight: 600; }"
            ".capsule-entry { background: transparent; border-radius: 0; padding: 0 10px; min-height: 0; }"
            ".capsule-entry.selected { background: alpha("+c("accentGreen")+",0.10); }"
            ".capsule-entry label { font-family: monospace; color: "+c("textPrimary")+"; } .capsule-entry .caption { font-size: 9px; color: "+c("textSecondary")+"; }"
            ".capsule-entry .capsule-kind { font-size: 8px; color: "+c("textSecondary")+"; }"
            ".capsule-entry.selected .name,.capsule-entry.selected .capsule-kind { color: "+c("accentText")+"; }"
            ".capsule-divider { background: "+c("border")+"; min-width: 1px; }";
        gtk_css_provider_load_from_data(css,rules.c_str(),-1,nullptr);
        gtk_style_context_add_provider_for_screen(gtk_widget_get_screen(window),GTK_STYLE_PROVIDER(css),GTK_STYLE_PROVIDER_PRIORITY_APPLICATION+2);
    }
    void SendCommand(const std::string& op,const std::string& id="") { send(Json{{"v",1},{"op",op},{"id",id}}.dump()); }
    bool Discard() {
        if (writing) return false;
        if (dirty && !Confirm(GTK_WINDOW(window),"放弃未保存的修改？","当前编辑尚未保存。")) return false;
        dirty=false; return true;
    }
    void Navigate(Json command) { if (command.at("op")=="search" || Discard()) send(command.dump()); }
    void Changed() { if (!updating) { dirty=true; gtk_label_set_text(GTK_LABEL(status),"未保存的修改"); Controls(); } }
    void ClearDraft() {
        if (read_cancel) read_cancel->store(true);
        draft=Record{}; detail_key.clear(); dirty=false; FillDraft();
    }
    void Controls() {
        const bool notes=state.module=="notes" && std::find(state.modules.begin(),state.modules.end(),Module::Notes)!=state.modules.end();
        const bool editable=notes && state.visible && state.managing && !state.password_field && !writing && (draft.id.empty() || draft.note_format!="rich-text");
        gtk_editable_set_editable(GTK_EDITABLE(title),editable); gtk_text_view_set_editable(GTK_TEXT_VIEW(body),editable);
        gtk_widget_set_sensitive(create,notes && !writing); gtk_widget_set_sensitive(save,editable);
        gtk_widget_set_sensitive(remove,!draft.id.empty() && !writing && notes);
        gtk_editable_set_editable(GTK_EDITABLE(summary),editable);
        gtk_widget_set_sensitive(format,editable);
        gtk_widget_set_sensitive(search,!writing);
    }
    void NewNote() {
        if (state.module!="notes" || !Discard()) return;
        ClearDraft(); draft.kind=Kind::Note;
        dirty=true; Controls();
        gtk_label_set_text(GTK_LABEL(status),"新建笔记"); gtk_widget_grab_focus(title);
    }
    void Detail(const Card* card) {
        if (!card) { if (!dirty) ClearDraft(); return; }
        const auto key=card->id+":"+card->revision;
        if (key==detail_key || dirty || writing) return;
        ClearDraft(); detail_key=key;
        if (card->module==Module::Passwords || card->module==Module::Temporary) {
            gtk_label_set_text(GTK_LABEL(status),card->preview.c_str()); return;
        }
        if (preview) {
            draft.id=card->id; draft.title=card->title; draft.content=card->payload.empty()?card->preview:card->payload; FillDraft();
            gtk_label_set_text(GTK_LABEL(status),(std::to_string(state.count)+" 条本地记录").c_str()); return;
        }
        read_cancel=std::make_shared<std::atomic<bool>>(false);
        const auto cancelled=read_cancel; const auto id=card->id; const auto revision=card->revision;
        const auto storage=ContentStore::DefaultRoot(); auto life=alive;
        jobs.Run(cancelled,[this,life,cancelled,id,revision,key,storage] {
            ContentStore store(storage); Record value; std::string error;
            const auto result=store.Get(id,&value,&error);
            if (!life->load() || cancelled->load()) return;
            Post([this,life,cancelled,key,revision,result,value=std::move(value)] {
                if (!life->load() || cancelled->load() || !state.visible || !state.managing || state.password_field || detail_key!=key) return;
                if (result!=StoreStatus::Ok || value.revision!=revision) { gtk_label_set_text(GTK_LABEL(status),"条目已变动，请重新选择"); return; }
                draft=value; FillDraft(); gtk_label_set_text(GTK_LABEL(status),value.note_format=="rich-text"?"富文本原始附件已保留":"本机条目"); Controls();
            });
        });
    }
    void Save() {
        if (preview || writing || state.module!="notes" || state.password_field || !state.visible) return;
        Record value=CaptureDraft();
        if (value.note_format=="rich-text") return;
        if (gtk_combo_box_get_active(GTK_COMBO_BOX(format))==2) {
            gtk_label_set_text(GTK_LABEL(status),"富文本编辑尚不可用，当前草稿已保留"); return;
        }
        if (value.title.empty() || value.content.empty()) { gtk_label_set_text(GTK_LABEL(status),"请填写标题和内容"); return; }
        Write(std::move(value),false);
    }
    void Remove() {
        if (preview || writing || draft.id.empty() || !Discard() ||
            !Confirm(GTK_WINDOW(window),"删除这条笔记？","仅删除当前条目，附件文件仍保留。")) return;
        Write(draft,true);
    }
    void Write(Record value,bool removing) {
        const auto storage=ContentStore::DefaultRoot(); auto life=alive;
        const auto authority=packages->Inspect(ModulePlugin(Module::Notes));
        if (!authority.enabled) { gtk_label_set_text(GTK_LABEL(status),"笔记插件已停用，草稿已保留"); return; }
        write_cancel=std::make_shared<std::atomic<bool>>(false); const auto cancelled=write_cancel;
        writing=true; Controls(); gtk_label_set_text(GTK_LABEL(status),"正在保存…");
        auto complete=[this,life,removing](StoreStatus result,Record saved) {
            if (!life->load()) return;
            Post([this,life,result,saved=std::move(saved),removing] {
                if (!life->load()) return;
                writing=false;
                if (result==StoreStatus::Ok) {
                    dirty=false; suspended_draft.reset(); ClearDraft();
                    if (state.visible && state.managing && !state.password_field) SendCommand("refresh",removing?"":saved.id);
                } else {
                    if (suspended_draft && state.visible && state.managing && !state.password_field && state.module=="notes") {
                        draft=*suspended_draft; detail_key=suspended_key; FillDraft(); dirty=true; suspended_draft.reset();
                    }
                    gtk_label_set_text(GTK_LABEL(status),result==StoreStatus::RevisionConflict?"条目已被修改，草稿已保留；重新读取后再保存":"保存失败，草稿已保留");
                }
                Controls();
            });
        };
        auto work=[this,storage,value=std::move(value),removing,cancelled,grant=authority.grant,complete] {
            ContentStore store(storage); Record saved; std::string error;
            auto result=StoreStatus::Invalid;
            try {
                packages->WithEnabledGrant(ModulePlugin(Module::Notes),grant,[&] {
                    if (!cancelled->load()) result=removing?store.Remove(value.id,value.revision,&error):store.Put(value,value.revision,&saved,&error);
                });
            } catch (const std::exception&) { /* Revoked operations retain the draft. */ }
            complete(result,std::move(saved));
        };
        if(!jobs.Run(cancelled,std::move(work),[complete]{complete(StoreStatus::Invalid,{});})) complete(StoreStatus::Invalid,{});
    }

    void Apply(const Snapshot& snapshot) {
        const bool notes_enabled=std::find(snapshot.modules.begin(),snapshot.modules.end(),Module::Notes)!=snapshot.modules.end();
        if (dirty && state.module=="notes" && (!snapshot.visible || !snapshot.managing || snapshot.password_field || snapshot.module!="notes" || !notes_enabled)) {
            suspended_draft=CaptureDraft(); suspended_key=detail_key;
        }
        state=snapshot;
        if (theme!=state.theme) SetTheme(state.theme);
        if (!state.visible || !state.managing || state.password_field) {
            // Ordinary close/navigation has already asked about drafts. A
            // protection/revocation transition must conceal immediately.
            if (write_cancel) write_cancel->store(true);
            ClearDraft(); gtk_widget_hide(window); return;
        }
        const bool enabled=std::any_of(state.modules.begin(),state.modules.end(),[&](auto module){return state.module==ModuleRaw(module);});
        if (!enabled || state.module!="notes") {
            if(write_cancel) write_cancel->store(true);
            ClearDraft();
        } else if(suspended_draft && !writing) {
            draft=*suspended_draft; detail_key=suspended_key; FillDraft(); dirty=true;
            suspended_draft.reset(); gtk_label_set_text(GTK_LABEL(status),"已恢复未保存的草稿");
        }
        updating=true;
        if (state.query!=gtk_entry_get_text(GTK_ENTRY(search))) gtk_entry_set_text(GTK_ENTRY(search),state.query.c_str());
        updating=false;
        gtk_label_set_text(GTK_LABEL(count),CountText(state.count).c_str()); gtk_label_set_text(GTK_LABEL(hint),state.hint.c_str());
        Clear(modules);
        for (auto module : state.modules) {
            const auto& definition=ModuleDefinition(module); const bool selected=state.module==ModuleRaw(module);
            auto* button=Button(definition.at("title"),[this,module] { Navigate({{"v",1},{"op","module"},{"text",ModuleRaw(module)}}); },"capsule-module");
            gtk_button_set_image(GTK_BUTTON(button),Icon(definition.at("icon"),11)); gtk_button_set_always_show_image(GTK_BUTTON(button),TRUE);
            if(selected) Class(button,"selected");
            gtk_widget_set_halign(button,GTK_ALIGN_START); Add(modules,button);
            if(selected) for(const auto& filter:definition.at("filters")) {
                auto* choice=Button(filter.at("title"),[this,id=filter.at("id").get<std::string>()] { Navigate({{"v",1},{"op","filter"},{"text",id}}); },"capsule-filter");
                if(state.filter==filter.at("id")) Class(choice,"selected");
                gtk_widget_set_halign(choice,GTK_ALIGN_START); Add(modules,choice);
            }
        }
        auto* focused=gtk_window_get_focus(GTK_WINDOW(window));
        const bool list_focused=focused && gtk_widget_is_ancestor(focused,list);
        Clear(list);
        const Card* selected=nullptr;
        GtkWidget* selected_row=nullptr;
        for(const auto& card:state.cards) {
            auto* row=Button("",[this,id=card.id] { Navigate({{"v",1},{"op","select"},{"id",id}}); },"capsule-entry");
            auto* column=Column(4); auto* row_heading=Row(7); auto* name=Label(card.title,"name"); auto* summary=Label(card.preview,"caption");
            std::string kind=KindRaw(card.kind); std::transform(kind.begin(),kind.end(),kind.begin(),[](unsigned char c){return std::toupper(c);});
            Add(row_heading,Label(kind,"capsule-kind")); Add(row_heading,name,true);
            gtk_widget_set_valign(column,GTK_ALIGN_CENTER); gtk_widget_set_size_request(row,-1,56);
            for(auto* label:{name,summary}) { gtk_label_set_xalign(GTK_LABEL(label),0); gtk_label_set_ellipsize(GTK_LABEL(label),PANGO_ELLIPSIZE_END); gtk_label_set_max_width_chars(GTK_LABEL(label),1); }
            Add(column,row_heading); Add(column,summary);
            gtk_widget_destroy(gtk_bin_get_child(GTK_BIN(row))); gtk_container_add(GTK_CONTAINER(row),column);
            if(card.id==(dirty?draft.id:state.selected_id)) Class(row,"selected");
            if(card.id==state.selected_id) { selected=&card; selected_row=row; }
            Add(list,row);
        }
        if(state.cards.empty()) Add(list,Label(state.loading?"正在读取…":"暂无条目","caption"));
        Detail(selected); Controls();
        const bool opening=!gtk_widget_get_visible(window);
        gtk_widget_show_all(window); if(opening) gtk_window_present(GTK_WINDOW(window));
        if(list_focused && selected_row) gtk_widget_grab_focus(selected_row);
    }
};
ManagerWindow::ManagerWindow(Send send,bool preview):impl_(std::make_unique<Impl>(std::move(send),preview)){}
ManagerWindow::~ManagerWindow()=default;
void ManagerWindow::Apply(const Snapshot& snapshot){impl_->Apply(snapshot);}
GtkWidget* ManagerWindow::Window() const{return impl_->window;}
GtkWidget* ManagerWindow::Root() const{return impl_->root;}
}
