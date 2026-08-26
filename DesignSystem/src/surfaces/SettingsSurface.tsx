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
    description: "管理输入方案、词库与本地学习数据；并击能力由扩展单独提供。",
    icon: "keyboard",
    section: "设置",
    subpages: [
      { id: "encoding", title: "输入方案" },
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
    description: "配置飞耀并击或互击输入，并进行课程与专项练习。",
    subpages: [
      { id: "settings", title: "设置" },
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
  marker = "check",
}: {
  title: string;
  detail: string;
  selected: boolean;
  onClick: () => void;
  icon: IconName;
  marker?: "check" | "radio";
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
      {marker === "radio" ? (
        <span
          aria-hidden="true"
          className={`settings-choice-card__radio${selected ? " is-selected" : ""}`}
        />
      ) : selected ? (
        <Icon name="check" size={16} weight="bold" />
      ) : null}
    </button>
  );
}

type InputScheme =
  | "full-pinyin"
  | "natural"
  | "flypy"
  | "wubi86"
  | "english"
  | "chord";

const INPUT_SCHEMES: readonly {
  id: Exclude<InputScheme, "chord">;
  title: string;
  detail: string;
  icon: IconName;
}[] = [
  {
    id: "full-pinyin",
    title: "雾凇全拼",
    detail: "雾凇词库与完整拼音输入",
    icon: "textbox",
  },
  {
    id: "natural",
    title: "自然码双拼",
    detail: "自然码双拼方案",
    icon: "keyboard",
  },
  {
    id: "flypy",
    title: "小鹤双拼",
    detail: "小鹤双拼方案",
    icon: "bird",
  },
  {
    id: "wubi86",
    title: "五笔86",
    detail: "86 版五笔字型",
    icon: "grid",
  },
  {
    id: "english",
    title: "英文",
    detail: "英文候选与补全",
    icon: "textbox",
  },
];

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

  const [inputScheme, setInputScheme] = useState<InputScheme>("chord");
  const [candidateScale, setCandidateScale] = useState(100);
  const [bufferEnabled, setBufferEnabled] = useState(true);
  const [bufferWindowVisible, setBufferWindowVisible] = useState(true);
  const [bufferPinned, setBufferPinned] = useState(true);
  const [resetOnAppSwitch, setResetOnAppSwitch] = useState(false);
  const [gatewayEnabled, setGatewayEnabled] = useState(true);
  const [gatewayClaudeOpen, setGatewayClaudeOpen] = useState(false);
  const [remoteTypingEnabled, setRemoteTypingEnabled] = useState(false);
  const [connector, setConnector] = useState<"codex" | "claude" | "openai">("codex");
  const [openAPIBaseURL, setOpenAPIBaseURL] = useState("https://api.cometapi.com/v1");
  const [openAPIModel, setOpenAPIModel] = useState("deepseek-v4-flash");
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

  const chordExtensionEnabled = plugins.some(
    (plugin) => plugin.id === "builtin.fly-chord-learning" && plugin.enabled,
  );
  const usingChordScheme = chordExtensionEnabled && inputScheme === "chord";

  useEffect(() => {
    if (!chordExtensionEnabled && inputScheme === "chord") {
      setInputScheme("natural");
    }
  }, [chordExtensionEnabled, inputScheme]);

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
    if (
      pluginID === "builtin.fly-chord-learning"
      && update.enabled === true
    ) {
      setInputScheme("chord");
    }
    if (
      pluginID === "builtin.fly-chord-learning"
      && update.enabled === false
      && inputScheme === "chord"
    ) {
      setInputScheme("natural");
    }
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

    if (plugin.id === "builtin.fly-chord-learning" && currentSubpage === "settings") {
      return (
        <SettingsSection
          title="并击设置"
          description="并击作为独立扩展提供；启用后会占用输入方案，直到你在输入法页切回普通方案。"
        >
          <SettingRow
            title="启用并击输入"
            detail="当前实现：飞耀并击。可在输入法 › 输入方案中切回普通方案。"
            icon="hands"
            control={(
              <Switch
                checked={plugin.enabled}
                label="启用并击输入"
                onChange={(enabled) => {
                  updatePlugin(plugin.id, { enabled });
                  setStatus(enabled ? "已启用并击扩展" : "已停用并击扩展");
                }}
              />
            )}
          />
          <SettingRow
            title="当前实现"
            detail="选择下方普通输入方案即可退出并击。"
            icon="info"
            control={<Badge tone="accent">飞耀并击</Badge>}
          />
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
          <SettingsSection
            title="输入方案"
            description="单独轻点 Shift 切换中英；Shift 与字母/标点组合或持续按住 500 ms 后，会保持按下前的输入模式。"
          >
            {usingChordScheme ? (
              <SettingRow
                title="当前使用并击扩展"
                detail="正在使用飞耀并击；选择下方任一方案即可切回普通输入。"
                icon="hands"
                control={<Badge tone="accent">并击</Badge>}
              />
            ) : null}
            <div className="settings-choice-grid settings-choice-grid--three" role="radiogroup" aria-label="输入方案">
              {INPUT_SCHEMES.map((scheme) => (
                <ChoiceCard
                  key={scheme.id}
                  detail={scheme.detail}
                  icon={scheme.icon}
                  marker="radio"
                  selected={inputScheme === scheme.id}
                  title={scheme.title}
                  onClick={() => {
                    setInputScheme(scheme.id);
                    setStatus(`已切换到${scheme.title}`);
                  }}
                />
              ))}
            </div>
          </SettingsSection>
        );
      }

      return (
        <SettingsSection
          title="词库"
          description="词库负责候选内容；输入方案决定如何检索与组织候选。"
        >
          <SettingRow
            title="雾凇拼音"
            detail="中文主词库 · 全拼、自然码双拼、小鹤双拼与飞耀方案共享"
            icon="book"
            control={(
              <span className="settings-inline-actions">
                <Button icon="download" kind="ghost" onClick={() => setStatus("已打开雾凇拼音学习导入预览")}>导入学习…</Button>
                <Button icon="export" kind="ghost" onClick={() => setStatus("雾凇拼音学习导出任务已模拟")}>导出学习…</Button>
              </span>
            )}
          />
          <SettingRow
            title="五笔86"
            detail="五笔86 码表与独立用户词频"
            icon="grid"
            control={(
              <span className="settings-inline-actions">
                <Button icon="download" kind="ghost" onClick={() => setStatus("已打开五笔86学习导入预览")}>导入学习…</Button>
                <Button icon="export" kind="ghost" onClick={() => setStatus("五笔86学习导出任务已模拟")}>导出学习…</Button>
              </span>
            )}
          />
          <SettingRow
            title="Easy English"
            detail="英文候选、补全、生词兜底与独立学习"
            icon="book"
            control={(
              <span className="settings-inline-actions">
                <Button icon="download" kind="ghost" onClick={() => setStatus("已打开 Easy English 学习导入预览")}>导入学习…</Button>
                <Button icon="export" kind="ghost" onClick={() => setStatus("Easy English 学习导出任务已模拟")}>导出学习…</Button>
              </span>
            )}
          />
          <SettingRow
            title="配置目录"
            detail="~/Library/RimeBuffer · 未显示的方案文件仅作词典或反查依赖"
            icon="database"
            control={(
              <Button kind="secondary" onClick={() => setStatus("已模拟打开配置目录")}>
                打开配置目录
              </Button>
            )}
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
          <SettingsSection
            title="AI 模型"
            description="“AI 生成”是统一缓冲插件；在这里切换它使用的模型连接器。正文只会在你明确点击生成时发送。"
          >
            <div className="settings-choice-grid settings-choice-grid--three" role="radiogroup" aria-label="当前连接器">
              <ChoiceCard
                icon="code"
                marker="radio"
                title="Codex CLI"
                detail="浏览器授权 · 隔离运行"
                selected={connector === "codex"}
                onClick={() => {
                  setConnector("codex");
                  setStatus("已切换到 Codex CLI");
                }}
              />
              <ChoiceCard
                icon="sparkle"
                marker="radio"
                title="Claude Code"
                detail="官方 CLI 授权"
                selected={connector === "claude"}
                onClick={() => {
                  setConnector("claude");
                  setStatus("已切换到 Claude Code");
                }}
              />
              <ChoiceCard
                icon="network"
                marker="radio"
                title="OpenAI API"
                detail="自定义兼容端点"
                selected={connector === "openai"}
                onClick={() => {
                  setConnector("openai");
                  setStatus("已切换到 OpenAI API");
                }}
              />
            </div>

            {connector === "codex" ? (
              <div className="connector-detail-panel">
                <SettingRow
                  title="Codex CLI"
                  detail="使用 RIMES 专用 ChatGPT 登录；不会读取 ~/.codex 中的 MCP、工具、Hook 或技能。"
                  icon="code"
                  control={<Badge tone="accent">可用</Badge>}
                />
                <div className="settings-action-row">
                  <Button kind="secondary" onClick={() => setStatus("已模拟重新授权 Codex")}>
                    重新授权 Codex
                  </Button>
                </div>
                <p className="connector-detail-panel__note">
                  CLI 在本机启动，但不代表本地推理：点击生成后，缓冲全文会经已登录服务发送。RIMES 不会把环境中的 API Key 透传给 Codex。
                </p>
              </div>
            ) : null}

            {connector === "claude" ? (
              <div className="connector-detail-panel">
                <SettingRow
                  title="Claude Code CLI"
                  detail="未找到具备所需流式生成能力的 Claude Code CLI。"
                  icon="sparkle"
                  control={<Badge>不可用</Badge>}
                />
                <div className="settings-action-row">
                  <Button kind="secondary" onClick={() => setStatus("已模拟发起 Claude 授权")}>
                    授权 Claude
                  </Button>
                </div>
                <p className="connector-detail-panel__note">
                  CLI 在本机启动，但不代表本地推理：点击生成后，缓冲全文会经已登录服务发送。RIMES 不会把环境中的 API Key 透传给 Claude Code。
                </p>
              </div>
            ) : null}

            {connector === "openai" ? (
              <div className="connector-detail-panel">
                <Field label="Base URL" hint="应包含 API 前缀（例如 /v1）；程序会追加 /chat/completions。">
                  <input
                    className="r-text-input"
                    onChange={(event) => setOpenAPIBaseURL(event.target.value)}
                    spellCheck={false}
                    value={openAPIBaseURL}
                  />
                </Field>
                <Field label="模型">
                  <input
                    className="r-text-input"
                    onChange={(event) => setOpenAPIModel(event.target.value)}
                    spellCheck={false}
                    value={openAPIModel}
                  />
                </Field>
                <Field label="API Key" hint="密钥保存在权限为 0600 的本地配置文件，不写入偏好设置或日志。">
                  <input
                    className="r-text-input"
                    defaultValue=""
                    placeholder="已保存（留空则保持不变）"
                    spellCheck={false}
                    type="password"
                  />
                </Field>
                <div className="settings-action-row">
                  <Button kind="secondary" onClick={() => setStatus("通用 Open API 配置已保存")}>
                    保存配置
                  </Button>
                  <Button kind="ghost" onClick={() => setStatus("已清除本地 API Key")}>
                    清除密钥
                  </Button>
                </div>
              </div>
            ) : null}
          </SettingsSection>
        );
      }

      if (currentSubpage === "local-gateway") {
        const gatewayJSON = `{
  "mcpServers": {
    "etinput": {
      "type": "http",
      "url": "http://127.0.0.1:47700/mcp",
      "headers": {
        "Authorization": "Bearer ••••••••"
      }
    }
  }
}`;
        const claudeCommand = "claude mcp add --transport http etinput http://127.0.0.1:47700/mcp --header \"Authorization: Bearer ••••••••\"";

        return (
          <SettingsSection
            title="本地网关"
            description="仅监听 127.0.0.1，并要求 Token 鉴权；推入内容仍需你在收件箱逐条确认。"
          >
            <SettingRow
              title="启用本地网关"
              detail="允许本机智能体通过标准 MCP / HTTP 推送待确认内容。"
              icon="network"
              control={(
                <Switch
                  checked={gatewayEnabled}
                  label="启用本地网关"
                  onChange={(enabled) => {
                    setGatewayEnabled(enabled);
                    setStatus(enabled ? "已启用本地网关" : "已关闭本地网关");
                  }}
                />
              )}
            />

            <div className={`connector-detail-panel${gatewayEnabled ? "" : " is-disabled"}`}>
              <header className="connector-detail-panel__header">
                <span>
                  <strong>接入配置</strong>
                  <small>标准 MCP（Streamable HTTP）。Cursor、Codex、Claude Code 等客户端通用。</small>
                </span>
                <Button
                  disabled={!gatewayEnabled}
                  icon="copy"
                  kind="secondary"
                  onClick={() => setStatus("已复制通用 MCP 配置 JSON")}
                >
                  复制配置
                </Button>
              </header>
              <pre aria-label="MCP 配置 JSON" className="settings-code-block">{gatewayJSON}</pre>

              <button
                aria-expanded={gatewayClaudeOpen}
                className="connector-disclosure"
                disabled={!gatewayEnabled}
                onClick={() => setGatewayClaudeOpen((open) => !open)}
                type="button"
              >
                <span>Claude Code 一键注册（可选）</span>
                <Icon name={gatewayClaudeOpen ? "up" : "down"} size={12} weight="bold" />
              </button>
              {gatewayClaudeOpen ? (
                <div className="connector-disclosure__body">
                  <p className="connector-detail-panel__note">
                    等价于上方通用配置；仅在已安装 Claude Code CLI 时需要。
                  </p>
                  <pre aria-label="Claude Code 注册命令" className="settings-code-block settings-code-block--single">
                    {claudeCommand}
                  </pre>
                  <div className="settings-action-row">
                    <Button
                      disabled={!gatewayEnabled}
                      icon="copy"
                      kind="ghost"
                      onClick={() => setStatus("已复制 Claude Code 注册命令")}
                    >
                      复制 Claude Code 命令
                    </Button>
                  </div>
                </div>
              ) : null}
            </div>
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
