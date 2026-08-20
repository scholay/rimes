import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ChangeEvent,
} from "react";
import { Icon, type IconName } from "../design-system/Icon";
import { initialPlugins } from "../design-system/data";
import { Button, IconButton } from "../design-system/primitives";

export type BufferMode =
  | "normal"
  | "ai"
  | "prompt"
  | "translation"
  | "stream"
  | "remarkable"
  | "marine";
export type BufferPhase = "idle" | "loading" | "ready" | "protected" | "error";

export type BufferLanguage = {
  value: string;
  label: string;
};

export type BufferSurfaceProps = {
  mode?: BufferMode;
  defaultMode?: BufferMode;
  phase?: BufferPhase;
  defaultPhase?: BufferPhase;
  sourceText?: string;
  defaultSourceText?: string;
  targets?: readonly string[];
  defaultTargets?: readonly string[];
  selectedTarget?: number;
  defaultSelectedTarget?: number;
  sourceLanguage?: string;
  defaultSourceLanguage?: string;
  targetLanguage?: string;
  defaultTargetLanguage?: string;
  languages?: readonly BufferLanguage[];
  availablePluginIDs?: readonly string[];
  className?: string;
  onModeChange?: (mode: BufferMode) => void;
  onPhaseChange?: (phase: BufferPhase) => void;
  onSourceChange?: (text: string) => void;
  onTargetsChange?: (targets: readonly string[]) => void;
  onTargetSelect?: (index: number, target: string) => void;
  onLanguageChange?: (sourceLanguage: string, targetLanguage: string) => void;
  onGenerate?: (mode: BufferMode, sourceText: string) => void;
  onSend?: (text: string, mode: BufferMode) => void;
  onRefresh?: (mode: BufferMode) => void;
  onClose?: () => void;
};

type ModeDescriptor = {
  label: string;
  icon: IconName;
  sourceRole: string;
  sourceIcon: IconName;
  targetRole?: string;
  targetIcon?: IconName;
  action: string;
  loadingAction: string;
};

const MODE_ORDER: readonly BufferMode[] = [
  "normal",
  "ai",
  "prompt",
  "translation",
  "stream",
  "remarkable",
  "marine",
];

export const BUFFER_MODE_PLUGIN_IDS = {
  ai: "builtin.ai-text",
  prompt: "builtin.my-prompt",
  translation: "builtin.apple-translation",
  stream: "builtin.stream-input",
  remarkable: "builtin.remarkable",
  marine: "builtin.marine-chrome",
} as const satisfies Record<Exclude<BufferMode, "normal">, string>;

const pluginCatalog = new Map(initialPlugins.map((plugin) => [plugin.id, plugin]));
const translationPlugin = pluginCatalog.get("builtin.apple-translation");
const aiPlugin = pluginCatalog.get("builtin.ai-text");
const promptPlugin = pluginCatalog.get("builtin.my-prompt");
const streamPlugin = pluginCatalog.get("builtin.stream-input");
const remarkablePlugin = pluginCatalog.get("builtin.remarkable");
const marinePlugin = pluginCatalog.get("builtin.marine-chrome");

const MODE_DESCRIPTORS: Record<BufferMode, ModeDescriptor> = {
  normal: {
    label: "Default",
    icon: "grid",
    sourceRole: "文",
    sourceIcon: "textbox",
    action: "发送",
    loadingAction: "发送中…",
  },
  translation: {
    label: translationPlugin?.name ?? "实时翻译",
    icon: translationPlugin?.icon ?? "globe",
    sourceRole: "原",
    sourceIcon: "textbox",
    targetRole: "译",
    targetIcon: "globe",
    action: "重新翻译",
    loadingAction: "翻译中…",
  },
  ai: {
    label: aiPlugin?.name ?? "AI 生成",
    icon: aiPlugin?.icon ?? "sparkle",
    sourceRole: "原",
    sourceIcon: "textbox",
    targetRole: "答",
    targetIcon: "sparkle",
    action: "生成",
    loadingAction: "生成中…",
  },
  prompt: {
    label: promptPlugin?.name ?? "My Prompt",
    icon: promptPlugin?.icon ?? "fileSearch",
    sourceRole: "查",
    sourceIcon: "search",
    targetRole: "词",
    targetIcon: "fileSearch",
    action: "检索",
    loadingAction: "检索中…",
  },
  stream: {
    label: streamPlugin?.name ?? "意识流输入",
    icon: streamPlugin?.icon ?? "waveform",
    sourceRole: "拼",
    sourceIcon: "keyboard",
    targetRole: "文",
    targetIcon: "waveform",
    action: "推测",
    loadingAction: "推测中…",
  },
  remarkable: {
    label: remarkablePlugin?.name ?? "Remarkable",
    icon: remarkablePlugin?.icon ?? "eye",
    sourceRole: "页",
    sourceIcon: "eye",
    targetRole: "识",
    targetIcon: "textbox",
    action: "识别当前页",
    loadingAction: "识别中…",
  },
  marine: {
    label: marinePlugin?.name ?? "Marine Chrome",
    icon: marinePlugin?.icon ?? "network",
    sourceRole: "文",
    sourceIcon: "textbox",
    targetRole: "答",
    targetIcon: "sparkle",
    action: "提取并生成",
    loadingAction: "生成中…",
  },
};

const DEFAULT_LANGUAGES: readonly BufferLanguage[] = [
  { value: "zh-Hans", label: "简体中文" },
  { value: "zh-Hant", label: "繁体中文" },
  { value: "en", label: "英语" },
  { value: "ja", label: "日语" },
  { value: "ko", label: "韩语" },
  { value: "fr", label: "法语" },
  { value: "de", label: "德语" },
  { value: "es", label: "西班牙语" },
];

const DEFAULT_SOURCE = "请把这段缓冲内容整理为一段清晰的产品说明。";

function defaultTargetsFor(mode: BufferMode): readonly string[] {
  switch (mode) {
    case "normal":
      return [];
    case "translation":
      return ["Turn this buffered text into a clear product description."];
    case "ai":
      return ["这是一段结构清楚、可以直接发送的产品说明。"];
    case "prompt":
      return [
        "产品说明写作模板",
        "功能发布说明模板",
        "设计评审提示词",
      ];
    case "stream":
      return [
        "请把这段缓冲内容整理成清晰的产品说明。",
        "请将缓冲内容改写为简洁的产品介绍。",
        "把当前内容整理成一段易读的说明。",
      ];
    case "remarkable":
      return ["已在本机识别当前 reMarkable 页面，可检查后加入缓冲区。"];
    case "marine":
      return ["已根据当前页面和缓冲正文生成可发送的回复。"];
  }
}

function generatedTargetsFor(mode: BufferMode, source: string): readonly string[] {
  const conciseSource = source.trim() || "当前缓冲内容";
  switch (mode) {
    case "normal":
      return [];
    case "translation":
      return [`Translation: ${conciseSource}`];
    case "ai":
      return [`已根据“${conciseSource}”生成一段可直接发送的内容。`];
    case "prompt":
      return [
        `${conciseSource} · 产品说明模板`,
        `${conciseSource} · 设计评审提示词`,
        `${conciseSource} · 发布检查清单`,
      ];
    case "stream":
      return [
        `${conciseSource}`,
        `${conciseSource}，并保持表达简洁。`,
        `请整理：${conciseSource}`,
      ];
    case "remarkable":
      return [`已在 Mac 本地识别当前页：${conciseSource}`];
    case "marine":
      return [`已结合当前网页上下文处理：${conciseSource}`];
  }
}

function useControllableState<T>(
  value: T | undefined,
  initialValue: T,
  onChange?: (next: T) => void,
) {
  const [internalValue, setInternalValue] = useState(initialValue);
  const resolvedValue = value ?? internalValue;

  const setValue = (next: T) => {
    if (value === undefined) setInternalValue(next);
    onChange?.(next);
  };

  return [resolvedValue, setValue] as const;
}

function statusFor(mode: BufferMode, phase: BufferPhase, hasContent: boolean) {
  if (phase === "protected") return "安全输入，内容已隐藏";
  if (phase === "loading") {
    if (mode === "translation") return "正在翻译";
    if (mode === "prompt") return "正在检索提示词";
    if (mode === "stream") return "正在推测完整输入";
    if (mode === "remarkable") return "正在识别当前页";
    if (mode === "marine") return "正在读取网页上下文";
    return mode === "normal" ? "正在发送" : "插件正在生成";
  }
  if (phase === "error") return "处理失败";
  if (!hasContent) return "等待内容";
  return phase === "ready" ? "可发送" : "等待内容";
}

function BufferTrack({
  role,
  icon,
  kind,
  protectedContent,
  loading,
  sourceValue,
  targets,
  selectedTarget,
  onSourceChange,
  onTargetSelect,
}: {
  role: string;
  icon: IconName;
  kind: "source" | "target";
  protectedContent: boolean;
  loading: boolean;
  sourceValue?: string;
  targets?: readonly string[];
  selectedTarget?: number;
  onSourceChange?: (text: string) => void;
  onTargetSelect?: (index: number) => void;
}) {
  return (
    <div
      aria-label={`${kind === "source" ? "源" : "目标"}缓冲轨道`}
      className={`buffer-track buffer-track--${kind}${protectedContent ? " is-protected" : ""}`}
    >
      <span className="buffer-track__role" title={kind === "source" ? "源缓冲区" : "目标缓冲区"}>
        <Icon name={protectedContent ? "lock" : icon} size={13} weight="bold" />
        <span>{role}</span>
      </span>

      <div className="buffer-track__content">
        {protectedContent ? (
          <span className="buffer-track__protected-message">
            <Icon name="lock" size={13} />
            内容已隐藏
          </span>
        ) : kind === "source" ? (
          <input
            aria-label="缓冲正文"
            className="buffer-track__editor"
            onChange={(event) => onSourceChange?.(event.target.value)}
            placeholder="等待暂存内容"
            spellCheck={false}
            type="text"
            value={sourceValue ?? ""}
          />
        ) : loading ? (
          <span aria-live="polite" className="buffer-track__loading">
            <Icon className="is-spinning" name="refresh" size={13} />
            正在处理…
          </span>
        ) : targets && targets.length > 0 ? (
          <div className="buffer-track__target-list" role="listbox">
            {targets.map((target, index) => (
              <button
                aria-selected={selectedTarget === index}
                className={`buffer-target${selectedTarget === index ? " is-selected" : ""}`}
                key={`${target}-${index}`}
                onClick={() => onTargetSelect?.(index)}
                role="option"
                title={target}
                type="button"
              >
                <span className="buffer-target__index">
                  {selectedTarget === index ? "✓ " : ""}{index + 1} ·
                </span>
                <span className="buffer-target__text">{target}</span>
              </button>
            ))}
          </div>
        ) : (
          <span className="buffer-track__empty">等待译文</span>
        )}
      </div>
    </div>
  );
}

/**
 * Interactive visual mirror of the native Buffer workbench. This component
 * owns demo state when props are omitted, while every meaningful state can also
 * be controlled by a consuming prototype.
 */
export function BufferSurface({
  mode: controlledMode,
  defaultMode = "normal",
  phase: controlledPhase,
  defaultPhase = "ready",
  sourceText: controlledSourceText,
  defaultSourceText = DEFAULT_SOURCE,
  targets: controlledTargets,
  defaultTargets,
  selectedTarget: controlledSelectedTarget,
  defaultSelectedTarget = 0,
  sourceLanguage: controlledSourceLanguage,
  defaultSourceLanguage = "zh-Hans",
  targetLanguage: controlledTargetLanguage,
  defaultTargetLanguage = "en",
  languages = DEFAULT_LANGUAGES,
  availablePluginIDs,
  className = "",
  onModeChange,
  onPhaseChange,
  onSourceChange,
  onTargetsChange,
  onTargetSelect,
  onLanguageChange,
  onGenerate,
  onSend,
  onRefresh,
  onClose,
}: BufferSurfaceProps) {
  const initialMode = controlledMode ?? defaultMode;
  const [mode, setMode] = useControllableState(controlledMode, defaultMode, onModeChange);
  const [phase, setPhase] = useControllableState(controlledPhase, defaultPhase, onPhaseChange);
  const [sourceText, setSourceText] = useControllableState(
    controlledSourceText,
    defaultSourceText,
    onSourceChange,
  );
  const [targets, setTargets] = useControllableState<readonly string[]>(
    controlledTargets,
    defaultTargets ?? defaultTargetsFor(initialMode),
    onTargetsChange,
  );
  const [selectedTarget, setSelectedTarget] = useControllableState(
    controlledSelectedTarget,
    defaultSelectedTarget,
  );
  const [sourceLanguage, setSourceLanguage] = useControllableState(
    controlledSourceLanguage,
    defaultSourceLanguage,
  );
  const [targetLanguage, setTargetLanguage] = useControllableState(
    controlledTargetLanguage,
    defaultTargetLanguage,
  );
  const [deliveryNote, setDeliveryNote] = useState("");
  const generationTimer = useRef<number | undefined>(undefined);
  const generationRevision = useRef(0);

  const availableModes = useMemo<readonly BufferMode[]>(() => {
    if (availablePluginIDs === undefined) return MODE_ORDER;
    const availableIDs = new Set(availablePluginIDs);
    return MODE_ORDER.filter((candidateMode) => (
      candidateMode === "normal"
      || availableIDs.has(BUFFER_MODE_PLUGIN_IDS[candidateMode])
    ));
  }, [availablePluginIDs]);
  const availableModeSet = useMemo(() => new Set(availableModes), [availableModes]);
  const modeIsAvailable = availableModeSet.has(mode);
  const effectiveMode: BufferMode = modeIsAvailable ? mode : "normal";
  const descriptor = MODE_DESCRIPTORS[effectiveMode];
  const derived = effectiveMode !== "normal";
  const protectedContent = phase === "protected";
  const loading = phase === "loading";
  const selectedOutput = derived ? targets[selectedTarget] ?? "" : sourceText;
  const canSend = !protectedContent && !loading && selectedOutput.trim().length > 0;
  const status = deliveryNote || statusFor(effectiveMode, phase, sourceText.trim().length > 0);
  const generationContext = useRef({
    mode: effectiveMode,
    protectedContent,
    sourceText,
  });
  generationContext.current = {
    mode: effectiveMode,
    protectedContent,
    sourceText,
  };
  const languageOptions = useMemo(() => {
    const values = new Set(languages.map((language) => language.value));
    const additions: BufferLanguage[] = [];
    if (!values.has(sourceLanguage)) additions.push({ value: sourceLanguage, label: sourceLanguage });
    if (!values.has(targetLanguage)) additions.push({ value: targetLanguage, label: targetLanguage });
    return [...languages, ...additions];
  }, [languages, sourceLanguage, targetLanguage]);

  const cancelPendingGeneration = useCallback(() => {
    generationRevision.current += 1;
    if (generationTimer.current === undefined) return;
    window.clearTimeout(generationTimer.current);
    generationTimer.current = undefined;
  }, []);

  // Render the safe fallback immediately, then persist it through either the
  // uncontrolled state or the controlled owner's onModeChange callback.
  useEffect(() => {
    if (modeIsAvailable) return;
    cancelPendingGeneration();
    setDeliveryNote("");
    setSelectedTarget(0);
    setTargets([]);
    setMode("normal");
    if (!protectedContent) setPhase(sourceText.trim() ? "ready" : "idle");
  }, [cancelPendingGeneration, mode, modeIsAvailable]);

  // Controlled props can change without passing through this component's event
  // handlers. Invalidate on every generation input as a second line of defence
  // so a timer created for an older owner/source/privacy state cannot publish.
  useEffect(() => {
    cancelPendingGeneration();
  }, [cancelPendingGeneration, effectiveMode, protectedContent, sourceText]);

  useEffect(() => () => {
    cancelPendingGeneration();
  }, [cancelPendingGeneration]);

  useEffect(() => {
    if (targets.length === 0) return;
    if (selectedTarget >= targets.length) setSelectedTarget(0);
  }, [selectedTarget, setSelectedTarget, targets.length]);

  const changeMode = (event: ChangeEvent<HTMLSelectElement>) => {
    const nextMode = event.target.value as BufferMode;
    if (!availableModeSet.has(nextMode)) return;
    cancelPendingGeneration();
    setMode(nextMode);
    setDeliveryNote("");
    setSelectedTarget(0);
    setTargets(defaultTargetsFor(nextMode));
    if (phase !== "protected") setPhase("ready");
  };

  const changeSourceLanguage = (event: ChangeEvent<HTMLSelectElement>) => {
    const next = event.target.value;
    cancelPendingGeneration();
    setSourceLanguage(next);
    if (!protectedContent && effectiveMode === "translation") {
      setTargets([]);
      setPhase("idle");
    }
    onLanguageChange?.(next, targetLanguage);
  };

  const changeTargetLanguage = (event: ChangeEvent<HTMLSelectElement>) => {
    const next = event.target.value;
    cancelPendingGeneration();
    setTargetLanguage(next);
    if (!protectedContent && effectiveMode === "translation") {
      setTargets([]);
      setPhase("idle");
    }
    onLanguageChange?.(sourceLanguage, next);
  };

  const swapLanguages = () => {
    const nextSource = targetLanguage;
    const nextTarget = sourceLanguage;
    cancelPendingGeneration();
    setSourceLanguage(nextSource);
    setTargetLanguage(nextTarget);
    if (!protectedContent && effectiveMode === "translation") {
      setTargets([]);
      setPhase("idle");
    }
    onLanguageChange?.(nextSource, nextTarget);
  };

  const generate = () => {
    if (protectedContent || loading || effectiveMode === "normal") return;
    cancelPendingGeneration();
    const requestRevision = generationRevision.current;
    const requestMode = effectiveMode;
    const requestSource = sourceText;
    setDeliveryNote("");
    setPhase("loading");
    onGenerate?.(requestMode, requestSource);

    // In uncontrolled demos, finish automatically so every phase is explorable.
    if (controlledPhase === undefined) {
      const timerID = window.setTimeout(() => {
        if (generationTimer.current === timerID) generationTimer.current = undefined;
        const currentContext = generationContext.current;
        if (
          generationRevision.current !== requestRevision
          || currentContext.mode !== requestMode
          || currentContext.sourceText !== requestSource
          || currentContext.protectedContent
        ) return;
        const nextTargets = generatedTargetsFor(requestMode, requestSource);
        setTargets(nextTargets);
        setSelectedTarget(0);
        setPhase("ready");
      }, 700);
      generationTimer.current = timerID;
    }
  };

  const refresh = () => {
    cancelPendingGeneration();
    setDeliveryNote("");
    if (effectiveMode !== "normal") setTargets([]);
    if (phase !== "protected") setPhase("idle");
    onRefresh?.(effectiveMode);
  };

  const toggleProtection = () => {
    cancelPendingGeneration();
    const nextPhase: BufferPhase = protectedContent
      ? (sourceText.trim() || targets.length > 0 ? "ready" : "idle")
      : "protected";
    setDeliveryNote("");
    setPhase(nextPhase);
  };

  const selectTarget = (index: number) => {
    const target = targets[index];
    if (target === undefined) return;
    setSelectedTarget(index);
    onTargetSelect?.(index, target);
  };

  const send = () => {
    if (!canSend) return;
    setDeliveryNote("已发送");
    onSend?.(selectedOutput, effectiveMode);
  };

  const primaryAction = derived && (phase === "idle" || phase === "error")
    ? generate
    : send;
  const primaryLabel = derived && (phase === "idle" || phase === "error")
    ? descriptor.action
    : loading
      ? descriptor.loadingAction
      : "发送";
  const primaryIcon: IconName = loading
    ? "refresh"
    : derived && (phase === "idle" || phase === "error")
      ? descriptor.icon
      : "send";

  return (
    <section
      aria-label="缓冲工作台"
      className={`buffer-surface buffer-surface--${effectiveMode}${className ? ` ${className}` : ""}`}
      data-mode={effectiveMode}
      data-phase={phase}
    >
      <header className="buffer-toolbar">
        <span aria-live="polite" className={`buffer-toolbar__status buffer-status--${phase}`}>
          {protectedContent ? <Icon name="lock" size={13} weight="bold" /> : null}
          {status}
        </span>

        <label className="buffer-toolbar__plugin-select">
          <Icon name={descriptor.icon} size={14} weight="bold" />
          <span className="sr-only">工作台插件</span>
          <select aria-label="工作台插件" onChange={changeMode} value={effectiveMode}>
            {availableModes.map((pluginMode) => (
              <option key={pluginMode} value={pluginMode}>
                {MODE_DESCRIPTORS[pluginMode].label}
              </option>
            ))}
          </select>
        </label>

        {effectiveMode === "translation" ? (
          <div aria-label="翻译语言" className="buffer-toolbar__translation-controls" role="group">
            <select
              aria-label="源语言"
              disabled={protectedContent || loading}
              onChange={changeSourceLanguage}
              value={sourceLanguage}
            >
              {languageOptions.map((language) => (
                <option key={`source-${language.value}`} value={language.value}>{language.label}</option>
              ))}
            </select>
            <IconButton
              disabled={protectedContent || loading}
              icon="swap"
              label="交换源语言和目标语言"
              onClick={swapLanguages}
            />
            <select
              aria-label="目标语言"
              disabled={protectedContent || loading}
              onChange={changeTargetLanguage}
              value={targetLanguage}
            >
              {languageOptions.map((language) => (
                <option key={`target-${language.value}`} value={language.value}>{language.label}</option>
              ))}
            </select>
          </div>
        ) : null}

        {derived ? (
          <Button
            disabled={protectedContent || loading || !sourceText.trim()}
            icon={descriptor.icon}
            kind="ghost"
            onClick={generate}
          >
            {loading ? descriptor.loadingAction : descriptor.action}
          </Button>
        ) : null}

        <span className="buffer-toolbar__spacer" />
        <IconButton
          icon="lock"
          label={protectedContent ? "关闭安全输入预览" : "模拟安全输入"}
          onClick={toggleProtection}
          selected={protectedContent}
        />
        <IconButton icon="refresh" label="刷新或重置当前插件（保留缓冲正文）" onClick={refresh} />
        <IconButton icon="close" label="关闭并暂停缓冲（保留内容）" onClick={onClose} />
      </header>

      <div className={`buffer-workbench${derived ? " buffer-workbench--derived" : ""}`}>
        <div className="buffer-workbench__rails">
          <BufferTrack
            icon={descriptor.sourceIcon}
            kind="source"
            loading={false}
            onSourceChange={(text) => {
              cancelPendingGeneration();
              setDeliveryNote("");
              setSourceText(text);
              if (!protectedContent && derived) {
                setTargets([]);
                setPhase("idle");
              }
            }}
            protectedContent={protectedContent}
            role={descriptor.sourceRole}
            sourceValue={sourceText}
          />
          {derived ? (
            <BufferTrack
              icon={descriptor.targetIcon ?? "sparkle"}
              kind="target"
              loading={loading}
              onTargetSelect={selectTarget}
              protectedContent={protectedContent}
              role={descriptor.targetRole ?? "答"}
              selectedTarget={selectedTarget}
              targets={targets}
            />
          ) : null}
        </div>

        <Button
          disabled={protectedContent || loading || (primaryAction === send && !canSend) || (!sourceText.trim() && primaryAction === generate)}
          icon={primaryIcon}
          kind="primary"
          onClick={primaryAction}
        >
          {primaryLabel}
        </Button>
      </div>
    </section>
  );
}
