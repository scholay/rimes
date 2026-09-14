import {
  useEffect,
  useMemo,
  useState,
  type PropsWithChildren,
  type ReactNode,
} from "react";
import { Icon, type IconName } from "../design-system/Icon";
import { inputSchemes, type PluginRecord } from "../design-system/data";
import {
  Badge,
  Button,
  Field,
  IconButton,
  MacWindow,
  Segmented,
  Switch,
} from "../design-system/primitives";
import {
  themeCSSVariables,
  themeFamilies,
  themeFamilyOrder,
  themes,
  type ThemeID,
} from "../design-system/tokens";
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
  | "core.clipboard"
  | "core.mailbox"
  | "core.capsule"
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
    description: "管理输入方案、词库与本地学习数据；并击能力由独立扩展提供。",
    icon: "keyboard",
    section: "设置",
    subpages: [
      { id: "schemes", title: "输入方案" },
      { id: "dictionaries", title: "词库" },
    ],
  },
  {
    id: "core.appearance",
    title: "外观",
    description: "主题同时作用于候选框、Buffer、Clipboard History 与设置页预览。",
    icon: "appearance",
    section: "设置",
    subpages: [
      { id: "theme", title: "主题" },
      { id: "size", title: "尺寸" },
    ],
  },
  {
    id: "core.buffer",
    title: "Buffer",
    description: "管理独立 Buffer 工作台；Clipboard History 不属于 Buffer。",
    icon: "tray",
    section: "设置",
    subpages: [{ id: "buffer", title: "Buffer" }],
  },
  {
    id: "core.clipboard",
    title: "Clipboard",
    description: "管理独立、仅在本机持久保存的多类型剪贴板历史窗口。",
    icon: "clipboard",
    section: "设置",
    subpages: [{ id: "clipboard", title: "Clipboard History" }],
  },
  {
    id: "core.mailbox",
    title: "Mailbox",
    description: "独立接收、保存和处理本地消息；按需显式发送到 Buffer。",
    icon: "book",
    section: "设置",
    subpages: [{ id: "mailbox", title: "Mailbox" }],
  },
  {
    id: "core.capsule",
    title: "Capsule",
    description: "独立管理八类本机条目，并可选择 iCloud Drive 同步六类可迁移内容与媒体。",
    icon: "database",
    section: "设置",
    subpages: [{ id: "capsule", title: "Capsule" }],
  },
  {
    id: "core.connectors",
    title: "连接器",
    description: "管理 AI 模型与本地网关。",
    icon: "link",
    section: "设置",
    subpages: [
      { id: "ai-model", title: "AI 模型" },
      { id: "local-gateway", title: "本地网关" },
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
    description: "启用飞耀并击或互击输入，并管理课程、练习与本地进度。",
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

  const [selectedSchemeID, setSelectedSchemeID] = useState("rime_ice");
  const [chordMode, setChordMode] = useState<"chord" | "mutual">("mutual");
  const [chordInterval, setChordInterval] = useState(0.10);
  const [chordIsCurrentScheme, setChordIsCurrentScheme] = useState(false);
  const [candidateScale, setCandidateScale] = useState(100);
  const [bufferEnabled, setBufferEnabled] = useState(true);
  const [bufferWindowVisible, setBufferWindowVisible] = useState(true);
  const [bufferPinned, setBufferPinned] = useState(true);
  const [closeAfterLastDelivery, setCloseAfterLastDelivery] = useState(true);
  const [clipboardHistoryEnabled, setClipboardHistoryEnabled] = useState(true);
  const [resetOnAppSwitch, setResetOnAppSwitch] = useState(false);
  const [gatewayEnabled, setGatewayEnabled] = useState(true);
  const [gatewayClaudeOpen, setGatewayClaudeOpen] = useState(false);
  const [connector, setConnector] = useState<"codex" | "claude" | "openai">("codex");
  const [openAPIBaseURL, setOpenAPIBaseURL] = useState("https://api.cometapi.com/v1");
  const [openAPIModel, setOpenAPIModel] = useState("deepseek-v4-flash");
  const [automaticUpdates, setAutomaticUpdates] = useState(true);

  const extensionRoutes = useMemo<SettingsRoute[]>(() => plugins
    .filter((plugin) => (
      plugin.category === "extension"
      && plugin.enabled
    ))
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
  const requestedSubpage = selectedSubpageByRoute[currentRoute.id]
    ?? currentRoute.subpages[0]?.id
    ?? "";
  const currentSubpage = currentRoute.subpages.some((page) => page.id === requestedSubpage)
    ? requestedSubpage
    : (currentRoute.subpages[0]?.id ?? "");

  useEffect(() => {
    if (requestedSubpage === currentSubpage) return;
    setSelectedSubpageByRoute((current) => ({
      ...current,
      [currentRoute.id]: currentSubpage,
    }));
  }, [currentRoute.id, currentSubpage, requestedSubpage]);

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

    if (plugin.id === "builtin.fly-chord-learning") {
      if (currentSubpage === "settings") {
        const activeModeName = chordMode === "chord" ? "飞耀并击" : "飞耀互击";
        return (
          <SettingsSection
            title="并击设置"
            description="扩展开关是并击能力的唯一入口；停用后普通输入和意识流输入都不会再处理并击按键。"
          >
            <SettingRow
              title="启用并击扩展"
              detail={plugin.enabled
                ? "意识流输入可将并击键序转换为连续全拼；普通输入仍需把并击设为当前方案。"
                : "意识流输入保持顺序全拼，普通输入方案不受影响。"}
              icon="hands"
              control={(
                <Switch
                  checked={plugin.enabled}
                  label="启用并击扩展"
                  onChange={(enabled) => {
                    updatePlugin(plugin.id, { enabled });
                    if (!enabled) setChordIsCurrentScheme(false);
                    setStatus(`并击扩展已${enabled ? "启用" : "停用"}`);
                  }}
                />
              )}
            />
            <Field label="输入方式" hint="切换方式不会清除课程进度或已经学习的数据。">
              <div className="settings-choice-grid">
                <ChoiceCard
                  icon="hands"
                  title="飞耀并击"
                  detail="同一时间窗内组合按键"
                  selected={chordMode === "chord"}
                  onClick={() => {
                    setChordMode("chord");
                    setStatus("并击输入方式已切换为飞耀并击");
                  }}
                />
                <ChoiceCard
                  icon="swap"
                  title="飞耀互击"
                  detail="左右手跨击配对"
                  selected={chordMode === "mutual"}
                  onClick={() => {
                    setChordMode("mutual");
                    setStatus("并击输入方式已切换为飞耀互击");
                  }}
                />
              </div>
            </Field>
            <Field
              label={`并击间隔 · ${chordInterval.toFixed(2)} 秒`}
              hint="允许范围 0.02–0.50 秒；修改会保留到下一次启用。"
            >
              <input
                aria-label="并击间隔"
                className="r-range"
                max="0.50"
                min="0.02"
                onChange={(event) => setChordInterval(Number(event.target.value))}
                step="0.01"
                type="range"
                value={chordInterval}
              />
            </Field>
            <div className="settings-action-row">
              <Button
                disabled={!plugin.enabled || chordIsCurrentScheme}
                icon="keyboard"
                kind="primary"
                onClick={() => {
                  setChordIsCurrentScheme(true);
                  setStatus(`${activeModeName}已设为当前输入方案`);
                }}
              >
                {!plugin.enabled
                  ? "先启用扩展"
                  : chordIsCurrentScheme
                    ? "已是当前输入方案"
                    : "设为当前输入方案"}
              </Button>
              <Button
                kind="ghost"
                onClick={() => {
                  setChordInterval(0.10);
                  setStatus("并击间隔已恢复为 0.10 秒");
                }}
              >
                恢复默认间隔
              </Button>
              <Badge tone={chordIsCurrentScheme ? "accent" : "neutral"}>
                {chordIsCurrentScheme ? `当前：${activeModeName}` : "未设为当前方案"}
              </Badge>
            </div>
          </SettingsSection>
        );
      }

      if (currentSubpage === "progress") {
        return (
          <SettingsSection title="并击进度" description="课程、练习和熟练度只保存在本机。">
            <div className="metric-card-grid">
              <article className="metric-card"><small>课程完成</small><strong>12</strong><span>节</span></article>
              <article className="metric-card"><small>练习组合</small><strong>286</strong><span>组</span></article>
              <article className="metric-card"><small>当前准确率</small><strong>93</strong><span>%</span></article>
            </div>
          </SettingsSection>
        );
      }

      const isPractice = currentSubpage === "practice";
      return (
        <SettingsSection
          title={isPractice ? "并击练习" : "并击课程"}
          description={isPractice ? "按当前飞耀模式进行专项练习。" : "从键位、组合到连续输入逐步学习。"}
        >
          <div className="lesson-card-grid">
            {(isPractice ? [
              ["左右手热身", "20 组"],
              ["易错组合", "12 组"],
              ["连续全拼", "自由练习"],
            ] : [
              ["基础键位", "8 / 12 完成"],
              ["左右手互击", "4 / 10 完成"],
              ["常用组合", "尚未开始"],
            ]).map(([title, detail], index) => (
              <article className="lesson-card" key={title}>
                <Icon name={!isPractice && index === 2 ? "lock" : "hands"} size={21} weight="duotone" />
                <strong>{title}</strong>
                <small>{detail}</small>
                <Button
                  kind="ghost"
                  onClick={() => setStatus(`已打开${title}`)}
                >
                  {!isPractice && index === 2 ? "查看要求" : "开始"}
                </Button>
              </article>
            ))}
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
      if (currentSubpage === "schemes") {
        return (
          <SettingsSection
            title="输入方案"
            description="选择普通输入使用的 Rime 方案；并击输入在“并击”扩展中单独启用和设为当前方案。"
          >
            {chordIsCurrentScheme ? (
              <SettingRow
                title="当前使用并击扩展"
                detail={`正在使用${chordMode === "chord" ? "飞耀并击" : "飞耀互击"}；选择下方任一方案即可切回普通输入。`}
                icon="hands"
                control={<Badge tone="accent">并击</Badge>}
              />
            ) : null}
            <div className="settings-choice-grid settings-choice-grid--schemes">
              {inputSchemes.map((scheme) => (
                <ChoiceCard
                  detail={scheme.summary}
                  icon={scheme.icon}
                  key={scheme.id}
                  onClick={() => {
                    setSelectedSchemeID(scheme.id);
                    setChordIsCurrentScheme(false);
                    setStatus(`${scheme.name}已设为当前输入方案`);
                  }}
                  selected={!chordIsCurrentScheme && selectedSchemeID === scheme.id}
                  title={scheme.name}
                />
              ))}
            </div>
            <SettingRow title="方案切换" detail="更换输入方案后将重新部署 Rime 配置；用户学习数据不会被清除。" icon="refresh" control={<Badge>需要部署</Badge>} />
          </SettingsSection>
        );
      }

      return (
        <SettingsSection title="词库" description="内置词库与用户学习数据使用独立的 RimeBuffer 数据目录。">
          <SettingRow title="雾凇拼音" detail="主要中文词库 · 已启用" icon="book" control={<Badge tone="accent">可用</Badge>} />
          <SettingRow title="五笔86" detail="五笔86 码表与用户词频 · 已启用" icon="grid" control={<Badge tone="accent">可用</Badge>} />
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
          <SettingsSection title="主题" description="主题与配色分开管理：经典包含三种既有配色，拉斯塔是一套独立视觉架构。">
            <div className="theme-family-list">
              {themeFamilyOrder.map((familyID) => {
                const family = themeFamilies[familyID];
                return (
                  <section className="theme-family" key={familyID}>
                    <header className="theme-family__header">
                      <span>
                        <strong>{family.title}</strong>
                        <small>{family.description}</small>
                      </span>
                      <Badge>{family.colorways.length > 1 ? `${family.colorways.length} 配色` : "独立主题"}</Badge>
                    </header>
                    <div className="theme-choice-list">
                      {family.colorways.map((id) => {
                        const theme = themes[id];
                        return (
                          <button
                            aria-pressed={activeThemeID === id}
                            className={`theme-choice theme-choice--${familyID}${activeThemeID === id ? " is-selected" : ""}`}
                            key={id}
                            onClick={() => {
                              setActiveThemeID(id);
                              onThemeChange?.(id);
                              setStatus(`已切换到${family.title}${familyID === "classic" ? ` · ${theme.title}` : ""}主题`);
                            }}
                            style={themeCSSVariables(theme)}
                            type="button"
                          >
                            <span className="theme-choice__icon"><Icon name="appearance" size={21} weight="duotone" /></span>
                            <span className="theme-choice__copy"><strong>{theme.title}</strong><small>{theme.description}</small></span>
                            <span aria-hidden="true" className="theme-choice__palette">
                              <i style={{ background: theme.brandRed }} />
                              <i style={{ background: theme.brandYellow }} />
                              <i style={{ background: theme.brandGreen }} />
                            </span>
                            {activeThemeID === id ? <Badge tone="accent">正在使用</Badge> : <Badge>可用</Badge>}
                          </button>
                        );
                      })}
                    </div>
                  </section>
                );
              })}
            </div>
          </SettingsSection>
        );
      }

      return (
        <SettingsSection title="界面尺寸" description="在原生实现中这些数值会映射为 macOS 逻辑点。">
          <Field label={`候选框缩放 · ${candidateScale}%`} hint="同时影响候选字体、行高和内部间距。">
            <input aria-label="候选框缩放" className="r-range" max="130" min="80" onChange={(event) => setCandidateScale(Number(event.target.value))} type="range" value={candidateScale} />
          </Field>
          <SettingRow title="候选框位置" detail="始终跟随当前逻辑输入光标；Buffer 捕获时悬浮在工作台输入光标附近，不占用工作台布局。" icon="textbox" control={<Badge tone="accent">自动</Badge>} />
          <Button kind="secondary" onClick={() => setCandidateScale(100)}>恢复默认尺寸</Button>
        </SettingsSection>
      );
    }

    if (currentRoute.id === "core.buffer") {
      return (
        <SettingsSection title="Buffer" description="关闭工作台会暂停捕获并收束瞬态状态，但保留已经形成的块。">
          <SettingRow title="启用缓冲模式" detail="提交内容先暂存，确认后再发送到当前文本框。" icon="tray" control={<Switch checked={bufferEnabled} label="启用缓冲模式" onChange={setBufferEnabled} />} />
          <SettingRow title="显示独立缓冲工作台" detail="聚焦文本框时把工作台带到当前屏幕。" icon="eye" control={<Switch checked={bufferWindowVisible} label="显示独立缓冲工作台" onChange={setBufferWindowVisible} />} />
          <SettingRow title="常显于所有桌面与全屏空间" detail="适合在应用和全屏空间之间切换时持续使用。" icon="pin" control={<Switch checked={bufferPinned} label="跨桌面常显" onChange={setBufferPinned} />} />
          <SettingRow title="最后一块上屏后关闭工作台" detail="适用于 Default 与所有缓冲插件；部分失败或内容变化时保持打开。" icon="check" control={<Switch checked={closeAfterLastDelivery} label="最后一块上屏后关闭工作台" onChange={setCloseAfterLastDelivery} />} />
          <SettingRow title="切换应用时清空本地缓冲" detail="只在没有外部来源块时执行；默认关闭。" icon="trash" control={<Switch checked={resetOnAppSwitch} label="切换应用时清空本地缓冲" onChange={setResetOnAppSwitch} />} />
          <div className="settings-action-row">
            <Button icon="export" kind="secondary" onClick={() => setStatus("缓冲工作台已移到当前屏幕")}>移到当前屏幕</Button>
            <Button icon="eye" kind="ghost" onClick={() => setBufferWindowVisible(true)}>显示工作台</Button>
          </div>
        </SettingsSection>
      );
    }

    if (currentRoute.id === "core.clipboard") {
      return (
        <SettingsSection title="Clipboard History" description="Clipboard 与 Buffer、Mailbox、Capsule 同级；历史保存在本机私有数据库，窗口关闭后仍会继续收录。">
          <SettingRow title="独立底部窗口" detail="使用 ⌘⇧P 打开 nonactivating 窗口；不会开启 Buffer 或改变它的内容。" icon="clipboard" control={<Badge tone="accent">⌘⇧P</Badge>} />
          <SettingRow title="收录剪贴板历史" detail="RIMES 运行时后台收录文本、链接、图片、文件与颜色；安全保护期间不会读取。" icon="check" control={<Switch checked={clipboardHistoryEnabled} label="收录剪贴板历史" onChange={setClipboardHistoryEnabled} />} />
          <SettingRow title="本机私有历史" detail="图片卡片显示异步缩略图和来源 App 图标；数据不进入仓库，也不提供云同步。" icon="database" control={<Badge tone="neutral">LOCAL</Badge>} />
          <SettingRow title="自动保护" detail="Secure Input、锁屏、睡眠或会话失活时停止读取并遮蔽正文；恢复时不会补录保护期间内容。" icon="lock" control={<Badge tone="accent">FAIL CLOSED</Badge>} />
          <Button icon="eye" kind="secondary" onClick={() => setStatus("已模拟打开 Clipboard History 独立窗口")}>打开 Clipboard History</Button>
        </SettingsSection>
      );
    }

    if (currentRoute.id === "core.mailbox") {
      return (
        <SettingsSection title="Mailbox" description="Mailbox 有自己的窗口、存储和生命周期；发送到 Buffer 是明确触发的可选桥接。">
          <SettingRow title="独立窗口" detail="使用 ⌘⇧M 打开，不要求 Buffer 已显示或启用。" icon="book" control={<Badge tone="accent">⌘⇧M</Badge>} />
          <SettingRow title="本机持久化" detail="会话、备注和审核状态保存在 Mailbox 自己的数据目录。" icon="database" control={<Badge tone="neutral">LOCAL</Badge>} />
          <Button icon="eye" kind="secondary" onClick={() => setStatus("已模拟打开 Mailbox 独立窗口")}>打开 Mailbox</Button>
        </SettingsSection>
      );
    }

    if (currentRoute.id === "core.capsule") {
      return (
        <SettingsSection title="Capsule" description="Capsule 是核心本机内容库，不再出现在 Buffer 插件目录或启停状态中。">
          <SettingRow title="内容类型" detail="Prompt · Memory · Password · Skill · Note · URL · Image · PDF" icon="database" control={<Badge tone="accent">8 TYPES</Badge>} />
          <SettingRow title="本机 Markdown" detail="普通条目兼容 Obsidian；密码字段保持本机密文；图片和 PDF 提供有界预览。" icon="lock" control={<Badge tone="neutral">LOCAL</Badge>} />
          <SettingRow title="iCloud Drive" detail="用户选择同步文件夹；Password、Skill 路径与主密钥不上传，媒体使用内容寻址附件。" icon="database" control={<Badge tone="neutral">OPTIONAL</Badge>} />
          <Button icon="eye" kind="secondary" onClick={() => setStatus("已模拟打开 Capsule 独立窗口")}>打开 Capsule</Button>
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

      return null;
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
        <SettingRow title="RIMES 数据目录" detail="~/Library/RIMES" icon="database" control={<Button kind="secondary" onClick={() => setStatus("已模拟打开 RIMES 数据目录")}>打开数据目录</Button>} />
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
        chordExtensionEnabled={plugins.some((plugin) => (
          plugin.id === "builtin.fly-chord-learning" && plugin.enabled
        ))}
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
