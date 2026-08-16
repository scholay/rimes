#pragma once

#include <string>

#include "../engine/rime_engine.hpp"

namespace rimes::windows::broker {

struct BrokerOptions {
  bool serve_once = false;
  bool print_endpoint = false;
  bool show_help = false;
  engine::RimeEngineOptions engine;
};

// Serving input requires four explicit absolute paths. The parser deliberately
// has no registry, Weasel, current-directory, or adjacent-file fallback.
// --help and --print-endpoint are the only diagnostics that may run without an
// engine configuration.
bool ParseBrokerOptions(int argc,
                        wchar_t** argv,
                        BrokerOptions* options,
                        std::wstring* error) noexcept;

}  // namespace rimes::windows::broker
