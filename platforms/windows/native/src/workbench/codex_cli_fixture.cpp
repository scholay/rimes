#include <Windows.h>
#include <iostream>
#include <iterator>
#include <string>
int wmain(int argc, wchar_t** argv) {
  const std::wstring mode = argc > 1 ? argv[1] : L"success";
  if (mode == L"blocked") { Sleep(30000); return 0; }
  const std::string input((std::istreambuf_iterator<char>(std::cin)), {});
  if (input != "synthetic source & ; \"中文💡\"") return 9;
  if (mode == L"delay") { Sleep(30000); return 0; }
  if (mode == L"stderr") { std::cerr << std::string(1100000, 'x'); return 1; }
  std::cout << "{\"type\":\"thread.started\",\"thread_id\":\"fixture\"}\n{\"type\":\"turn.started\"}\n";
  if (mode == L"tool") {
    std::cout << "{\"type\":\"item.started\",\"item\":{\"type\":\"command_execution\"}}\n"; return 0;
  }
  if (mode == L"malformed") { std::cout << "not-json\n"; return 0; }
  std::cout << "{\"type\":\"item.completed\",\"item\":{\"type\":\"reasoning\",\"text\":\"private reasoning\"}}\n";
  std::cout << "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"你好💡\"}}\n";
  if (mode != L"unfinished") std::cout << "{\"type\":\"turn.completed\"}\n";
  return mode == L"nonzero" ? 3 : 0;
}
