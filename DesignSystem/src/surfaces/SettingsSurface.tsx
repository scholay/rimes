import {
  useEffect,
  useMemo,
  useState,
  type PropsWithChildren,
  type ReactNode,
} from "react";
import { Icon, type IconName } from "../design-system/Icon";
import type { PluginRecord } from "../design-system/data";
import {
  Badge,
  Button,
  Field,
  IconButton,
  MacWindow,
  Segmented,
  Switch,
} from "../design-system/primitives";
import { themeCSSVariables, themes, type ThemeID } from "../design-system/tokens";
import {
  PluginConfigurationDialog,
  type PluginConfiguration,
  type PluginConfigurationMap,
  type PluginSetter,
} from "./ExtensionsSurface";

export type SettingsRouteID =
  | "core.input-method"
  | "core.appearance"
  | "core.buffer"
  | "core.connectors"
  | "core.plugins"
  | "core.maintenance"
  | `extension.${string}`;

type SettingsSubpage = { id: string; title: string };

type SettingsRoute = {
  id: SettingsRouteID;
  title: string;
  description: string;
  icon: IconName;
  section: "设置" | "扩展";
  subpages: readonly SettingsSubpage[];
  pluginID?: string;
};

const coreRoutes: readonly SettingsRoute[] = [
  {
    id: "core.input-method",
    title: "输入法",
    description: "管理输入编码、键入模式、词库与本地学习数据。",
    icon: "keyboard",
    section: "设置",
    subpages: [
      { id: "encoding", title: "输入编码" },
      { id: "typing-mode", title: "键入模式" },
      { id: "dictionaries", title: "词库" },
    ],
  },
  {
    id: "core.appearance",
    title: "外观",
    description: "主题同时作用于候选框、缓冲工作台与设置页预览。",
    icon: "appearance",
    section: "设置",
    subpages: [
      { id: "theme", title: "主题" },
      { id: "size", title: "尺寸" },
    ],
  },
  {
    id: "core.buffer",
    title: "缓冲区",
    description: "控制暂存、独立工作台、跨桌面显示与切换应用行为。",
    icon: "tray",
    section: "设置",
    subpages: [{ id: "buffer", title: "缓冲区" }],
  },
  {
    id: "core.connectors",
    title: "连接器",
    description: "管理 AI 模型、本地网关与已配对设备。",
    icon: "link",
    section: "设置",
    subpages: [
      { id: "ai-model", title: "AI 模型" },
      { id: "local-gateway", title: "本地网关" },
      { id: "remote-typing", title: "隔空传字" },
    ],
  },
  {
    id: "core.plugins",
    title: "插件",
    description: "管理工作台可用的缓冲插件与随应用提供的内部扩展。",
    icon: "plugin",
    section: "设置",
    subpages: [
      { id: "all", title: "全部" },
      { id: "buffer-plugins", title: "缓冲插件" },
      { id: "built-in-extensions", title: "内置扩展" },
    ],
  },
  {
    id: "core.maintenance",
    title: "维护",
    description: "检查更新、重启输入法，以及查看本地日志和数据。",
    icon: "tools",
    section: "设置",
    subpages: [
      { id: "update-restart", title: "更新与重启" },
      { id: "logs-data", title: "日志与数据" },
    ],
  },
];

const extensionRouteDetails: Record<string, Pick<SettingsRoute, "subpages" | "description">> = {
  "builtin.typing-speed": {
    description: "查看当前活跃输入速度和本地历史趋势。",
    subpages: [
      { id: "overview", title: "概览" },
      { id: "history", title: "历史" },
    ],
  },
  "builtin.statistics": {
    description: "查看按键分布、每日计数与全部历史。",
    subpages: [
      { id: "daily", title: "每日" },
      { id: "history", title: "历史" },
    ],
  },
  "builtin.fly-chord-learning": {
    description: "按飞耀互击方案安排课程、练习并保存本地进度。",
    subpages: [
      { id: "lessons", title: "课程" },
      { id: "practice", title: "练习" },
      { id: "progress", title: "进度" },
    ],
  },
};

const defaultSubpages: Record<string, string> = Object.fromEntries(
  coreRoutes.map((route) => [route.id, route.subpages[0]?.id ?? ""]),
);

const pluginInstallLabel = (plugin: PluginRecord) => {
  switch (plugin.installState) {
    case "bundled":
      return "内置";
    case "installed":
      return "已安装";
    case "not-downloaded":
      return "未下载";
    case "downloading":
      return "正在下载";
    case "failed":
      return "下载失败";
  }
};

function SettingsSection({
  title,
  description,
  children,
}: PropsWithChildren<{ title: string; description?: string }>) {
  return (
    <section className="settings-section">
      <header className="settings-section__header">
        <h3>{title}</h3>
        {description ? <p>{description}</p> : null}
      </header>
      <div className="settings-section__body">{children}</div>
    </section>
  );
}

function SettingRow({
  title,
  detail,
  control,
  icon,
}: {
  title: string;
  detail: string;
  control: ReactNode;
  icon?: IconName;
}) {
  return (
    <div className="settings-row">
      {icon ? (
        <span className="settings-row__icon">
          <Icon name={icon} size={18} weight="duotone" />
        </span>
      ) : null}
      <span className="settings-row__copy">
        <strong>{title}</strong>
        <small>{detail}</small>
      </span>
      <span className="settings-row__control">{control}</span>
    </div>
  );
}

function ChoiceCard({
  title,
  detail,
  selected,
  onClick,
  icon,
}: {
  title: string;
  detail: string;
  selected: boolean;
  onClick: () => void;
  icon: IconName;
}) {
  return (
    <button
      aria-pressed={selected}
      className={`settings-choice-card${selected ? " is-selected" : ""}`}
      onClick={onClick}
      type="button"
    >
      <Icon name={icon} size={20} weight={selected ? "fill" : "duotone"} />
      <span>
        <strong>{title}</strong>
        <small>{detail}</small>
      </span>
      {selected ? <Icon name="check" size={16} weight="bold" /> : null}
    </button>
  );
}

export type SettingsSurfaceProps = {
  plugins: PluginRecord[];
  setPlugins: PluginSetter;
  pluginConfigurations?: PluginConfigurationMap;
  onPluginConfigurationChange?: (
    plugin: PluginRecord,
    configuration: PluginConfiguration,
  ) => void;
  initialRouteID?: SettingsRouteID;
  themeID?: ThemeID;
  onThemeChange?: (theme: ThemeID) => void;
};

export function SettingsSurface({
  plugins,
  setPlugins,
  pluginConfigurations = {},
  onPluginConfigurationChange,
  initialRouteID = "core.appearance",
  themeID = "night",
  onThemeChange,
}: SettingsSurfaceProps) {
  const [currentRouteID, setCurrentRouteID] = useState<SettingsRouteID>(initialRouteID);
  const [activeThemeID, setActiveThemeID] = useState<ThemeID>(themeID);
  const [selectedSubpageByRoute, setSelectedSubpageByRoute] = useState<Record<string, string>>(
    defaultSubpages,
  );
  const [selectedPlugin, setSelectedPlugin] = useState<PluginRecord | null>(null);
  const [status, setStatus] = useState("所有设置仅作用于当前设计场景");

  const [encoding, setEncoding] = useState("double-pinyin");
  const [typingMode, setTypingMode] = useState("chinese");
  const [candidateLayout, setCandidateLayout] = useState("horizontal");
  const [candidateScale, setCandidateScale] = useState(100);
  const [bufferEnabled, setBufferEnabled] = useState(true);
  const [bufferWindowVisible, setBufferWindowVisible] = useState(true);
  const [bufferPinned, setBufferPinned] = useState(true);
  const [resetOnAppSwitch, setResetOnAppSwitch] = useState(false);
  const [gatewayEnabled, setGatewayEnabled] = useState(true);
  const [remoteTypingEnabled, setRemoteTypingEnabled] = useState(false);
  const [connector, setConnector] = useState("codex");
  const [automaticUpdates, setAutomaticUpdates] = useState(true);

  const extensionRoutes = useMemo<SettingsRoute[]>(() => plugins
    .filter((plugin) => plugin.category === "extension" && plugin.enabled)
    .map((plugin) => {
      const detail = extensionRouteDetails[plugin.id] ?? {
        description: plugin.summary,
        subpages: [{ id: "overview", title: "概览" }],
      };
      return {
        id: `extension.${plugin.id.replace("builtin.", "")}`,
        title: plugin.name,
        description: detail.description,
        icon: plugin.icon,
        section: "扩展",
        subpages: detail.subpages,
        pluginID: plugin.id,
      };
    }), [plugins]);

  const routes = useMemo(() => [...coreRoutes, ...extensionRoutes], [extensionRoutes]);
  const currentRoute = routes.find((route) => route.id === currentRouteID) ?? coreRoutes[0];
  const currentSubpage = selectedSubpageByRoute[currentRoute.id]
    ?? currentRoute.subpages[0]?.id
    ?? "";

  useEffect(() => {
    setCurrentRouteID(initialRouteID);
  }, [initialRouteID]);

  useEffect(() => {
    if (!routes.some((route) => route.id === currentRouteID)) {
      setCurrentRouteID("core.plugins");
    }
  }, [currentRouteID, routes]);

  useEffect(() => {
    setActiveThemeID(themeID);
  }, [themeID]);

  const selectRoute = (route: SettingsRoute) => {
    setCurrentRouteID(route.id);
    setSelectedSubpageByRoute((current) => ({
      ...current,
      [route.id]: current[route.id] ?? route.subpages[0]?.id ?? "",
    }));
  };

  const selectSubpage = (subpageID: string) => {
    setSelectedSubpageByRoute((current) => ({
      ...current,
      [currentRoute.id]: subpageID,
    }));
  };

  const updatePlugin = (pluginID: string, update: Partial<PluginRecord>) => {
    setPlugins((current) => current.map((plugin) => (
      plugin.id === pluginID ? { ...plugin, ...update } : plugin
    )));
  };

  const downloadPlugin = (plugin: PluginRecord) => {
    updatePlugin(plugin.id, { installState: "downloading" });
    setStatus(`正在从 GitHub 下载 ${plugin.name}`);
    window.setTimeout(() => {
      updatePlugin(plugin.id, { installState: "installed", enabled: false });
      setStatus(`${plugin.name} 已下载并安装，当前保持停用`);
    }, 850);
  };

  const renderPluginManager = () => {
    const visiblePlugins = plugins.filter((plugin) => {
      if (currentSubpage === "buffer-plugins") return plugin.category === "buffer";
      if (currentSubpage === "built-in-extensions") return plugin.category === "extension";
      return true;
    });

    return (
      <SettingsSection
        title="插件"
        description="下载只安装插件；新下载的插件保持停用，启用后才会进入工作台或扩展导航。"
      >
        <div className="plugin-management-list">
          {visiblePlugins.map((plugin) => {
            const available = plugin.installState === "bundled" || plugin.installState === "installed";
            return (
              <article className="plugin-management-card" key={plugin.id}>
                <span className="plugin-management-card__icon">
                  <Icon name={plugin.icon} size={22} weight="duotone" />
                </span>
                <span className="plugin-management-card__copy">
                  <span className="plugin-management-card__title">
                    <strong>{plugin.name}</strong>
                    <small>v{plugin.version}</small>
                    <Badge tone={available ? "neutral" : "warning"}>
                      {pluginInstallLabel(plugin)}
                    </Badge>
                  </span>
                  <small>{plugin.summary}</small>
                </span>
                <span className="plugin-management-card__actions">
                  {available && plugin.configurable ? (
                    <Button icon="gear" kind="ghost" onClick={() => setSelectedPlugin(plugin)}>
                      设置…
                    </Button>
                  ) : null}
                  {available ? (
                    <Switch
                      checked={plugin.enabled}
                      label={`${plugin.enabled ? "停用" : "启用"} ${plugin.name}`}
                      onChange={(enabled) => {
                        updatePlugin(plugin.id, { enabled });
                        setStatus(`${plugin.name} 已${enabled ? "启用" : "停用"}`);
                      }}
                    />
                  ) : (
                    <Button
                      icon="cloudDownload"
                      kind="secondary"
                      disabled={plugin.installState === "downloading"}
                      onClick={() => downloadPlugin(plugin)}
                    >
                      {plugin.installState === "downloading" ? "等待…" : "下载"}
                    </Button>
                  )}
                </span>
              </article>
            );
          })}
        </div>
      </SettingsSection>
    );
  };

  const renderExtensionPage = (route: SettingsRoute) => {
    const plugin = plugins.find((item) => item.id === route.pluginID);
    if (!plugin) return null;

    if (plugin.id === "builtin.typing-speed") {
      return (
        <SettingsSection title={currentSubpage === "overview" ? "实时速度" : "输入速度历史"}>
          <div className="metric-card-grid">
            <article className="metric-card"><small>当前速度</small><strong>72</strong><span>字 / 分钟</span></article>
            <article className="metric-card"><small>按键速度</small><strong>186</strong><span>键 / 分钟</span></article>
            <article className="metric-card"><small>活跃时间</small><strong>28</strong><span>分钟</span></article>
          </div>
          <div className="settings-data-placeholder">
            <Icon name="speed" size={24} weight="duotone" />
            <span>{currentSubpage === "overview" ? "按活跃输入时间实时更新" : "最近七天速度趋势 · 数据只保存在本机"}</span>
          </div>
        </SettingsSection>
      );
    }

    if (plugin.id === "builtin.statistics") {
      return (
        <SettingsSection title={currentSubpage === "daily" ? "今日输入统计" : "全部历史"}>
          <div className="metric-card-grid">
            <article className="metric-card"><small>今日按键</small><strong>4,286</strong><span>次</span></article>
            <article className="metric-card"><small>成文字符</small><strong>1,204</strong><span>个</span></article>
            <article className="metric-card"><small>连续记录</small><strong>16</strong><span>天</span></article>
          </div>
          <div className="settings-data-placeholder">
            <Icon name="chart" size={24} weight="duotone" />
            <span>{currentSubpage === "daily" ? "键盘热力图将在这里呈现" : "仅汇总计数，不保存输入正文"}</span>
          </div>
        </SettingsSection>
      );
    }

    return (
      <SettingsSection title={route.subpages.find((page) => page.id === currentSubpage)?.title ?? "课程"}>
        <div className="lesson-card-grid">
          {[
            ["基础键位", "8 / 12 完成"],
            ["左右手互击", "4 / 10 完成"],
            ["常用组合", "尚未开始"],
          ].map(([title, detail], index) => (
            <article className="lesson-card" key={title}>
              <Icon name={index === 2 ? "lock" : "hands"} size={21} weight="duotone" />
              <strong>{title}</strong>
              <small>{detail}</small>
              <Button
                kind="ghost"
                onClick={() => setStatus(index === 2 ? `${title}的解锁要求已展开` : `已继续${title}`)}
              >
                {index === 2 ? "查看要求" : "继续"}
              </Button>
            </article>
          ))}
        </div>
      </SettingsSection>
    );
  };

  const renderPage = () => {
    if (currentRoute.section === "扩展") return renderExtensionPage(currentRoute);

    if (currentRoute.id === "core.input-method") {
      if (currentSubpage === "encoding") {
        return (
          <SettingsSection title="输入编码" description="选择 Rime 使用的主要拼音编码方案。">
            <div className="settings-choice-grid">
              <ChoiceCard icon="textbox" title="全拼" detail="使用完整拼音进行输入" selected={encoding === "full-pinyin"} onClick={() => setEncoding("full-pinyin")} />
              <ChoiceCard icon="keyboard" title="双拼" detail="当前使用自然码双拼" selected={encoding === "double-pinyin"} onClick={() => setEncoding("double-pinyin")} />
            </div>
            <SettingRow
              title="双拼方案"
              detail="更换方案后将重新部署 Rime 配置。"
              control={(
                <select className="r-native-select" disabled={encoding !== "double-pinyin"} defaultValue="natural">
                  <option value="natural">自然码</option>
                  <option value="flypy">小鹤双拼</option>
                  <option value="mspy">微软双拼</option>
                </select>
              )}
            />
          </SettingsSection>
        );
      }

      if (currentSubpage === "typing-mode") {
        return (
          <SettingsSection title="键入模式">
            <Field label="默认语言">
              <Segmented
                ariaLabel="默认键入语言"
                onChange={setTypingMode}
                options={[
                  { value: "chinese", label: "中文" },
                  { value: "english", label: "英文直通" },
                ]}
                value={typingMode}
              />
            </Field>
            <Field label="候选布局">
              <Segmented
                ariaLabel="候选框布局"
                onChange={setCandidateLayout}
                options={[
                  { value: "horizontal", label: "横向" },
                  { value: "matrix", label: "矩阵" },
                ]}
                value={candidateLayout}
              />
            </Field>
            <SettingRow title="输入法切换快捷键" detail="使用 Ctrl + Space 切换到 RIMES。" icon="keyboard" control={<Badge tone="accent">⌃ Space</Badge>} />
          </SettingsSection>
        );
      }

      return (
        <SettingsSection title="词库" description="内置词库与用户学习数据使用独立的 RimeBuffer 数据目录。">
          <SettingRow title="雾凇拼音" detail="主要中文词库 · 已启用" icon="book" control={<Badge tone="accent">可用</Badge>} />
          <SettingRow title="Easy English" detail="中英混输补充词库 · 已启用" icon="book" control={<Badge tone="accent">可用</Badge>} />
          <SettingRow
            title="用户学习数据"
            detail="导入或导出当前用户词频，不包含缓冲正文。"
            icon="database"
            control={<span className="settings-inline-actions"><Button icon="download" kind="ghost" onClick={() => setStatus("已打开用户词频导入预览")}>导入…</Button><Button icon="export" kind="ghost" onClick={() => setStatus("用户词频导出任务已模拟")}>导出…</Button></span>}
          />
        </SettingsSection>
      );
    }

    if (currentRoute.id === "core.appearance") {
      if (currentSubpage === "theme") {
        return (
          <SettingsSection title="主题" description="主题固定使用产品色，不再跟随系统强调色。">
            <div className="theme-choice-list">
              {(Object.entries(themes) as [ThemeID, (typeof themes)[ThemeID]][]).map(([id, theme]) => (
                <button
                  aria-pressed={activeThemeID === id}
                  className={`theme-choice${activeThemeID === id ? " is-selected" : ""}`}
                  key={id}
                  onClick={() => {
                    setActiveThemeID(id);
                    onThemeChange?.(id);
                    setStatus(`已切换到${theme.title}主题`);
                  }}
                  style={themeCSSVariables(theme)}
                  type="button"
                >
                  <span className="theme-choice__icon"><Icon name="appearance" size={21} weight="duotone" /></span>
                  <span className="theme-choice__copy"><strong>{theme.title}</strong><small>{theme.description}</small></span>
                  {activeThemeID === id ? <Badge tone="accent">正在使用</Badge> : <Badge>可用</Badge>}
                </button>
              ))}
            </div>
          </SettingsSection>
        );
      }

      return (
        <SettingsSection title="界面尺寸" description="在原生实现中这些数值会映射为 macOS 逻辑点。">
          <Field label={`候选框缩放 · ${candidateScale}%`} hint="同时影响候选字体、行高和内部间距。">
            <input aria-label="候选框缩放" className="r-range" max="130" min="80" onChange={(event) => setCandidateScale(Number(event.target.value))} type="range" value={candidateScale} />
          </Field>
          <SettingRow title="候选框位置" detail="优先跟随当前文本光标；工作台活跃时贴靠工作台外沿。" icon="textbox" control={<Badge tone="accent">自动</Badge>} />
          <Button kind="secondary" onClick={() => setCandidateScale(100)}>恢复默认尺寸</Button>
        </SettingsSection>
      );
    }

    if (currentRoute.id === "core.buffer") {
      return (
        <SettingsSection title="缓冲区" description="关闭工作台会暂停捕获并收束瞬态状态，但保留已经形成的块。">
          <SettingRow title="启用缓冲模式" detail="提交内容先暂存，确认后再发送到当前文本框。" icon="tray" control={<Switch checked={bufferEnabled} label="启用缓冲模式" onChange={setBufferEnabled} />} />
          <SettingRow title="显示独立缓冲工作台" detail="聚焦文本框时把工作台带到当前屏幕。" icon="eye" control={<Switch checked={bufferWindowVisible} label="显示独立缓冲工作台" onChange={setBufferWindowVisible} />} />
          <SettingRow title="常显于所有桌面与全屏空间" detail="适合在应用和全屏空间之间切换时持续使用。" icon="pin" control={<Switch checked={bufferPinned} label="跨桌面常显" onChange={setBufferPinned} />} />
          <SettingRow title="切换应用时清空本地缓冲" detail="只在没有外部来源块时执行；默认关闭。" icon="trash" control={<Switch checked={resetOnAppSwitch} label="切换应用时清空本地缓冲" onChange={setResetOnAppSwitch} />} />
          <div className="settings-action-row">
            <Button icon="export" kind="secondary" onClick={() => setStatus("缓冲工作台已移到当前屏幕")}>移到当前屏幕</Button>
            <Button icon="eye" kind="ghost" onClick={() => setBufferWindowVisible(true)}>显示工作台</Button>
          </div>
        </SettingsSection>
      );
    }

    if (currentRoute.id === "core.connectors") {
      if (currentSubpage === "ai-model") {
        return (
          <SettingsSection title="AI 模型" description="正文只会在用户明确点击生成时交给所选连接器。">
            <div className="settings-choice-grid settings-choice-grid--three">
              <ChoiceCard icon="code" title="Codex CLI" detail="浏览器授权 · 已就绪" selected={connector === "codex"} onClick={() => setConnector("codex")} />
              <ChoiceCard icon="sparkle" title="Claude Code" detail="官方 CLI 授权" selected={connector === "claude"} onClick={() => setConnector("claude")} />
              <ChoiceCard icon="network" title="OpenAI API" detail="自定义兼容端点" selected={connector === "openai"} onClick={() => setConnector("openai")} />
            </div>
            <SettingRow title="连接器状态" detail={connector === "codex" ? "Codex 隔离握手与登录均已通过。" : "选择后将检查对应登录和能力。"} icon="check" control={<Button kind="secondary" onClick={() => setStatus(`${connector} 连接检查通过`)}>检查连接</Button>} />
          </SettingsSection>
        );
      }

      if (currentSubpage === "local-gateway") {
        return (
          <SettingsSection title="本地网关" description="仅监听 127.0.0.1，并要求 Token 鉴权。">
            <SettingRow title="启用本地网关" detail="允许本机 Claude Code、Codex 等工具推送待确认内容。" icon="network" control={<Switch checked={gatewayEnabled} label="启用本地网关" onChange={setGatewayEnabled} />} />
            <Field label="网关地址"><input className="r-text-input" readOnly value="http://127.0.0.1:17321" /></Field>
            <div className="settings-action-row"><Button icon="copy" kind="secondary" onClick={() => setStatus("本地网关配置 JSON 已复制到模拟状态")}>复制配置 JSON</Button><Button icon="copy" kind="ghost" onClick={() => setStatus("Claude Code 命令已复制到模拟状态")}>复制 Claude Code 命令</Button></div>
          </SettingsSection>
        );
      }

      return (
        <SettingsSection title="隔空传字" description="配对设备使用端到端加密通道；收到的文字按既有直通规则处理。">
          <SettingRow title="启用隔空传字" detail="允许已配对的 RIMES 设备发现这台 Mac。" icon="network" control={<Switch checked={remoteTypingEnabled} label="启用隔空传字" onChange={setRemoteTypingEnabled} />} />
          <Field label="这台 Mac 的名称"><input className="r-text-input" defaultValue="Isaac 的 Mac" /></Field>
          <SettingRow title="MacBook Pro" detail="上次在线：刚刚 · 已配对" icon="check" control={<Button kind="danger" onClick={() => setStatus("已模拟取消 MacBook Pro 配对")}>取消配对</Button>} />
        </SettingsSection>
      );
    }

    if (currentRoute.id === "core.plugins") return renderPluginManager();

    if (currentSubpage === "update-restart") {
      return (
        <SettingsSection title="更新与重启" description="这些操作在设计系统中只模拟状态，不会影响已安装输入法。">
          <SettingRow title="自动检查更新" detail="启动后按稳定通道检查 GitHub Release。" icon="refresh" control={<Switch checked={automaticUpdates} label="自动检查更新" onChange={setAutomaticUpdates} />} />
          <SettingRow title="当前版本" detail="RIMES 0.4.3 · 已是最新版本" icon="info" control={<Button kind="secondary" onClick={() => setStatus("已经是最新版本")}>检查更新…</Button>} />
          <div className="settings-action-row"><Button icon="refresh" kind="secondary" onClick={() => setStatus("已请求重启输入法进程")}>重启输入法进程</Button><Button icon="download" kind="danger" onClick={() => setStatus("已进入重新安装确认流程")}>重新安装输入法</Button></div>
        </SettingsSection>
      );
    }

    return (
      <SettingsSection title="日志与数据" description="运行日志不记录输入正文；插件配置和用户词库保存在独立目录。">
        <SettingRow title="运行日志" detail="~/rimebuffer.log · 0600 权限 · 自动轮转" icon="fileSearch" control={<Button kind="secondary" onClick={() => setStatus("已模拟打开运行日志")}>打开运行日志</Button>} />
        <SettingRow title="安装日志" detail="~/rimebuffer-install.log" icon="fileSearch" control={<Button kind="secondary" onClick={() => setStatus("已模拟打开安装日志")}>打开安装日志</Button>} />
        <SettingRow title="RIMES 数据目录" detail="~/Library/RimeBuffer" icon="database" control={<Button kind="secondary" onClick={() => setStatus("已模拟打开 RIMES 数据目录")}>打开数据目录</Button>} />
      </SettingsSection>
    );
  };

  const currentRoutePlugin = currentRoute.pluginID
    ? plugins.find((plugin) => plugin.id === currentRoute.pluginID)
    : undefined;

  return (
    <div className="settings-surface">
      <MacWindow title="RIMES 设置" className="settings-window" toolbar={<Badge tone="accent">设计预览</Badge>}>
        <div className="settings-layout">
          <aside className="settings-sidebar" aria-label="设置导航">
            {(["设置", "扩展"] as const).map((section) => {
              const sectionRoutes = routes.filter((route) => route.section === section);
              if (sectionRoutes.length === 0) return null;
              return (
                <section className="settings-sidebar__section" key={section}>
                  <h2>{section}</h2>
                  <nav>
                    {sectionRoutes.map((route) => (
                      <button
                        aria-current={currentRoute.id === route.id ? "page" : undefined}
                        className={`settings-nav-item${currentRoute.id === route.id ? " is-selected" : ""}`}
                        key={route.id}
                        onClick={() => selectRoute(route)}
                        type="button"
                      >
                        <Icon name={route.icon} size={18} weight={currentRoute.id === route.id ? "fill" : "regular"} />
                        <span>{route.title}</span>
                      </button>
                    ))}
                  </nav>
                </section>
              );
            })}
          </aside>

          <main className="settings-content">
            <div className="settings-subpage-bar">
              <Segmented
                ariaLabel={`${currentRoute.title}子页面`}
                onChange={selectSubpage}
                options={currentRoute.subpages.map((page) => ({ value: page.id, label: page.title }))}
                value={currentSubpage}
              />
            </div>

            <header className="settings-page-heading">
              <span>
                <h1>{currentRoute.title}</h1>
                <p>{currentRoute.description}</p>
              </span>
              {currentRoutePlugin?.configurable ? (
                <IconButton
                  icon="gear"
                  label={`配置 ${currentRoute.title}`}
                  onClick={() => setSelectedPlugin(currentRoutePlugin)}
                />
              ) : null}
            </header>

            <div className="settings-page-scroll">{renderPage()}</div>

            <footer className="settings-status-bar">
              <Icon name="info" size={15} />
              <span aria-live="polite">{status}</span>
              <span>{currentRoute.id} · {currentSubpage}</span>
            </footer>
          </main>
        </div>
      </MacWindow>

      <PluginConfigurationDialog
        initialConfiguration={selectedPlugin ? pluginConfigurations[selectedPlugin.id] : undefined}
        onClose={() => setSelectedPlugin(null)}
        onSave={(plugin, configuration) => {
          onPluginConfigurationChange?.(plugin, configuration);
          setStatus(`${plugin.name} 配置已保存`);
        }}
        plugin={selectedPlugin}
      />
    </div>
  );
}
