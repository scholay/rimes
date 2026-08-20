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

function defaultTargetsFor(_mode: BufferMode): readonly string[] {
  // All plugins open on the writing rail. Live-expand fills the lower rail
  // after typed content arrives; exchange plugins swap this rail after request.
  return [];
}

function bufferLayoutFor(mode: BufferMode): "single-exchange" | "live-expand" {
  // Live retrieval / parallel drafting: grow a lower rail while typing.
  return mode === "translation" || mode === "stream" || mode === "prompt"
    ? "live-expand"
    : "single-exchange";
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
        `${conciseSource} · 用户调研提纲`,
        `${conciseSource} · 竞品对比框架`,
      ];
    case "stream":
      return [
        `${conciseSource}`,
        `${conciseSource}，并保持表达简洁。`,
        `请整理：${conciseSource}`,
        `把“${conciseSource}”改成可直接发送的说明。`,
        `基于“${conciseSource}”给出更口语的版本。`,
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

/** Only surface status when it changes what the user should do next.
 *  Idle "可发送" / "等待内容" is redundant with the send button and rails. */
function statusFor(mode: BufferMode, phase: BufferPhase, _hasContent: boolean): string | null {
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
  return null;
}

function BufferTrack({
  role,
  icon,
  kind,
  protectedContent,
  loading,
  sourceValue,
  targets,
  selectedTarget = 0,
  emptyLabel,
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
  emptyLabel?: string;
  onSourceChange?: (text: string) => void;
  onTargetSelect?: (index: number) => void;
}) {
  const targetCount = targets?.length ?? 0;
  const activeIndex = targetCount === 0
    ? 0
    : Math.min(Math.max(selectedTarget, 0), targetCount - 1);
  const activeTarget = targetCount > 0 ? targets![activeIndex] : "";

  const stepTarget = (delta: number) => {
    if (targetCount <= 1) return;
    const next = (activeIndex + delta + targetCount) % targetCount;
    onTargetSelect?.(next);
  };

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
        ) : targetCount > 0 ? (
          <div
            aria-label={`候选 ${activeIndex + 1} / ${targetCount}`}
            className="buffer-track__pager"
            role="group"
          >
            <span className="buffer-track__pager-stepper">
              <span className="buffer-track__pager-count" title={`${targetCount} 条候选`}>
                {activeIndex + 1}/{targetCount}
              </span>
              {targetCount > 1 ? (
                <span className="buffer-track__pager-controls">
                  <button
                    aria-label="上一条候选"
                    className="buffer-track__pager-button"
                    onClick={() => stepTarget(-1)}
                    type="button"
                  >
                    <Icon name="up" size={11} weight="bold" />
                  </button>
                  <button
                    aria-label="下一条候选"
                    className="buffer-track__pager-button"
                    onClick={() => stepTarget(1)}
                    type="button"
                  >
                    <Icon name="down" size={11} weight="bold" />
                  </button>
                </span>
              ) : null}
            </span>
            <span className="buffer-track__pager-text" title={activeTarget}>
              {activeTarget}
            </span>
          </div>
        ) : (
          <span className="buffer-track__empty">{emptyLabel ?? "等待结果"}</span>
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
  const layout = bufferLayoutFor(effectiveMode);
  const liveExpand = layout === "live-expand";
  const exchange = layout === "single-exchange" && effectiveMode !== "normal";
  const protectedContent = phase === "protected";
  const loading = phase === "loading";
  const hasSource = sourceText.trim().length > 0;
  const showLiveTargetRail = liveExpand && !protectedContent && hasSource;
  // Exchange plugins keep one rail: write first, then swap to waiting/results.
  const exchangeDecision = exchange && !protectedContent && (loading || targets.length > 0);
  const selectedOutput = (liveExpand || exchangeDecision)
    ? targets[selectedTarget] ?? ""
    : sourceText;
  const canSend = !protectedContent && !loading && selectedOutput.trim().length > 0;
  const canRequest = !protectedContent && !loading && (
    effectiveMode === "remarkable"
    || effectiveMode === "marine"
    || hasSource
  );
  const status = deliveryNote || statusFor(effectiveMode, phase, hasSource);
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

  const runGeneration = useCallback((requestMode: BufferMode, requestSource: string) => {
    if (protectedContent) return;
    cancelPendingGeneration();
    const requestRevision = generationRevision.current;
    setDeliveryNote("");
    setPhase("loading");
    onGenerate?.(requestMode, requestSource);

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
      }, liveExpand ? 420 : 700);
      generationTimer.current = timerID;
    }
  }, [
    cancelPendingGeneration,
    controlledPhase,
    liveExpand,
    onGenerate,
    protectedContent,
    setPhase,
    setSelectedTarget,
    setTargets,
  ]);

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

  useEffect(() => {
    cancelPendingGeneration();
  }, [cancelPendingGeneration, effectiveMode, protectedContent]);

  // Live-expand plugins grow a lower rail as soon as the user has typed something.
  useEffect(() => {
    if (!liveExpand || protectedContent) return;
    if (!hasSource) {
      cancelPendingGeneration();
      setTargets([]);
      if (phase !== "idle") setPhase("idle");
      return;
    }
    if (controlledPhase !== undefined) return;
    const requestMode = effectiveMode;
    const requestSource = sourceText;
    cancelPendingGeneration();
    const requestRevision = generationRevision.current;
    setPhase("loading");
    onGenerate?.(requestMode, requestSource);
    const timerID = window.setTimeout(() => {
      if (generationTimer.current === timerID) generationTimer.current = undefined;
      const currentContext = generationContext.current;
      if (
        generationRevision.current !== requestRevision
        || currentContext.mode !== requestMode
        || currentContext.sourceText !== requestSource
        || currentContext.protectedContent
      ) return;
      setTargets(generatedTargetsFor(requestMode, requestSource));
      setSelectedTarget(0);
      setPhase("ready");
    }, 420);
    generationTimer.current = timerID;
  }, [
    cancelPendingGeneration,
    controlledPhase,
    effectiveMode,
    hasSource,
    liveExpand,
    onGenerate,
    protectedContent,
    sourceLanguage,
    sourceText,
    targetLanguage,
  ]);

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
    setTargets([]);
    if (phase !== "protected") setPhase(sourceText.trim() ? "ready" : "idle");
  };

  const changeSourceLanguage = (event: ChangeEvent<HTMLSelectElement>) => {
    const next = event.target.value;
    cancelPendingGeneration();
    setSourceLanguage(next);
    if (!protectedContent && liveExpand) {
      setTargets([]);
      setPhase(hasSource ? "ready" : "idle");
    }
    onLanguageChange?.(next, targetLanguage);
  };

  const changeTargetLanguage = (event: ChangeEvent<HTMLSelectElement>) => {
    const next = event.target.value;
    cancelPendingGeneration();
    setTargetLanguage(next);
    if (!protectedContent && liveExpand) {
      setTargets([]);
      setPhase(hasSource ? "ready" : "idle");
    }
    onLanguageChange?.(sourceLanguage, next);
  };

  const swapLanguages = () => {
    const nextSource = targetLanguage;
    const nextTarget = sourceLanguage;
    cancelPendingGeneration();
    setSourceLanguage(nextSource);
    setTargetLanguage(nextTarget);
    if (!protectedContent && liveExpand) {
      setTargets([]);
      setPhase(hasSource ? "ready" : "idle");
    }
    onLanguageChange?.(nextSource, nextTarget);
  };

  const generate = () => {
    if (!canRequest || effectiveMode === "normal" || liveExpand) return;
    runGeneration(effectiveMode, sourceText);
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
    if (exchange) {
      setTargets([]);
      setPhase(hasSource ? "ready" : "idle");
    }
  };

  const awaitingExchangeRequest = exchange && !exchangeDecision;
  const primaryAction = awaitingExchangeRequest ? generate : send;
  const primaryLabel = loading
    ? descriptor.loadingAction
    : awaitingExchangeRequest
      ? descriptor.action
      : "发送";
  const primaryIcon: IconName = loading
    ? "refresh"
    : awaitingExchangeRequest
      ? descriptor.icon
      : "send";

  const onSourceEdit = (text: string) => {
    cancelPendingGeneration();
    setDeliveryNote("");
    setSourceText(text);
    if (!protectedContent && exchange && targets.length > 0) {
      // Editing source abandons the previous decision set and returns to writing.
      setTargets([]);
    }
    if (!protectedContent && phase !== "loading") {
      setPhase(text.trim() ? "ready" : "idle");
    }
  };

  const workbenchClass = [
    "buffer-workbench",
    showLiveTargetRail ? "buffer-workbench--live-expand" : "",
    exchangeDecision ? "buffer-workbench--exchange-decision" : "",
  ].filter(Boolean).join(" ");

  return (
    <section
      aria-label="缓冲工作台"
      className={`buffer-surface buffer-surface--${effectiveMode}${className ? ` ${className}` : ""}`}
      data-layout={layout}
      data-mode={effectiveMode}
      data-phase={phase}
    >
      <header className="buffer-toolbar">
        {status ? (
          <span aria-live="polite" className={`buffer-toolbar__status buffer-status--${phase}`}>
            {protectedContent ? <Icon name="lock" size={13} weight="bold" /> : null}
            {status}
          </span>
        ) : null}

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

        <span className="buffer-toolbar__spacer" />
        <IconButton icon="close" label="关闭并暂停缓冲（保留内容）" onClick={onClose} />
      </header>

      <div className={workbenchClass}>
        <div className="buffer-workbench__rails">
          {exchangeDecision ? (
            <BufferTrack
              emptyLabel="等待返回结果"
              icon={descriptor.targetIcon ?? "sparkle"}
              kind="target"
              loading={loading}
              onTargetSelect={selectTarget}
              protectedContent={protectedContent}
              role={descriptor.targetRole ?? "答"}
              selectedTarget={selectedTarget}
              targets={targets}
            />
          ) : (
            <BufferTrack
              icon={descriptor.sourceIcon}
              kind="source"
              loading={false}
              onSourceChange={onSourceEdit}
              protectedContent={protectedContent}
              role={descriptor.sourceRole}
              sourceValue={sourceText}
            />
          )}
          {showLiveTargetRail ? (
            <BufferTrack
              emptyLabel={
                effectiveMode === "stream"
                  ? "等待推测结果"
                  : effectiveMode === "prompt"
                    ? "等待检索结果"
                    : "等待译文"
              }
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
          disabled={
            protectedContent
            || loading
            || (primaryAction === send && !canSend)
            || (primaryAction === generate && !canRequest)
          }
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
