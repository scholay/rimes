import {
  useEffect,
  useRef,
  useState,
  type Dispatch,
  type KeyboardEvent,
  type SetStateAction,
} from "react";
import { Icon } from "../design-system/Icon";
import {
  Badge,
  Button,
  Field,
  IconButton,
  MacWindow,
  Segmented,
  Switch,
} from "../design-system/primitives";
import type { PluginRecord } from "../design-system/data";

export type PluginSetter = Dispatch<SetStateAction<PluginRecord[]>>;

type TranslationLanguage = "auto" | "zh-Hans" | "zh-Hant" | "en" | "ja" | "ko";
type TranslationProvider = "apple" | "ai";

const sourceLanguages: readonly { value: TranslationLanguage; label: string }[] = [
  { value: "auto", label: "自动检测" },
  { value: "zh-Hans", label: "简体中文" },
  { value: "zh-Hant", label: "繁体中文" },
  { value: "en", label: "English" },
  { value: "ja", label: "日本語" },
  { value: "ko", label: "한국어" },
];

const targetLanguages = sourceLanguages.filter((language) => language.value !== "auto");

const pluginStatusLabel = (plugin: PluginRecord) => {
  switch (plugin.installState) {
    case "bundled":
      return "内置";
    case "installed":
      return "已安装";
    case "not-downloaded":
      return "未下载";
    case "downloading":
      return "下载中";
    case "failed":
      return "下载失败";
  }
};

export type PluginConfiguration = Record<string, string | number | boolean>;
export type PluginConfigurationMap = Record<string, PluginConfiguration>;

export function PluginConfigurationDialog({
  plugin,
  initialConfiguration,
  onClose,
  onSave,
}: {
  plugin: PluginRecord | null;
  initialConfiguration?: PluginConfiguration;
  onClose: () => void;
  onSave?: (plugin: PluginRecord, configuration: PluginConfiguration) => void;
}) {
  const [sourceLanguage, setSourceLanguage] = useState<TranslationLanguage>("auto");
  const [targetLanguage, setTargetLanguage] = useState<TranslationLanguage>("zh-Hans");
  const [translationProvider, setTranslationProvider] = useState<TranslationProvider>("apple");
  const [translateContinuously, setTranslateContinuously] = useState(true);
  const [connector, setConnector] = useState("codex");
  const [promptDirectory, setPromptDirectory] = useState("~/Documents/Prompts");
  const [syncRemotePrompts, setSyncRemotePrompts] = useState(true);
  const [streamCandidates, setStreamCandidates] = useState("3");
  const [streamLatency, setStreamLatency] = useState("balanced");
  const [saved, setSaved] = useState(false);
  const dialogRef = useRef<HTMLElement | null>(null);

  useEffect(() => {
    setSaved(false);
    const configuration = initialConfiguration ?? {};
    const source = configuration.sourceLanguage;
    const target = configuration.targetLanguage;
    const provider = configuration.provider;
    setSourceLanguage(
      typeof source === "string" && sourceLanguages.some((item) => item.value === source)
        ? source as TranslationLanguage
        : "auto",
    );
    setTargetLanguage(
      typeof target === "string" && targetLanguages.some((item) => item.value === target)
        ? target as TranslationLanguage
        : "zh-Hans",
    );
    setTranslationProvider(provider === "ai" ? "ai" : "apple");
    setTranslateContinuously(
      typeof configuration.translateContinuously === "boolean"
        ? configuration.translateContinuously
        : true,
    );
    setConnector(typeof configuration.connector === "string" ? configuration.connector : "codex");
    setPromptDirectory(
      typeof configuration.promptDirectory === "string"
        ? configuration.promptDirectory
        : "~/Documents/Prompts",
    );
    setSyncRemotePrompts(
      typeof configuration.syncRemotePrompts === "boolean"
        ? configuration.syncRemotePrompts
        : true,
    );
    setStreamCandidates(
      typeof configuration.candidateCount === "number"
        ? String(configuration.candidateCount)
        : "3",
    );
    setStreamLatency(
      typeof configuration.latency === "string" ? configuration.latency : "balanced",
    );
  }, [initialConfiguration, plugin?.id]);

  useEffect(() => {
    if (!plugin) return;
    const priorFocus = document.activeElement instanceof HTMLElement
      ? document.activeElement
      : null;
    const frame = window.requestAnimationFrame(() => {
      dialogRef.current
        ?.querySelector<HTMLElement>("button, select, input, [tabindex]:not([tabindex='-1'])")
        ?.focus();
    });
    return () => {
      window.cancelAnimationFrame(frame);
      priorFocus?.focus();
    };
  }, [plugin]);

  if (!plugin) return null;

  const swapTranslationLanguages = () => {
    const nextSource = targetLanguage;
    const nextTarget = sourceLanguage === "auto" ? "en" : sourceLanguage;
    setSourceLanguage(nextSource);
    setTargetLanguage(nextTarget);
    setSaved(false);
  };

  const configuration = (): PluginConfiguration => {
    switch (plugin.id) {
      case "builtin.apple-translation":
        return {
          sourceLanguage,
          targetLanguage,
          provider: translationProvider,
          translateContinuously,
        };
      case "builtin.ai-text":
        return { connector };
      case "builtin.my-prompt":
        return { promptDirectory, syncRemotePrompts };
      case "builtin.stream-input":
        return {
          candidateCount: Number(streamCandidates),
          latency: streamLatency,
        };
      default:
        return { enabled: plugin.enabled };
    }
  };

  const save = () => {
    onSave?.(plugin, configuration());
    setSaved(true);
  };

  const handleDialogKeyDown = (event: KeyboardEvent<HTMLElement>) => {
    if (event.key === "Escape") {
      event.preventDefault();
      onClose();
      return;
    }
    if (event.key !== "Tab") return;
    const focusable = Array.from(dialogRef.current?.querySelectorAll<HTMLElement>(
      "button:not(:disabled), select:not(:disabled), input:not(:disabled), [tabindex]:not([tabindex='-1'])",
    ) ?? []);
    if (focusable.length === 0) return;
    const currentIndex = focusable.indexOf(document.activeElement as HTMLElement);
    const nextIndex = event.shiftKey
      ? (currentIndex <= 0 ? focusable.length - 1 : currentIndex - 1)
      : (currentIndex < 0 || currentIndex === focusable.length - 1 ? 0 : currentIndex + 1);
    event.preventDefault();
    focusable[nextIndex]?.focus();
  };

  return (
    <div className="plugin-dialog-backdrop" onMouseDown={onClose}>
      <section
        aria-labelledby="plugin-dialog-title"
        aria-modal="true"
        className="plugin-dialog"
        onKeyDown={handleDialogKeyDown}
        onMouseDown={(event) => event.stopPropagation()}
        ref={dialogRef}
        role="dialog"
      >
        <header className="plugin-dialog__header">
          <span className="plugin-dialog__icon">
            <Icon name={plugin.icon} size={21} weight="duotone" />
          </span>
          <span className="plugin-dialog__heading">
            <strong id="plugin-dialog-title">{plugin.name} 设置</strong>
            <span>v{plugin.version}</span>
          </span>
          <IconButton icon="close" label="关闭插件设置" onClick={onClose} />
        </header>

        <div className="plugin-dialog__body">
          {plugin.id === "builtin.apple-translation" ? (
            <>
              <div className="translation-language-row">
                <Field label="源语言" hint="自动检测只适用于源缓冲区。">
                  <select
                    aria-label="实时翻译源语言"
                    className="r-native-select"
                    onChange={(event) => {
                      setSourceLanguage(event.target.value as TranslationLanguage);
                      setSaved(false);
                    }}
                    value={sourceLanguage}
                  >
                    {sourceLanguages.map((language) => (
                      <option key={language.value} value={language.value}>
                        {language.label}
                      </option>
                    ))}
                  </select>
                </Field>

                <IconButton
                  icon="swap"
                  label="交换源语言和目标语言"
                  onClick={swapTranslationLanguages}
                />

                <Field label="目标语言" hint="目标语言必须明确指定。">
                  <select
                    aria-label="实时翻译目标语言"
                    className="r-native-select"
                    onChange={(event) => {
                      setTargetLanguage(event.target.value as TranslationLanguage);
                      setSaved(false);
                    }}
                    value={targetLanguage}
                  >
                    {targetLanguages.map((language) => (
                      <option key={language.value} value={language.value}>
                        {language.label}
                      </option>
                    ))}
                  </select>
                </Field>
              </div>

              <Field label="翻译通道" hint="Apple 本地翻译需要 macOS 15 或更高版本。">
                <Segmented
                  ariaLabel="翻译通道"
                  onChange={(value) => {
                    setTranslationProvider(value);
                    setSaved(false);
                  }}
                  options={[
                    { value: "apple", label: "Apple 本地" },
                    { value: "ai", label: "当前 AI 连接器" },
                  ]}
                  value={translationProvider}
                />
              </Field>

              <div className="settings-control-row">
                <span>
                  <strong>连续翻译</strong>
                  <small>源缓冲变化后更新独立目标轨，不会自动上屏。</small>
                </span>
                <Switch
                  checked={translateContinuously}
                  label="连续翻译"
                  onChange={(next) => {
                    setTranslateContinuously(next);
                    setSaved(false);
                  }}
                />
              </div>
            </>
          ) : null}

          {plugin.id === "builtin.ai-text" ? (
            <Field label="默认连接器" hint="只在用户明确触发生成时发送当前缓冲正文。">
              <select
                className="r-native-select"
                onChange={(event) => {
                  setConnector(event.target.value);
                  setSaved(false);
                }}
                value={connector}
              >
                <option value="codex">Codex CLI</option>
                <option value="claude">Claude Code CLI</option>
                <option value="openai">OpenAI 兼容 API</option>
              </select>
            </Field>
          ) : null}

          {plugin.id === "builtin.my-prompt" ? (
            <>
              <Field label="本地提示词目录" hint="支持 Markdown、Obsidian 与 Fabric 风格文件。">
                <input
                  className="r-text-input"
                  onChange={(event) => {
                    setPromptDirectory(event.target.value);
                    setSaved(false);
                  }}
                  value={promptDirectory}
                />
              </Field>
              <div className="settings-control-row">
                <span>
                  <strong>启动时同步远程仓库</strong>
                  <small>远程内容先同步到本地，再建立检索索引。</small>
                </span>
                <Switch
                  checked={syncRemotePrompts}
                  label="启动时同步远程提示词仓库"
                  onChange={(next) => {
                    setSyncRemotePrompts(next);
                    setSaved(false);
                  }}
                />
              </div>
            </>
          ) : null}

          {plugin.id === "builtin.stream-input" ? (
            <>
              <Field label="候选数量" hint="连续全拼最多展示三个完整猜测。">
                <Segmented
                  ariaLabel="意识流候选数量"
                  onChange={(value) => {
                    setStreamCandidates(value);
                    setSaved(false);
                  }}
                  options={[
                    { value: "1", label: "1 个" },
                    { value: "2", label: "2 个" },
                    { value: "3", label: "3 个" },
                  ]}
                  value={streamCandidates}
                />
              </Field>
              <Field label="响应节奏">
                <Segmented
                  ariaLabel="意识流响应节奏"
                  onChange={(value) => {
                    setStreamLatency(value);
                    setSaved(false);
                  }}
                  options={[
                    { value: "fast", label: "灵敏" },
                    { value: "balanced", label: "平衡" },
                    { value: "stable", label: "稳定" },
                  ]}
                  value={streamLatency}
                />
              </Field>
            </>
          ) : null}

          {![
            "builtin.apple-translation",
            "builtin.ai-text",
            "builtin.my-prompt",
            "builtin.stream-input",
          ].includes(plugin.id) ? (
            <div className="plugin-dialog__notice">
              <Icon name="info" size={18} weight="duotone" />
              <span>{plugin.summary}</span>
            </div>
          ) : null}
        </div>

        <footer className="plugin-dialog__footer">
          <span aria-live="polite" className="plugin-dialog__save-status">
            {saved ? "配置已保存到当前设计场景" : "所有处理结果仍需手动确认上屏"}
          </span>
          <Button kind="ghost" onClick={onClose}>取消</Button>
          <Button icon="check" kind="primary" onClick={save}>保存配置</Button>
        </footer>
      </section>
    </div>
  );
}

export type ExtensionsSurfaceProps = {
  plugins: PluginRecord[];
  setPlugins: PluginSetter;
  pluginConfigurations?: PluginConfigurationMap;
  onPluginConfigurationChange?: (
    plugin: PluginRecord,
    configuration: PluginConfiguration,
  ) => void;
  onOpenSettings?: (routeID?: string) => void;
  defaultMenuOpen?: boolean;
};

export function ExtensionsSurface({
  plugins,
  setPlugins,
  pluginConfigurations = {},
  onPluginConfigurationChange,
  onOpenSettings,
  defaultMenuOpen = true,
}: ExtensionsSurfaceProps) {
  const [menuOpen, setMenuOpen] = useState(defaultMenuOpen);
  const [engineHealthy, setEngineHealthy] = useState(true);
  const [selectedPlugin, setSelectedPlugin] = useState<PluginRecord | null>(null);
  const [activity, setActivity] = useState("等待操作");

  const configurePlugin = (plugin: PluginRecord) => {
    setSelectedPlugin(plugin);
    setActivity(`正在配置 ${plugin.name}`);
  };

  const downloadPlugin = (plugin: PluginRecord) => {
    setPlugins((current) => current.map((item) => (
      item.id === plugin.id ? { ...item, installState: "downloading" } : item
    )));
    setActivity(`正在从 GitHub 下载 ${plugin.name}`);
    window.setTimeout(() => {
      setPlugins((current) => current.map((item) => (
        item.id === plugin.id
          ? { ...item, installState: "installed", enabled: false }
          : item
      )));
      setActivity(`${plugin.name} 已下载，保持停用`);
    }, 850);
  };

  const installedPlugins = plugins.filter((plugin) => (
    plugin.installState === "bundled" || plugin.installState === "installed"
  ));

  return (
    <div className="extensions-surface">
      <MacWindow title="RIMES · 扩展与菜单" className="extensions-window">
        <div className="extensions-stage">
          <section className="menu-bar-preview" aria-label="macOS 输入法菜单预览">
            <div className="menu-bar-preview__wallpaper">
              <span>设计工作区</span>
              <button
                aria-expanded={menuOpen}
                aria-haspopup="menu"
                className={`input-source-trigger${menuOpen ? " is-active" : ""}`}
                onClick={() => setMenuOpen((open) => !open)}
                type="button"
              >
                <Icon name="keyboard" size={17} weight="bold" />
                <span>中</span>
              </button>
            </div>

            {menuOpen ? (
              <div aria-label="RIMES 输入法菜单" className="native-input-menu" role="menu">
                <header className="native-input-menu__header">
                  <span>
                    <strong>RIMES</strong>
                    <small>雾凇拼音 · 双拼</small>
                  </span>
                  <Badge tone={engineHealthy ? "accent" : "warning"}>
                    {engineHealthy ? "运行正常" : "英文直通"}
                  </Badge>
                </header>

                {!engineHealthy ? (
                  <div className="native-input-menu__warning" role="status">
                    <Icon name="warning" size={16} weight="fill" />
                    <span>输入引擎异常，当前已退化为英文直通</span>
                  </div>
                ) : null}

                <button
                  className="native-input-menu__item"
                  onClick={() => {
                    onOpenSettings?.();
                    setActivity("已打开设置后台");
                  }}
                  role="menuitem"
                  type="button"
                >
                  <Icon name="gear" size={15} />
                  <span>设置…</span>
                </button>
                <button
                  className="native-input-menu__item"
                  onClick={() => {
                    onOpenSettings?.("core.maintenance");
                    setActivity("已打开设置 › 维护");
                  }}
                  role="menuitem"
                  type="button"
                >
                  <Icon name="tools" size={15} />
                  <span>维护…</span>
                </button>
              </div>
            ) : null}
          </section>

          <aside className="extensions-inspector">
            <header className="extensions-inspector__header">
              <span>
                <strong>插件配置入口</strong>
                <small>已安装插件使用同一配置弹窗。</small>
              </span>
              <Button
                icon={engineHealthy ? "warning" : "check"}
                kind="ghost"
                onClick={() => setEngineHealthy((healthy) => !healthy)}
              >
                {engineHealthy ? "模拟故障" : "恢复引擎"}
              </Button>
            </header>

            <div className="extensions-inspector__list">
              {plugins.map((plugin) => {
                const available = plugin.installState === "bundled" || plugin.installState === "installed";
                return (
                  <article className="extension-launcher" key={plugin.id}>
                    <span className="extension-launcher__icon">
                      <Icon name={plugin.icon} size={19} weight="duotone" />
                    </span>
                    <span className="extension-launcher__copy">
                      <strong>{plugin.name}</strong>
                      <small>v{plugin.version} · {pluginStatusLabel(plugin)}</small>
                    </span>
                    {available && plugin.configurable ? (
                      <IconButton
                        icon="gear"
                        label={`配置 ${plugin.name}`}
                        onClick={() => configurePlugin(plugin)}
                      />
                    ) : null}
                    {!available ? (
                      <Button
                        icon="cloudDownload"
                        kind="ghost"
                        disabled={plugin.installState === "downloading"}
                        onClick={() => downloadPlugin(plugin)}
                      >
                        {plugin.installState === "downloading" ? "下载中" : "下载"}
                      </Button>
                    ) : null}
                  </article>
                );
              })}
            </div>
          </aside>
        </div>

        <footer className="extensions-status-bar">
          <Icon name="info" size={15} />
          <span aria-live="polite">{activity}</span>
          <span>{installedPlugins.length} 个插件可用</span>
        </footer>
      </MacWindow>

      <PluginConfigurationDialog
        initialConfiguration={selectedPlugin ? pluginConfigurations[selectedPlugin.id] : undefined}
        onClose={() => setSelectedPlugin(null)}
        onSave={(plugin, configuration) => {
          onPluginConfigurationChange?.(plugin, configuration);
          setActivity(`${plugin.name} 配置已保存`);
        }}
        plugin={selectedPlugin}
      />
    </div>
  );
}
