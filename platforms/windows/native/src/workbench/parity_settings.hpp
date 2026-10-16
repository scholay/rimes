#pragma once
#include "../ui/settings_layout.hpp"
#include "provider.hpp"
#include <memory>

namespace rimes::windows::workbench {
// Real native settings content embedded in the shared macOS-shaped shell.
// All edits and portable profiles remain drafts until the shell saves.
class ParitySettings {
public:
  ParitySettings();
  ~ParitySettings();
  void Create(HWND parent, const Settings &settings);
  void Layout(ui::SettingsPage page, int subpage, const ui::DipRect &body,
              unsigned dpi, HFONT font);
  void PaintFields(HDC dc, ui::ThemeId theme, unsigned dpi) const;
  bool Command(unsigned id, unsigned notification);
  void Tick();
  bool Read(Settings *settings, std::string *error);
  const std::map<std::string, std::wstring> &Secrets() const;
  std::vector<HWND> VisibleControls() const;

private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
struct ConnectionProbeResult {
  bool success = false;
  std::string message;
  std::vector<std::string> models;
};
ConnectionProbeResult ProbeConnection(const ConnectionProfile &,
                                      const std::wstring &key);
} // namespace rimes::windows::workbench
