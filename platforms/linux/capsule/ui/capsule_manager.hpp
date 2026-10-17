#pragma once
#include "capsule_protocol.hpp"
#include <functional>
#include <memory>
#include <gtk/gtk.h>
namespace rimes::capsule {
class ManagerWindow {
public:
    using Send = std::function<void(std::string)>;
    explicit ManagerWindow(Send send, bool preview = false);
    ~ManagerWindow();
    void Apply(const Snapshot& snapshot);
    void ClipboardStatus(const std::string& status);
    GtkWidget* Window() const;
    GtkWidget* Root() const;
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
}
