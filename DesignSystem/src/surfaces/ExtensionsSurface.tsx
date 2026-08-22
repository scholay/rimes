import {
  useEffect,
  useId,
  useRef,
  useState,
  type Dispatch,
  type FocusEvent,
  type KeyboardEvent,
  type SetStateAction,
} from "react";
import { Icon, type IconName } from "../design-system/Icon";
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

export type InboxItem = {
  id: string;
  source: string;
  context: string;
  preview: string;
  receivedAt: string;
  icon: IconName;
};

const demoInboxItems: readonly InboxItem[] = [
  {
    id: "paired-local-brief",
    source: "本地配对来源",
    context: "配对文本",
    preview: "把这段配对传入的文字加入 Buffer，稍后继续整理。",
    receivedAt: "刚刚",
    icon: "network",
  },
  {
    id: "paired-iphone-note",
    source: "配对设备 · iPhone",
    context: "文本传入",
    preview: "下次迭代优先检查候选框切换应用后的可见性。",
    receivedAt: "2 分钟前",
    icon: "textbox",
  },
];

const copyDemoInboxItems = (): InboxItem[] => demoInboxItems.map((item) => ({ ...item }));

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
  chordExtensionEnabled = false,
  initialConfiguration,
  onClose,
  onSave,
}: {
  plugin: PluginRecord | null;
  chordExtensionEnabled?: boolean;
  initialConfiguration?: PluginConfiguration;
  onClose: () => void;
  onSave?: (plugin: PluginRecord, configuration: PluginConfiguration) => void;
}) {
  const [sourceLanguage, setSourceLanguage] = useState<TranslationLanguage>("auto");
  const [targetLanguage, setTargetLanguage] = useState<TranslationLanguage>("zh-Hans");
  const [translationProvider, setTranslationProvider] = useState<TranslationProvider>("apple");
  const [translateContinuously, setTranslateContinuously] = useState(true);
  const [connector, setConnector] = useState("codex");
  const [streamCandidates, setStreamCandidates] = useState("5");
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
    setStreamCandidates(
      typeof configuration.candidateCount === "number"
        && configuration.candidateCount >= 1
        && configuration.candidateCount <= 5
        ? String(configuration.candidateCount)
        : "5",
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

          {plugin.id === "builtin.stream-input" ? (
            <>
              <div className="plugin-dialog__notice" role="status">
                <Icon name={chordExtensionEnabled ? "hands" : "keyboard"} size={18} weight="duotone" />
                <span>
                  {chordExtensionEnabled
                    ? "并击扩展已启用：意识流输入支持并击键序，并在生成前转换为连续全拼。"
                    : "并击扩展已停用：意识流输入保持顺序全拼，不处理并击键序。"}
                </span>
              </div>
              <Field label="候选数量" hint="连续全拼可展示一至五个完整猜测，多项结果使用分页切换。">
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
                    { value: "4", label: "4 个" },
                    { value: "5", label: "5 个" },
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
  onAcceptInboxItem?: (item: InboxItem) => void;
  defaultMenuOpen?: boolean;
};

export function ExtensionsSurface({
  plugins,
  setPlugins,
  pluginConfigurations = {},
  onPluginConfigurationChange,
  onOpenSettings,
  onAcceptInboxItem,
  defaultMenuOpen = true,
}: ExtensionsSurfaceProps) {
  const [menuOpen, setMenuOpen] = useState(defaultMenuOpen);
  const [engineHealthy, setEngineHealthy] = useState(true);
  const [selectedPlugin, setSelectedPlugin] = useState<PluginRecord | null>(null);
  const [inboxOpen, setInboxOpen] = useState(false);
  const [gatewayOnline, setGatewayOnline] = useState(true);
  const [inboxItems, setInboxItems] = useState<InboxItem[]>(copyDemoInboxItems);
  const [acceptedInboxCount, setAcceptedInboxCount] = useState(0);
  const [rejectedInboxCount, setRejectedInboxCount] = useState(0);
  const [activity, setActivity] = useState("等待操作");
  const menuTriggerRef = useRef<HTMLButtonElement | null>(null);
  const menuRef = useRef<HTMLDivElement | null>(null);
  const pendingMenuFocusRef = useRef<"first" | "last" | null>(null);
  const inboxDialogRef = useRef<HTMLElement | null>(null);
  const pendingInboxReviewFocusRef = useRef<{
    index: number;
    outcome: "accepted" | "rejected";
  } | null>(null);
  const inboxDialogTitleID = useId();
  const inboxDialogDescriptionID = useId();

  const getMenuItems = () => Array.from(
    menuRef.current?.querySelectorAll<HTMLButtonElement>("[role='menuitem']") ?? [],
  );

  const focusMenuEdge = (edge: "first" | "last") => {
    window.requestAnimationFrame(() => {
      const items = getMenuItems();
      items[edge === "first" ? 0 : items.length - 1]?.focus();
    });
  };

  const openMenuFromKeyboard = (edge: "first" | "last") => {
    if (menuOpen) {
      focusMenuEdge(edge);
      return;
    }
    pendingMenuFocusRef.current = edge;
    setMenuOpen(true);
  };

  const closeMenu = (restoreFocus = false) => {
    pendingMenuFocusRef.current = null;
    setMenuOpen(false);
    if (restoreFocus) {
      window.requestAnimationFrame(() => menuTriggerRef.current?.focus());
    }
  };

  useEffect(() => {
    if (!menuOpen || pendingMenuFocusRef.current === null) return;
    const edge = pendingMenuFocusRef.current;
    pendingMenuFocusRef.current = null;
    focusMenuEdge(edge);
  }, [menuOpen]);

  useEffect(() => {
    if (!menuOpen) return;
    const closeOnOutsidePointer = (event: PointerEvent) => {
      const target = event.target;
      if (!(target instanceof Node)) return;
      if (menuRef.current?.contains(target) || menuTriggerRef.current?.contains(target)) return;
      closeMenu();
    };
    document.addEventListener("pointerdown", closeOnOutsidePointer, true);
    return () => document.removeEventListener("pointerdown", closeOnOutsidePointer, true);
  }, [menuOpen]);

  useEffect(() => {
    if (!inboxOpen) return;
    const frame = window.requestAnimationFrame(() => {
      inboxDialogRef.current
        ?.querySelector<HTMLElement>(
          "button:not(:disabled), [href], input:not(:disabled), select:not(:disabled), [tabindex]:not([tabindex='-1'])",
        )
        ?.focus();
    });
    return () => {
      window.cancelAnimationFrame(frame);
      window.requestAnimationFrame(() => menuTriggerRef.current?.focus());
    };
  }, [inboxOpen]);

  useEffect(() => {
    const pendingFocus = pendingInboxReviewFocusRef.current;
    if (!inboxOpen || pendingFocus === null) return;
    pendingInboxReviewFocusRef.current = null;
    const matchingActions = Array.from(
      inboxDialogRef.current?.querySelectorAll<HTMLButtonElement>(
        `[data-inbox-review-action="${pendingFocus.outcome}"]`,
      ) ?? [],
    );
    const nextAction = matchingActions[
      Math.min(pendingFocus.index, matchingActions.length - 1)
    ];
    const fallback = inboxDialogRef.current?.querySelector<HTMLButtonElement>(
      "[data-inbox-empty-action], [data-inbox-finish-action]",
    );
    (nextAction ?? fallback)?.focus();
  }, [inboxItems, inboxOpen]);

  const handleMenuKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (event.key === "Tab") {
      event.preventDefault();
      const menu = menuRef.current;
      const destination = event.shiftKey
        ? menuTriggerRef.current
        : Array.from(document.querySelectorAll<HTMLElement>(
          "button:not(:disabled), [href], input:not(:disabled), select:not(:disabled), [tabindex]:not([tabindex='-1'])",
        )).find((candidate) => (
          menu !== null
          && !menu.contains(candidate)
          && (menu.compareDocumentPosition(candidate) & Node.DOCUMENT_POSITION_FOLLOWING) !== 0
        ));
      closeMenu();
      window.requestAnimationFrame(() => destination?.focus());
      return;
    }
    const items = getMenuItems();
    if (items.length === 0) return;
    const currentIndex = items.indexOf(document.activeElement as HTMLButtonElement);
    let nextIndex: number | null = null;
    switch (event.key) {
      case "ArrowDown":
        nextIndex = currentIndex < 0 ? 0 : (currentIndex + 1) % items.length;
        break;
      case "ArrowUp":
        nextIndex = currentIndex < 0 ? items.length - 1 : (currentIndex - 1 + items.length) % items.length;
        break;
      case "Home":
        nextIndex = 0;
        break;
      case "End":
        nextIndex = items.length - 1;
        break;
      case "Escape":
        event.preventDefault();
        event.stopPropagation();
        closeMenu(true);
        return;
      default:
        return;
    }
    event.preventDefault();
    items[nextIndex]?.focus();
  };

  const handleMenuBlur = (event: FocusEvent<HTMLDivElement>) => {
    const nextTarget = event.relatedTarget;
    if (nextTarget instanceof Node && menuRef.current?.contains(nextTarget)) return;
    closeMenu();
  };

  const handleInboxDialogKeyDown = (event: KeyboardEvent<HTMLElement>) => {
    if (event.key === "Escape") {
      event.preventDefault();
      setInboxOpen(false);
      return;
    }
    if (event.key !== "Tab") return;
    const focusable = Array.from(inboxDialogRef.current?.querySelectorAll<HTMLElement>(
      "button:not(:disabled), [href], input:not(:disabled), select:not(:disabled), [tabindex]:not([tabindex='-1'])",
    ) ?? []);
    if (focusable.length === 0) return;
    const currentIndex = focusable.indexOf(document.activeElement as HTMLElement);
    const nextIndex = event.shiftKey
      ? (currentIndex <= 0 ? focusable.length - 1 : currentIndex - 1)
      : (currentIndex < 0 || currentIndex === focusable.length - 1 ? 0 : currentIndex + 1);
    event.preventDefault();
    focusable[nextIndex]?.focus();
  };

  const openInbox = () => {
    closeMenu();
    setInboxOpen(true);
    setActivity(`已打开外部来源收件箱 · ${inboxItems.length} 项待审`);
  };

  const reviewInboxItem = (item: InboxItem, outcome: "accepted" | "rejected") => {
    setInboxItems((current) => {
      const itemIndex = current.findIndex((candidate) => candidate.id === item.id);
      if (itemIndex < 0) return current;
      pendingInboxReviewFocusRef.current = { index: itemIndex, outcome };
      return current.filter((candidate) => candidate.id !== item.id);
    });
    if (outcome === "accepted") {
      onAcceptInboxItem?.(item);
      setAcceptedInboxCount((count) => count + 1);
      setActivity(`已接受来自 ${item.source} 的内容到 Buffer（本地模拟）`);
    } else {
      setRejectedInboxCount((count) => count + 1);
      setActivity(`已拒绝来自 ${item.source} 的内容（本地模拟）`);
    }
  };

  const refillInbox = () => {
    pendingInboxReviewFocusRef.current = { index: 0, outcome: "accepted" };
    setInboxItems(copyDemoInboxItems());
    setActivity("已加入 2 项本地模拟待审内容");
  };

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
                onClick={() => {
                  pendingMenuFocusRef.current = null;
                  setMenuOpen((open) => !open);
                }}
                onKeyDown={(event) => {
                  if (event.key === "ArrowDown" || event.key === "ArrowUp") {
                    event.preventDefault();
                    openMenuFromKeyboard(event.key === "ArrowDown" ? "first" : "last");
                  } else if (event.key === "Escape" && menuOpen) {
                    event.preventDefault();
                    closeMenu(true);
                  }
                }}
                ref={menuTriggerRef}
                type="button"
              >
                <Icon name="keyboard" size={17} weight="bold" />
                <span>中</span>
              </button>
            </div>

            {menuOpen ? (
              <div
                aria-label="RIMES 输入法菜单"
                className="native-input-menu"
                onBlur={handleMenuBlur}
                onKeyDown={handleMenuKeyDown}
                ref={menuRef}
                role="menu"
              >
                <header className="native-input-menu__header" role="presentation">
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
                    closeMenu();
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
                  aria-label={`外部来源收件箱，${inboxItems.length} 项待审`}
                  className="native-input-menu__item"
                  onClick={openInbox}
                  role="menuitem"
                  type="button"
                >
                  <Icon name="tray" size={15} />
                  <span>外部来源收件箱…</span>
                  <span aria-hidden="true" className="native-input-menu__meta">
                    {inboxItems.length}
                  </span>
                </button>
                <button
                  className="native-input-menu__item"
                  onClick={() => {
                    closeMenu();
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
                    {available
                    && plugin.id === "builtin.fly-chord-learning"
                    && plugin.enabled ? (
                      <IconButton
                        icon="gear"
                        label={`配置 ${plugin.name}`}
                        onClick={() => {
                          onOpenSettings?.("extension.fly-chord-learning");
                          setActivity("已打开并击扩展设置");
                        }}
                      />
                    ) : available && plugin.configurable ? (
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
          <span aria-live={inboxOpen ? "off" : "polite"}>{activity}</span>
          <span>{installedPlugins.length} 个插件可用</span>
        </footer>
      </MacWindow>

      <PluginConfigurationDialog
        chordExtensionEnabled={plugins.some((plugin) => (
          plugin.id === "builtin.fly-chord-learning" && plugin.enabled
        ))}
        initialConfiguration={selectedPlugin ? pluginConfigurations[selectedPlugin.id] : undefined}
        onClose={() => setSelectedPlugin(null)}
        onSave={(plugin, configuration) => {
          onPluginConfigurationChange?.(plugin, configuration);
          setActivity(`${plugin.name} 配置已保存`);
        }}
        plugin={selectedPlugin}
      />

      {inboxOpen ? (
        <div className="inbox-dialog-backdrop" onMouseDown={() => setInboxOpen(false)}>
          <section
            aria-describedby={inboxDialogDescriptionID}
            aria-labelledby={inboxDialogTitleID}
            aria-modal="true"
            className="inbox-dialog"
            onKeyDown={handleInboxDialogKeyDown}
            onMouseDown={(event) => event.stopPropagation()}
            ref={inboxDialogRef}
            role="dialog"
          >
            <header className="inbox-dialog__header">
              <span className="inbox-dialog__icon">
                <Icon name="tray" size={22} weight="duotone" />
              </span>
              <span className="inbox-dialog__heading">
                <strong id={inboxDialogTitleID}>外部来源收件箱</strong>
                <small id={inboxDialogDescriptionID}>审核外部传入内容后，再明确加入 Buffer。</small>
              </span>
              <Badge tone={inboxItems.length > 0 ? "accent" : "neutral"}>
                {inboxItems.length} 项待审
              </Badge>
              <IconButton
                icon="close"
                label="关闭外部来源收件箱"
                onClick={() => setInboxOpen(false)}
              />
            </header>

            <div className="inbox-dialog__body">
              <section className="inbox-gateway" aria-label="外部传字网关状态">
                <span
                  aria-hidden="true"
                  className={`inbox-gateway__indicator${gatewayOnline ? " is-online" : ""}`}
                />
                <span className="inbox-gateway__copy">
                  <strong>外部传字网关</strong>
                  <small>仅接收明确配对的外部来源；不读取或保存系统剪贴板。</small>
                </span>
                <Badge tone={gatewayOnline ? "accent" : "warning"}>
                  {gatewayOnline ? "在线" : "离线"}
                </Badge>
                <Button
                  kind="ghost"
                  onClick={() => {
                    setGatewayOnline((online) => {
                      setActivity(online ? "外部传字网关已切换为离线模拟" : "外部传字网关已恢复在线模拟");
                      return !online;
                    });
                  }}
                >
                  {gatewayOnline ? "模拟离线" : "恢复在线"}
                </Button>
              </section>

              {inboxItems.length > 0 ? (
                <div aria-label="待审外部内容" className="inbox-review-list" role="list">
                  {inboxItems.map((item) => (
                    <article className="inbox-review-item" key={item.id} role="listitem">
                      <span className="inbox-review-item__icon">
                        <Icon name={item.icon} size={18} weight="duotone" />
                      </span>
                      <span className="inbox-review-item__content">
                        <span className="inbox-review-item__meta">
                          <strong>{item.source}</strong>
                          <small>{item.context} · {item.receivedAt}</small>
                        </span>
                        <span className="inbox-review-item__preview">{item.preview}</span>
                      </span>
                      <span className="inbox-review-item__actions">
                        <Button
                          aria-label={`拒绝 ${item.source} 内容`}
                          data-inbox-review-action="rejected"
                          kind="ghost"
                          onClick={() => reviewInboxItem(item, "rejected")}
                        >
                          拒绝
                        </Button>
                        <Button
                          aria-label={`接受 ${item.source} 内容并加入 Buffer`}
                          data-inbox-review-action="accepted"
                          icon="check"
                          kind="primary"
                          onClick={() => reviewInboxItem(item, "accepted")}
                        >
                          接受并加入 Buffer
                        </Button>
                      </span>
                    </article>
                  ))}
                </div>
              ) : (
                <div className="inbox-empty" role="status">
                  <span className="inbox-empty__icon"><Icon name="check" size={22} weight="bold" /></span>
                  <strong>没有等待审核的外部内容</strong>
                  <small>新内容到达时会留在这里，除非你明确接受，否则不会进入 Buffer。</small>
                  <Button
                    data-inbox-empty-action
                    icon="plus"
                    kind="secondary"
                    onClick={refillInbox}
                  >
                    加入模拟待审项
                  </Button>
                </div>
              )}
            </div>

            <footer className="inbox-dialog__footer">
              <span aria-live="polite">
                待审 {inboxItems.length} · 已接受 {acceptedInboxCount} · 已拒绝 {rejectedInboxCount}
              </span>
              <Button
                data-inbox-finish-action
                kind="primary"
                onClick={() => setInboxOpen(false)}
              >
                完成
              </Button>
            </footer>
          </section>
        </div>
      ) : null}
    </div>
  );
}
