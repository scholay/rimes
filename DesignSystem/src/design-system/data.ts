import type { IconName } from "./Icon";

export type SurfaceID = "settings" | "extensions" | "candidate" | "buffer" | "clipboard";

export const surfaces: { id: SurfaceID; title: string; caption: string; icon: IconName }[] = [
  { id: "settings", title: "设置后台", caption: "完整路由与配置状态", icon: "sliders" },
  { id: "extensions", title: "扩展与菜单", caption: "插件详情和右上角菜单", icon: "plugin" },
  { id: "candidate", title: "候选框", caption: "单行、矩阵与锚点状态", icon: "textbox" },
  { id: "buffer", title: "Buffer", caption: "普通与派生双轨工作台", icon: "tray" },
  { id: "clipboard", title: "剪贴板", caption: "进程内历史与安全状态", icon: "clipboard" },
];

export type PluginInstallState = "bundled" | "not-downloaded" | "downloading" | "installed" | "failed";

export type PluginRecord = {
  id: string;
  name: string;
  version: string;
  summary: string;
  icon: IconName;
  category: "extension" | "buffer";
  installState: PluginInstallState;
  enabled: boolean;
  configurable: boolean;
};

export const initialPlugins: PluginRecord[] = [
  {
    id: "builtin.typing-speed",
    name: "打字测速",
    version: "1.0",
    summary: "按活跃输入时间计算按键和成文字符速度；不保存输入正文。",
    icon: "speed",
    category: "extension",
    installState: "bundled",
    enabled: true,
    configurable: false,
  },
  {
    id: "builtin.statistics",
    name: "统计",
    version: "1.0",
    summary: "按日查看键盘热力图与全部历史趋势；仅保存本地计数。",
    icon: "chart",
    category: "extension",
    installState: "bundled",
    enabled: true,
    configurable: false,
  },
  {
    id: "builtin.fly-chord-learning",
    name: "飞耀互击学习",
    version: "1.0",
    summary: "从飞耀互击方案生成课程与专项练习，进度只保存在本机。",
    icon: "hands",
    category: "extension",
    installState: "bundled",
    enabled: false,
    configurable: false,
  },
  {
    id: "builtin.ai-text",
    name: "AI 生成",
    version: "2.0",
    summary: "使用选定的 Codex、Claude Code 或通用 Open API 生成独立目标缓冲区。",
    icon: "sparkle",
    category: "buffer",
    installState: "bundled",
    enabled: true,
    configurable: true,
  },
  {
    id: "builtin.my-prompt",
    name: "My Prompt",
    version: "1.0",
    summary: "从本地 Markdown、Obsidian 或 Fabric 风格提示词库实时检索。",
    icon: "fileSearch",
    category: "buffer",
    installState: "bundled",
    enabled: true,
    configurable: true,
  },
  {
    id: "builtin.apple-translation",
    name: "实时翻译",
    version: "2.0",
    summary: "把源缓冲区实时翻译到独立目标缓冲区，默认使用 Apple 本地翻译。",
    icon: "globe",
    category: "buffer",
    installState: "bundled",
    enabled: true,
    configurable: true,
  },
  {
    id: "builtin.stream-input",
    name: "意识流输入",
    version: "1.1",
    summary: "连续输入不分词的全拼，实时给出一至三个完整猜测。",
    icon: "waveform",
    category: "buffer",
    installState: "bundled",
    enabled: true,
    configurable: true,
  },
  {
    id: "builtin.remarkable",
    name: "Remarkable",
    version: "2.0",
    summary: "只读导出 reMarkable 当前页，并用 Apple Vision 在 Mac 本地识别。",
    icon: "eye",
    category: "buffer",
    installState: "not-downloaded",
    enabled: false,
    configurable: true,
  },
  {
    id: "builtin.marine-chrome",
    name: "Marine Chrome",
    version: "0.2.3",
    summary: "由配套 Chrome 扩展读取当前网页和精确回复目标。",
    icon: "network",
    category: "buffer",
    installState: "not-downloaded",
    enabled: false,
    configurable: true,
  },
];
