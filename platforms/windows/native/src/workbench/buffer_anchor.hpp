#pragma once

#include <Windows.h>
#include <optional>

#include "buffer_placement.hpp"

namespace rimes::windows::workbench {
struct BufferInputAnchor {
  // Physical screen pixels; convert all coordinates using the chosen
  // monitor's DPI before applying the shared placement math.
  std::optional<BufferRect> caret;
  std::optional<BufferRect> box;
};
BufferInputAnchor ProbeBufferInputAnchor(DWORD expected_process);
}  // namespace rimes::windows::workbench
