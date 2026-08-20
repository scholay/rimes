# RIMES Design System

RIMES Design System 是 `design/react-system` 分支中的交互式 React 设计母版。它把原生输入法中最需要反复调整的五类界面放在同一个可操作画布里：

- 设置后台
- 菜单与扩展配置
- 输入法候选框
- Buffer 工作台
- 剪贴板历史

这个项目用于共同讨论、试验并冻结视觉与交互规范。它不会替换 ETInput 中的 AppKit / InputMethodKit 运行时，也不会在输入法进程里引入 WebView。

## 本地运行

```bash
cd DesignSystem
npm install
npm run dev
```

常用检查：

```bash
npm run typecheck
npm run tokens:swift
npm run check
```

生产构建同时保留 Sites 托管契约：

- `dist/client/index.html`
- `dist/server/index.js`
- `dist/.openai/hosting.json`

## 使用方式

左侧切换五个产品界面，中间画布执行交互，右侧 Inspector 实时调整颜色和圆角。顶部可以切换墨竹、翡翠和静谧主题，也可以复制或导出当前 token JSON。

场景和主题写入 URL，便于把某个讨论状态直接发给协作者：

```text
?surface=settings&theme=night
?surface=candidate&theme=day
?surface=buffer&theme=quiet
```

主要交互均为本地模拟：候选选择、Buffer 派生模式、翻译语言交换、插件下载与启停、剪贴板选择和安全遮蔽都不会读取真实输入焦点、网络或系统剪贴板。

## 代码结构

```text
src/
  App.tsx                         设计工作台与 Inspector
  design-system/
    Icon.tsx                      Phosphor 语义图标适配器
    data.ts                       场景与插件 fixture
    primitives.tsx               共享基础控件
    tokens/
      themes.json                 主题与几何单一来源
      index.ts                    CSS 变量与导出工具
  surfaces/
    SettingsSurface.tsx
    ExtensionsSurface.tsx
    CandidateSurface.tsx
    BufferSurface.tsx
    ClipboardSurface.tsx
  styles.css                      工作台与基础控件
  surface-styles.css              五个产品界面
generated/
  RimeDesignTokens.generated.swift
```

`themes.json` 保留原生 `RimeUI.swift` 的主题语义：墨竹、翡翠共用固定产品绿 `#22C55E`，静谧使用中性强调色。`1 CSS px = 1 macOS logical pt`，候选框、Buffer 和设置窗口的基准尺寸与原生实现保持一致。

## Token 迁移到 Swift

修改 `src/design-system/tokens/themes.json` 后运行：

```bash
npm run tokens:swift
```

它会更新 `generated/RimeDesignTokens.generated.swift`。生成文件只是设计评审产物；合入原生目标前仍应人工核对对比度、AppKit 动态外观、窗口行为及现有 `RimeUI` 兼容性。

## 设计边界

- React 负责视觉语言、组件状态和交互提案。
- AppKit / InputMethodKit 继续负责输入焦点、候选窗口、文本投递、跨 Space 行为和安全边界。
- Buffer 与 Clipboard 在设计层共享工作台语法，但在原生端仍需遵守单进程、非激活窗口与 `Delivery.insert` 约束。
- 右上角输入源菜单在原生端由 macOS `NSMenu` 绘制；这里的实现用于内容结构与交互讨论，不承诺像素级替换系统菜单。

