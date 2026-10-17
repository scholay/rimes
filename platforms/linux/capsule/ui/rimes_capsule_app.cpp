#include "../../product_brand.hpp"
#include "buffer_protocol.hpp"
#include "capsule_click.hpp"
#include "capsule_clipboard.hpp"
#include "capsule_kinds.hpp"
#include "capsule_protocol.hpp"
#include "desktop.hpp"
#include "panel_window.hpp"
#include "capsule_manager.hpp"

#include <gdk/gdk.h>
#include <gtk/gtk.h>

#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif
#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/gdkwayland.h>
#endif

#ifdef HAVE_GTK_LAYER_SHELL
#include <gtk-layer-shell.h>
#endif

#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <cstdint>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

constexpr int kWindowWidth = rimes::capsule::kRailWidth;
constexpr int kWindowHeight = rimes::capsule::kRailHeight;

struct App {
    GtkWidget* window = nullptr;
    GtkWidget* tab_box = nullptr;
    GtkWidget* filter_box = nullptr;
    std::unique_ptr<rimes::capsule::ManagerWindow> manager;
    GtkWidget* count = nullptr;
    GtkWidget* card_box = nullptr;
    GtkWidget* hint = nullptr;
    GtkWidget* query = nullptr;
    int socket_fd = -1;
    guint io_id = 0;
    std::string incoming;
    std::string dump_geometry;
    bool quit_after_dump = false;
    bool dumped_geometry = false;
    rimes::capsule::Snapshot snapshot;
    bool wayland_layer = false;
    bool preview = false;
    bool placed = false;
    std::string theme;
    std::unique_ptr<rimes::desktop::PanelWindow> panel;
    struct CardRow {
        std::string id;
        GtkWidget* event = nullptr;
        GtkWidget* title = nullptr;
        GtkWidget* preview = nullptr;
    };
    std::vector<CardRow> card_rows;
    int last_press_index = -1;
    std::int64_t last_press_ms = -1;
    bool seen_copy_seq = false;
    std::uint64_t handled_copy_seq = 0;
};

App* g_app = nullptr;

std::string DefaultSocketPath() {
    if (const char* override_path = g_getenv("RIMES_CAPSULE_SOCKET")) {
        if (override_path[0] != '\0') {
            return override_path;
        }
    }
    if (const char* runtime = g_getenv("XDG_RUNTIME_DIR")) {
        return std::string(runtime) + "/rimes-capsule.sock";
    }
    return "/tmp/rimes-capsule-" + std::to_string(geteuid()) + ".sock";
}

bool SendCommand(App* app, const std::string& json) {
    std::string frame;
    if (app->socket_fd < 0 || !rimes::buffer::EncodeFrame(json, &frame)) {
        return false;
    }
    return send(app->socket_fd, frame.data(), frame.size(), MSG_NOSIGNAL) ==
           static_cast<ssize_t>(frame.size());
}

void WriteGeometryDump(App* app) {
    if (app->dump_geometry.empty() || app->dumped_geometry) {
        return;
    }
    GtkAllocation allocation{};
    gtk_widget_get_allocation(app->window, &allocation);
    if (allocation.width < 2 || allocation.height < 2) {
        gtk_window_get_size(GTK_WINDOW(app->window), &allocation.width, &allocation.height);
    }
    if (allocation.width < 2 && !app->quit_after_dump) {
        return;
    }
    gint request_w = 0;
    gint request_h = 0;
    gtk_widget_get_size_request(app->window, &request_w, &request_h);
    FILE* file = std::fopen(app->dump_geometry.c_str(), "w");
    if (file == nullptr) {
        return;
    }
    std::fprintf(file,
                 "{\"width\":%d,\"height\":%d,\"size_request_w\":%d,\"size_request_h\":%d,"
                 "\"layer\":%s,\"min_width\":%d,\"min_height\":%d}\n",
                 allocation.width, allocation.height, request_w, request_h,
                 app->wayland_layer ? "true" : "false", kWindowWidth, kWindowHeight);
    std::fclose(file);
    app->dumped_geometry = true;
    if (app->quit_after_dump) {
        gtk_main_quit();
    }
}

void OnSizeAllocate(GtkWidget* /*widget*/, GdkRectangle* allocation, gpointer data) {
    if (allocation == nullptr || allocation->width < 2 || allocation->height < 2) {
        return;
    }
    WriteGeometryDump(static_cast<App*>(data));
}

void ClearBox(GtkWidget* box) {
    GList* children = gtk_container_get_children(GTK_CONTAINER(box));
    for (GList* item = children; item != nullptr; item = item->next) {
        gtk_widget_destroy(GTK_WIDGET(item->data));
    }
    g_list_free(children);
}

void RebuildTabs(App* app) {
    ClearBox(app->tab_box); ClearBox(app->filter_box);
    for (auto module : app->snapshot.modules) {
        const auto& definition = rimes::capsule::ModuleDefinition(module);
        auto* button = rimes::desktop::Button(definition.at("title"), [app, module] {
            SendCommand(app, rimes::desktop::Json{{"v",1},{"op","module"},{"text",rimes::capsule::ModuleRaw(module)}}.dump());
        }, "rimes-tab");
        if (rimes::capsule::ModuleRaw(module) == app->snapshot.module) rimes::desktop::Class(button,"rimes-tab-active");
        gtk_widget_set_can_focus(button,FALSE);
        gtk_box_pack_start(GTK_BOX(app->tab_box),button,FALSE,FALSE,0);
    }
    if (const auto module = rimes::capsule::ModuleFromRaw(app->snapshot.module)) {
        for (const auto& filter : rimes::capsule::ModuleDefinition(*module).at("filters")) {
            auto* button = rimes::desktop::Button(filter.at("title"), [app, id = filter.at("id").get<std::string>()] {
                SendCommand(app, rimes::desktop::Json{{"v",1},{"op","filter"},{"text",id}}.dump());
            }, "rimes-filter");
            if (filter.at("id") == app->snapshot.filter) rimes::desktop::Class(button,"selected");
            gtk_widget_set_size_request(button,60,18); gtk_widget_set_can_focus(button,FALSE);
            gtk_box_pack_start(GTK_BOX(app->filter_box),button,FALSE,FALSE,0);
        }
    }
    gtk_widget_show_all(app->tab_box); gtk_widget_show_all(app->filter_box);
}

gboolean OnCardButtonPress(GtkWidget* self, GdkEventButton* ev, gpointer data) {
    auto* host = static_cast<App*>(data);
    const int index = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(self), "index"));
    const std::int64_t now_ms = g_get_monotonic_time() / 1000;
    const bool gdk_double = ev != nullptr && ev->type == GDK_2BUTTON_PRESS;
    const bool activate = rimes::capsule::ShouldActivateOnPress(
        index, host->last_press_index, now_ms, host->last_press_ms, gdk_double);
    const std::string select =
        rimes::desktop::Json{{"v",1},{"op","select"},{"id",host->snapshot.cards.at(index).id}}.dump();
    SendCommand(host, select);
    if (activate) {
        SendCommand(host, rimes::desktop::Json{{"v",1},{"op","activate"},{"id",host->snapshot.cards.at(index).id}}.dump());
    }
    host->last_press_index = index;
    host->last_press_ms = now_ms;
    return TRUE;
}

void SetCardSelectedStyle(GtkWidget* event, bool selected) {
    GtkStyleContext* context = gtk_widget_get_style_context(event);
    if (selected) {
        gtk_style_context_add_class(context, "rimes-card-selected");
    } else {
        gtk_style_context_remove_class(context, "rimes-card-selected");
    }
}

bool CardsMatchIds(const App* app) {
    if (app->card_rows.size() != app->snapshot.cards.size()) {
        return false;
    }
    for (std::size_t i = 0; i < app->card_rows.size(); ++i) {
        if (app->card_rows[i].id != app->snapshot.cards[i].id) {
            return false;
        }
    }
    return true;
}

void UpdateCardsInPlace(App* app) {
    for (int i = 0; i < static_cast<int>(app->card_rows.size()); ++i) {
        auto& row = app->card_rows[static_cast<std::size_t>(i)];
        const auto& card = app->snapshot.cards[static_cast<std::size_t>(i)];
        gtk_label_set_text(GTK_LABEL(row.title), card.title.c_str());
        gtk_label_set_text(GTK_LABEL(row.preview), card.preview.c_str());
        SetCardSelectedStyle(row.event, i == app->snapshot.selected);
        g_object_set_data(G_OBJECT(row.event), "index", GINT_TO_POINTER(i));
    }
}

App::CardRow MakeCardRow(App* app, const rimes::capsule::Card& card, int index) {
    App::CardRow row;
    row.id = card.id;
    row.event = gtk_event_box_new();
    gtk_widget_set_name(row.event, "rimes-card");
    SetCardSelectedStyle(row.event, index == app->snapshot.selected);
    GtkWidget* column = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_container_set_border_width(GTK_CONTAINER(column), 8);
    gtk_container_add(GTK_CONTAINER(row.event), column);
    row.title = gtk_label_new(card.title.c_str());
    gtk_widget_set_name(row.title, "rimes-card-title");
    gtk_label_set_xalign(GTK_LABEL(row.title), 0);
    gtk_label_set_ellipsize(GTK_LABEL(row.title), PANGO_ELLIPSIZE_END);
    gtk_box_pack_start(GTK_BOX(column), row.title, FALSE, FALSE, 0);
    row.preview = gtk_label_new(card.preview.c_str());
    gtk_widget_set_name(row.preview, "rimes-card-preview");
    gtk_label_set_xalign(GTK_LABEL(row.preview), 0);
    gtk_label_set_line_wrap(GTK_LABEL(row.preview), TRUE);
    gtk_label_set_max_width_chars(GTK_LABEL(row.preview), 28);
    gtk_label_set_lines(GTK_LABEL(row.preview),4);
    gtk_label_set_ellipsize(GTK_LABEL(row.preview),PANGO_ELLIPSIZE_END);
    gtk_box_pack_start(GTK_BOX(column), row.preview, TRUE, TRUE, 0);
    gtk_widget_set_size_request(row.event, 206, 126);
    g_object_set_data(G_OBJECT(row.event), "index", GINT_TO_POINTER(index));
    g_signal_connect(row.event, "button-press-event", G_CALLBACK(OnCardButtonPress), app);
    gtk_box_pack_start(GTK_BOX(app->card_box), row.event, FALSE, FALSE, 0);
    return row;
}

void RebuildCards(App* app) {
    ClearBox(app->card_box);
    app->card_rows.clear();
    if (app->snapshot.cards.empty()) {
        GtkWidget* empty = gtk_label_new(app->snapshot.hint.c_str());
        gtk_widget_set_name(empty, "rimes-placeholder");
        gtk_box_pack_start(GTK_BOX(app->card_box), empty, FALSE, FALSE, 0);
        gtk_widget_show_all(app->card_box);
        return;
    }
    app->card_rows.reserve(app->snapshot.cards.size());
    for (int i = 0; i < static_cast<int>(app->snapshot.cards.size()); ++i) {
        app->card_rows.push_back(
            MakeCardRow(app, app->snapshot.cards[static_cast<std::size_t>(i)], i));
    }
    gtk_widget_show_all(app->card_box);
}

void SyncCards(App* app) {
    if (app->snapshot.cards.empty() || !CardsMatchIds(app)) {
        RebuildCards(app);
        return;
    }
    UpdateCardsInPlace(app);
}

bool DisplayIsWayland() {
#ifdef GDK_WINDOWING_WAYLAND
    GdkDisplay* display = gdk_display_get_default();
    return display != nullptr && GDK_IS_WAYLAND_DISPLAY(display);
#else
    return false;
#endif
}

void WriteGtkClipboard(const std::string& text) {
    GtkClipboard* board = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
    gtk_clipboard_set_text(board, text.c_str(), -1);
}

void ApplyCopiedText(App* app, const rimes::capsule::ClipboardWriteDecision& decision) {
    if (decision.path == rimes::capsule::ClipboardWritePath::Skip) {
        return;
    }
    const auto& text = app->snapshot.last_copied;
    if (decision.path == rimes::capsule::ClipboardWritePath::WlCopy) {
        if (rimes::capsule::SpawnWlCopy(text)) {
            return;
        }
        WriteGtkClipboard(text);
        gtk_label_set_text(GTK_LABEL(app->hint), rimes::capsule::kWaylandCopyFallbackHint);
        return;
    }
    WriteGtkClipboard(text);
    if (decision.status_override != nullptr) {
        gtk_label_set_text(GTK_LABEL(app->hint), decision.status_override);
    }
}

void LoadCss(const std::string& theme, GdkScreen* screen);

void ApplySnapshot(App* app) {
    if (app->theme != app->snapshot.theme) {
        LoadCss(app->snapshot.theme, gtk_widget_get_screen(app->window));
        app->theme = app->snapshot.theme;
    }
    gtk_label_set_text(GTK_LABEL(app->count),
                       rimes::capsule::CountText(app->snapshot.count).c_str());
    gtk_label_set_text(GTK_LABEL(app->hint), app->snapshot.hint.c_str());
    const auto query = app->snapshot.query.empty() ? std::string("搜索标题或内容")
                                                   : app->snapshot.query;
    gtk_label_set_text(GTK_LABEL(app->query), query.c_str());
    RebuildTabs(app);
    SyncCards(app);
    const bool wayland = DisplayIsWayland();
    const bool have_wl_copy = wayland && !rimes::capsule::FindOnPath("wl-copy").empty();
    rimes::capsule::ClipboardApplyState copy_state{app->seen_copy_seq, app->handled_copy_seq};
    const auto decision =
        rimes::capsule::ApplyCopiedNote(&copy_state, app->snapshot.copy_seq,
                                       app->snapshot.last_copied, wayland, have_wl_copy);
    app->seen_copy_seq = copy_state.seen_seq;
    app->handled_copy_seq = copy_state.handled_seq;
    ApplyCopiedText(app, decision);
    app->manager->Apply(app->snapshot);
    if (app->snapshot.visible && !app->snapshot.managing) {
        app->panel->Place(kWindowWidth, kWindowHeight, {}, !app->placed);
        gtk_widget_show_all(app->window);
        app->placed = true;
    } else {
        app->last_press_index = -1;
        app->last_press_ms = -1;
        gtk_widget_hide(app->window);
        app->placed = false;
    }
}

gboolean OnSocket(GIOChannel* /*channel*/, GIOCondition condition, gpointer data) {
    auto* app = static_cast<App*>(data);
    if ((condition & (G_IO_HUP | G_IO_ERR)) != 0) {
        gtk_main_quit();
        return G_SOURCE_REMOVE;
    }
    char chunk[4096];
    const auto got = read(app->socket_fd, chunk, sizeof(chunk));
    if (got <= 0) {
        gtk_main_quit();
        return G_SOURCE_REMOVE;
    }
    app->incoming.append(chunk, static_cast<std::size_t>(got));
    while (app->incoming.size() >= 4) {
        std::uint32_t length = 0;
        if (!rimes::buffer::DecodeFrameHeader(app->incoming.data(), &length)) {
            gtk_main_quit();
            return G_SOURCE_REMOVE;
        }
        if (app->incoming.size() < 4 + length) {
            break;
        }
        const std::string payload = app->incoming.substr(4, length);
        app->incoming.erase(0, 4 + length);
        rimes::capsule::Snapshot parsed;
        if (!rimes::capsule::DecodeSnapshot(payload, &parsed)) {
            continue;
        }
        app->snapshot = parsed;
        ApplySnapshot(app);
    }
    return G_SOURCE_CONTINUE;
}

bool ConnectSocket(App* app, const std::string& path) {
    if (const char* delay = g_getenv("RIMES_CAPSULE_CONNECT_DELAY_MS")) {
        const auto ms = std::atoi(delay);
        if (ms > 0 && ms < 30000) {
            g_usleep(static_cast<gulong>(ms) * 1000);
        }
    }
    app->socket_fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (app->socket_fd < 0) {
        return false;
    }
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    std::strncpy(address.sun_path, path.c_str(), sizeof(address.sun_path) - 1);
    if (connect(app->socket_fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0) {
        close(app->socket_fd);
        app->socket_fd = -1;
        return false;
    }
    GIOChannel* channel = g_io_channel_unix_new(app->socket_fd);
    app->io_id = g_io_add_watch(channel, static_cast<GIOCondition>(G_IO_IN | G_IO_HUP | G_IO_ERR),
                                OnSocket, app);
    g_io_channel_unref(channel);
    SendCommand(app, R"({"v":1,"op":"hello"})");
    return true;
}

void LoadCss(const std::string& theme, GdkScreen* screen) {
    using namespace rimes::desktop;
    Theme(theme, screen);
    const auto& palette = Visuals().at("palettes").at(theme == "liquidGlass" ? "day" : theme);
    auto c = [&](const char* key) { return palette.at(key).get<std::string>(); };
    static auto* provider = gtk_css_provider_new();
    const std::string css =
        "#rimes-capsule-window, .rimes-capsule, #rimes-chrome { background: " + c("bufferBackground") + "; color: " + c("textPrimary") + "; border-radius: 10px; }"
        "#rimes-title { color: " + c("textPrimary") + "; font-family: monospace; font-weight: bold; font-size: 15px; }"
        "#rimes-count, #rimes-query, #rimes-hint, #rimes-placeholder { color: " + c("textSecondary") + "; font-size: 12px; }"
        "button.rimes-tab, button.rimes-action { background: " + c("surfaceSecondary") + "; color: " + c("textPrimary") + "; border: 1px solid " + c("borderStrong") + "; border-radius: 6px; padding: 2px 8px; font-size: 12px; }"
        "button.rimes-tab-active { background: alpha(" + c("accentGreen") + ", 0.18); }"
        "button.rimes-action { min-width: 22px; min-height: 22px; padding: 0; }"
        "button.rimes-filter { padding: 0 8px; border: 0; min-height: 0; background: transparent; border-radius: 4px; font-size: 11px; color: " + c("textSecondary") + "; }"
        "button.rimes-filter.selected { background: " + c("surfaceTertiary") + "; font-weight: 600; color: " + c("textPrimary") + "; }"
        "#rimes-hint { font-size: 9px; } #rimes-count { font-family: monospace; font-size: 10px; }"
        "#rimes-card { background: " + c("surfaceSecondary") + "; border-radius: 8px; margin-right: 8px; }"
        "#rimes-card.rimes-card-selected { border: 1px solid " + c("accentGreen") + "; }"
        "#rimes-card-title { color: " + c("textPrimary") + "; font-weight: bold; }"
        "#rimes-card-preview { color: " + c("textSecondary") + "; font-size: 11px; }";
    gtk_css_provider_load_from_data(provider, css.c_str(), -1, nullptr);
    gtk_style_context_remove_provider_for_screen(screen, GTK_STYLE_PROVIDER(provider));
    gtk_style_context_add_provider_for_screen(screen, GTK_STYLE_PROVIDER(provider), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 1);
}

void BuildUi(App* app) {
    app->window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_title(GTK_WINDOW(app->window), rimes::branding::Title(" Capsule").c_str());
    gtk_window_set_icon_name(GTK_WINDOW(app->window), "rimes");
    gtk_window_set_default_size(GTK_WINDOW(app->window), kWindowWidth, kWindowHeight);
    gtk_widget_set_size_request(app->window, kWindowWidth, kWindowHeight);
    gtk_window_set_resizable(GTK_WINDOW(app->window), FALSE);
    gtk_window_set_decorated(GTK_WINDOW(app->window), FALSE);
    gtk_window_set_skip_taskbar_hint(GTK_WINDOW(app->window), TRUE);
    gtk_window_set_skip_pager_hint(GTK_WINDOW(app->window), TRUE);
    gtk_window_set_accept_focus(GTK_WINDOW(app->window), FALSE);
    gtk_window_set_focus_on_map(GTK_WINDOW(app->window), FALSE);
    gtk_window_set_type_hint(GTK_WINDOW(app->window), GDK_WINDOW_TYPE_HINT_UTILITY);
    gtk_window_set_keep_above(GTK_WINDOW(app->window), TRUE);
    gtk_widget_set_name(app->window, "rimes-capsule-window");
    gtk_style_context_add_class(gtk_widget_get_style_context(app->window), "rimes-capsule");
    g_signal_connect(app->window, "destroy", G_CALLBACK(gtk_main_quit), nullptr);
    g_signal_connect(app->window, "size-allocate", G_CALLBACK(OnSizeAllocate), app);

    app->panel = std::make_unique<rimes::desktop::PanelWindow>(GTK_WINDOW(app->window), "capsule", 16, !app->preview);
    app->wayland_layer = app->panel->Layer();
    gtk_widget_set_size_request(app->window, kWindowWidth, kWindowHeight);

    GtkWidget* chrome = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_name(chrome, "rimes-chrome");
    gtk_container_add(GTK_CONTAINER(app->window), chrome);

    GtkWidget* header = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 9);
    gtk_widget_set_margin_start(header,14); gtk_widget_set_margin_end(header,14);
    gtk_widget_set_margin_top(header,12); gtk_widget_set_size_request(header,-1,30);
    gtk_box_pack_start(GTK_BOX(chrome), header, FALSE, FALSE, 0);

    GtkWidget* title = gtk_label_new("Capsule");
    gtk_widget_set_name(title, "rimes-title");
    gtk_box_pack_start(GTK_BOX(header), title, FALSE, FALSE, 0);

    app->tab_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    gtk_box_pack_start(GTK_BOX(header), app->tab_box, FALSE, FALSE, 0);

    app->query = gtk_label_new("Search notes");
    gtk_widget_set_name(app->query, "rimes-query");
    gtk_box_pack_start(GTK_BOX(header), app->query, TRUE, TRUE, 0);

    app->count = gtk_label_new("0 ITEMS");
    gtk_widget_set_name(app->count, "rimes-count");
    gtk_box_pack_start(GTK_BOX(header), app->count, FALSE, FALSE, 0);
    auto* manage = rimes::desktop::IconButton("gearshape", "管理 Capsule", [app] { SendCommand(app,R"({"v":1,"op":"manage"})"); });
    gtk_widget_set_can_focus(manage,FALSE); gtk_box_pack_start(GTK_BOX(header),manage,FALSE,FALSE,0);

    GtkWidget* close = gtk_button_new_with_label("×");
    gtk_style_context_add_class(gtk_widget_get_style_context(close), "rimes-action");
    g_signal_connect(close, "clicked", G_CALLBACK(+[](GtkButton*, gpointer data) {
                         SendCommand(static_cast<App*>(data), R"({"v":1,"op":"close"})");
                     }),
                     app);
    gtk_box_pack_end(GTK_BOX(header), close, FALSE, FALSE, 0);

    GtkWidget* scroll = gtk_scrolled_window_new(nullptr, nullptr);
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_AUTOMATIC,
                                   GTK_POLICY_NEVER);
    auto* band = gtk_box_new(GTK_ORIENTATION_HORIZONTAL,8);
    gtk_widget_set_margin_start(band,14); gtk_widget_set_margin_end(band,14); gtk_widget_set_margin_top(band,9);
    gtk_box_pack_start(GTK_BOX(chrome),band,FALSE,FALSE,0);
    app->filter_box=gtk_box_new(GTK_ORIENTATION_VERTICAL,3); gtk_widget_set_size_request(app->filter_box,60,126);
    gtk_box_pack_start(GTK_BOX(band),app->filter_box,FALSE,FALSE,0);
    gtk_widget_set_size_request(scroll,-1,126); gtk_box_pack_start(GTK_BOX(band),scroll,TRUE,TRUE,0);

    app->card_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_container_add(GTK_CONTAINER(scroll), app->card_box);

    app->hint = gtk_label_new("Return inserts the selected note · Esc closes");
    gtk_widget_set_name(app->hint, "rimes-hint");
    gtk_widget_set_halign(app->hint, GTK_ALIGN_START);
    gtk_widget_set_margin_start(app->hint, 14);
    gtk_widget_set_margin_top(app->hint,8);
    gtk_widget_set_margin_bottom(app->hint, 8);
    gtk_box_pack_start(GTK_BOX(chrome), app->hint, FALSE, FALSE, 0);
    app->manager = std::make_unique<rimes::capsule::ManagerWindow>([app](auto command) { SendCommand(app,command); },app->preview);
}

}  // namespace

int main(int argc, char** argv) {
    gtk_init(&argc, &argv);
    std::string socket_path = DefaultSocketPath();
    bool preview = false, manager_preview = false;
    std::string render_path, preview_theme = "night";
    std::string dump_geometry;
    bool quit_after_dump = false;
    for (int index = 1; index < argc; ++index) {
        if (std::strcmp(argv[index], "--socket") == 0 && index + 1 < argc) {
            socket_path = argv[++index];
        } else if (std::strcmp(argv[index], "--manager-preview") == 0) {
            preview = true; manager_preview = true;
        } else if (std::strcmp(argv[index], "--render") == 0 && index + 1 < argc) {
            render_path = argv[++index];
        } else if (std::strcmp(argv[index], "--theme") == 0 && index + 1 < argc) {
            preview_theme = argv[++index];
        } else if (std::strcmp(argv[index], "--preview") == 0) {
            preview = true;
        } else if (std::strcmp(argv[index], "--dump-geometry") == 0 && index + 1 < argc) {
            dump_geometry = argv[++index];
        } else if (std::strcmp(argv[index], "--quit-after-dump") == 0) {
            quit_after_dump = true;
        }
    }

    if (!rimes::desktop::Visuals().at("palettes").contains(preview_theme) && preview_theme!="liquidGlass") return 2;
    if (!render_path.empty() && !preview) return 2;
    App app;
    g_app = &app;
    app.dump_geometry = dump_geometry;
    app.quit_after_dump = quit_after_dump;
    app.preview = preview;
    BuildUi(&app);

    if (preview) {
        app.snapshot.visible = true;
        app.snapshot.managing = manager_preview;
        app.snapshot.theme = preview_theme;
        for (auto module : rimes::capsule::kModules) if (module != rimes::capsule::Module::Notes) app.snapshot.modules.push_back(module);
        std::sort(app.snapshot.modules.begin(),app.snapshot.modules.end());
        app.snapshot.armed = true;
        app.snapshot.tab = "note";
        app.snapshot.hint = manager_preview ? "Ctrl+S SAVE   ESC BACK TO RAIL" : "Return inserts the selected note · Esc closes";
        app.snapshot.count = 1;
        rimes::capsule::Card demo;
        demo.id = rimes::capsule::kDefaultEntryId;
        demo.title = rimes::capsule::kDefaultEntryTitle;
        demo.preview = rimes::capsule::kDefaultEntryContent;
        demo.kind = rimes::capsule::Kind::Note;
        if (manager_preview) {
            int identity=1;
            for(const auto& item:rimes::capsule::ModuleContract().at("managerPreview")) {
                auto card=demo;card.id="72696d65-7300-4000-8000-00000000000"+std::to_string(++identity);
                card.title=item.at("title"); card.payload=item.at("content");
                card.preview=rimes::capsule::PreviewOf(card.payload.substr(0,card.payload.find('\n')));app.snapshot.cards.push_back(card);
            }
        }
        app.snapshot.cards.push_back(demo); app.snapshot.selected_id=app.snapshot.cards.front().id;
        app.snapshot.count=static_cast<int>(app.snapshot.cards.size());
        ApplySnapshot(&app);
        if (!render_path.empty()) {
            if(manager_preview) gtk_window_set_focus(GTK_WINDOW(app.manager->Window()),nullptr);
            for (int i = 0; i < 30; ++i) { while (gtk_events_pending()) gtk_main_iteration(); g_usleep(10000); }
            return rimes::desktop::Render(manager_preview ? app.manager->Root() : gtk_bin_get_child(GTK_BIN(app.window)), render_path) ? 0 : 1;
        }
        if (!app.dump_geometry.empty()) {
            g_timeout_add(
                200,
                [](gpointer data) -> gboolean {
                    WriteGeometryDump(static_cast<App*>(data));
                    return G_SOURCE_REMOVE;
                },
                &app);
        }
        if (app.quit_after_dump) {
            g_timeout_add(
                2000,
                [](gpointer data) -> gboolean {
                    WriteGeometryDump(static_cast<App*>(data));
                    gtk_main_quit();
                    return G_SOURCE_REMOVE;
                },
                &app);
        }
        gtk_main();
        return 0;
    }

    if (!ConnectSocket(&app, socket_path)) {
        g_printerr("rimes-capsule: could not connect to %s\n", socket_path.c_str());
        return 1;
    }
    gtk_main();
    if (app.socket_fd >= 0) {
        close(app.socket_fd);
    }
    return 0;
}
