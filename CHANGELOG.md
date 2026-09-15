# 更新日志

本文件由 `python3 scripts/release/release_tool.py changelog --write` 根据发布 tag 与
[Conventional Commits](https://www.conventionalcommits.org/zh-hans/v1.0.0/) 生成，请勿手工编辑。
每个版本的安装方式与校验和见 [GitHub Releases](https://github.com/scholay/rimes/releases)。

## [v0.5.0-preview.1](https://github.com/scholay/rimes/releases/tag/v0.5.0-preview.1) — 2026-08-22

### 新功能

- prepare RIMES 0.5 input and buffer release (96ae5dd)
- **ui:** port React design system to native surfaces (09cfe78)
- **design:** slim input menu and rethink buffer rail layouts (7706571)
- **design:** add interactive React design system (9053a90)
- **settings:** add quiet theme and configurable shortcuts (db67a00)
- **windows:** add native TSF foundation (4c20c39)

### 修复

- **settings:** refresh choice card visual states (ae170fc)
- repair settings choices and clipboard shortcut (a8add72)
- **ui:** repair settings and compact buffer layout (bb400a9)
- **design:** restore compact buffer actions (c419b06)
- **design:** harden buffer and inbox interactions (9779409)
- **design:** align semantic colors with native UI (6893277)
- show candidates in iShot annotations (089b4f1)
- **windows:** avoid PowerShell automatic variable collision (2209b09)

### 文档

- establish community contribution workflows (3ee4cf0)
- formalize AI contributor attribution (47a68d9)
- credit Claude, Cursor, Codex, and Grok as contributors (0438492)

### 维护

- render default settings surface deterministically (bf2446b)
- **windows:** pin Visual Studio 2022 runner (cfcd830)

### 其他

- enable controlled unsigned previews (08917f7)

## [v0.4.3](https://github.com/scholay/rimes/releases/tag/v0.4.3) — 2026-08-15

### 修复

- harden RIMES installation, updater, and release (ce63692)

## [v0.4.2](https://github.com/scholay/rimes/releases/tag/v0.4.2) — 2026-08-10

### 新功能

- add Windows and Linux input scheme previews (4acf8ca)
- add marine chrome integration and polish buffer UI (7762417)
- add buffer plugin cycling and improve candidate contrast (e1b5f1f)
- broaden CLI compatibility and polish workbench UI (a3309f9)
- add My Prompt search plugin (3006c34)
- add local OCR for Remarkable (da81d4b)
- add configurable plugins and remarkable import (fb87fa8)
- support multiple enabled buffer plugins (4589191)
- promote prepared actions to the workbench primary control (526311d)
- refine workbench editing and stream input (e401ccc)
- ship RIMES workbench and stream input (347f90d)
- unify AI connectors and support context-only generation (f5991fc)
- **输入法:** 重构设置并扩展缓冲插件平台 (851345f)
- **缓冲工作台:** 简化交互并加固焦点与主题 (bf15df2)
- **缓冲工作台:** 独立窗口与焦点安全投递 (9576f3a)
- **候选窗+MCP:** 尺寸约束+实时预览, MCP 2025-06-18, 通用接入 (87db0b3)
- **M2:** local gateway + MCP + inbound bus + inbox (verified end-to-end) (6e376cc)
- **ui:** workbench settings IA + three-layer panel preview (56b43ef)
- **M1:** block provenance (Origin) + echo guard + source badges (91826f7)
- buffer workbench groundwork + M0 safety baseline (41583c4)

### 修复

- verify universal release binary correctly (9dbc258)
- centralize releases in scholay/rimes (8fa9fce)
- support macOS save panels and literal v input (3a6d381)
- stabilize focused workbench and marine chrome capture (76cff6d)
- harden plugin configuration storage and layout (15d5a2b)
- support stream chords and three-row layouts (addfc66)
- harden buffer paste and stream alternatives (0aff412)
- restore Control-Space input switching (1dbdbf9)
- unify workbench capture and semantic blocks (b41cbae)
- harden workbench delivery and Shift handling (ae251d8)
- **ime:** restore candidate paging and literal keys (7fe7c82)
- restore local CLI authentication (dcfc30f)
- **缓冲工作台:** 收紧单行界面并彻底隔离 Enter 回调 (7670621)
- **候选窗+MCP:** 补齐预览约束并加固本地网关 (001c015)

### 文档

- add MIT license (68c716a)
- add bilingual READMEs with product demo links (fdbe0d7)
- note WeChat input-switch crash as a known macOS 26 limitation (e785801)

### 维护

- normalize Rime data line endings (d61d534)
- harden preview and prompt smoke timing (e2aef88)
- point release updates at scholay/rimes (baaf2ae)
- 隔离 AI 缓冲插件夹具 (870b49e)
- 隔离并标注冒烟测试 (e0d98b2)
- bump version to 0.4.0 (804276b)
- bump version to 0.3.1 (0e9cb42)
- bump version to 0.3.0 (2f368de)
- run remote-smoke in CI (552bad9)
- bump version to 0.2.0 (d3b55b7)

### 其他

- Refine input schemes, buffer UI, and compatibility (df5b509)
- Improve input source registration and installer flow (2f63d6f)
- Add option-based character selection (111a146)
- Refine Enter input method UI (154ab5f)
- Refine candidate window UI (584b6b4)
- Add Marine buffer bridge and harden ETInput metadata (f688466)
- v0.4.1: restore schema-switch menu, import user Rime config, tidy input source (8740440)
- Bundle 雾凇/串击/并击 Rime schemas for a truly self-contained build (d6d9f9c)
- v0.3.8: fix input-source enable/icons on macOS 26 + move menu into system input menu (661a6b2)
- Rebrand to 恩特输入法 + new icon set (app, status-bar, input-source) (419db50)
- Fix "no candidates": dynamic schema menu + guard stale preference; PDF icon (2719e20)
- Add input-mode menu icon (fixes blank input source row + enable failure) (448c74e)
- Fix duplicate/blank input source: give the input mode a distinct id (2321f6d)
- Show localized name 恩特输入法 in input source list + fix installer dark-mode text (be6c78f)
- Add guided .pkg installer for first-time install (568a217)
- Fix repeated Keychain password prompt for remote-typing identity (c90969c)
- Add 隔空传字 (Mac-to-Mac remote typing) over encrypted LAN P2P (f4738f4)
- Self-contained librime + rebrand to 恩特输入法 (ETInput) + logo (0131ff6)
- Add GitHub Actions CI and in-app auto-update (7cd7404)
- Improve buffer mode controls and release feedback (548ddb0)
- Refine candidate buffer UI and controls (b4e9c74)
- Keep buffer anchored with candidate window (141fa91)
- Add keyboard frequency heatmap (1d8bd55)
- Refine RimeBuffer candidate and buffer UI (3b63bc4)
- Initial RimeBuffer import (a26da80)
