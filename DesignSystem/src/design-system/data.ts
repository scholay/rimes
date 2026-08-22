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

export type InputSchemeRecord = {
  id: "rime_ice" | "double_pinyin" | "double_pinyin_flypy" | "wubi86" | "english";
  name: string;
  summary: string;
  icon: IconName;
};

export const inputSchemes: readonly InputSchemeRecord[] = [
  {
    id: "rime_ice",
    name: "雾凇全拼",
    summary: "雾凇拼音 · 使用完整拼音输入",
    icon: "textbox",
  },
  {
    id: "double_pinyin",
    name: "自然码双拼",
    summary: "自然码双拼键位",
    icon: "keyboard",
  },
  {
    id: "double_pinyin_flypy",
    name: "小鹤双拼",
    summary: "小鹤双拼键位",
    icon: "keyboard",
  },
  {
    id: "wubi86",
    name: "五笔86",
    summary: "86 版五笔字型",
    icon: "grid",
  },
  {
    id: "english",
    name: "英文",
    summary: "英文候选与补全",
    icon: "globe",
  },
];

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
    name: "并击",
    version: "2.0",
    summary: "提供飞耀并击与互击输入、课程和练习；停用后不再接管并击按键。",
    icon: "hands",
    category: "extension",
    installState: "bundled",
    enabled: false,
    configurable: false,
  },
  {
    id: "builtin.ai-text",
    name: "AI 生成",
    version: "2.1",
    summary: "使用选定的 Codex、Claude Code 或通用 Open API 生成独立目标缓冲区。",
    icon: "sparkle",
    category: "buffer",
    installState: "bundled",
    enabled: true,
    configurable: true,
  },
  {
    id: "builtin.apple-translation",
    name: "实时翻译",
    version: "2.1",
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
    version: "1.3",
    summary: "连续输入不分词的全拼；并击扩展启用时支持并击转全拼，停用时继续使用顺序全拼。",
    icon: "waveform",
    category: "buffer",
    installState: "bundled",
    enabled: true,
    configurable: true,
  },
];
