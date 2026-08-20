import {
  useEffect,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent,
  type PropsWithChildren,
  type ReactNode,
  type WheelEvent,
} from "react";
import { Icon, type IconName } from "../design-system/Icon";
import {
  Badge,
  Button,
  IconButton,
  Segmented,
  SelectButton,
} from "../design-system/primitives";

export type ClipboardLayoutMode = "single" | "dual";
export type ClipboardActivationMode = "target" | "browse" | "protected";
export type ClipboardActivationDestination = "buffer" | "target" | "pasteboard";

export type ClipboardSurfaceItem = {
  id: string;
  text: string;
};

export type ClipboardSurfaceFeedback = {
  destination?: ClipboardActivationDestination;
  itemID?: string;
  message: string;
  tone: "neutral" | "accent" | "warning";
};

export type ClipboardSurfaceProps = {
  className?: string;
  initialActivationMode?: ClipboardActivationMode;
  initialItems?: readonly ClipboardSurfaceItem[];
  initialLayout?: ClipboardLayoutMode;
  initialRailActive?: boolean;
  initialSelectedID?: string;
  showControls?: boolean;
  onActivate?: (
    item: ClipboardSurfaceItem,
    destination: ClipboardActivationDestination,
  ) => void;
  onFeedback?: (feedback: ClipboardSurfaceFeedback) => void;
  onItemsChange?: (items: ClipboardSurfaceItem[]) => void;
};

export type WorkbenchShellProps = PropsWithChildren<{
  className?: string;
  clipboardSection?: ReactNode;
  contextIndicators?: ReactNode;
  controls?: ReactNode;
  onClose?: () => void;
  onRefresh?: () => void;
  status: string;
  statusDetail?: string;
}>;

const sampleClipboardItems: ClipboardSurfaceItem[] = [
  {
    id: "clipboard-design-tokens",
    text: "候选框和缓冲工作台要共享同一套设计令牌。",
  },
  {
    id: "clipboard-build-command",
    text: "npm run build && npm run test:sites",
  },
  {
    id: "clipboard-theme-note",
    text: "墨竹、翡翠与静谧都必须保持清晰对比度。",
  },
  {
    id: "clipboard-release-link",
    text: "https://github.com/young-bo-i/rime-buffer/releases/latest",
  },
];

const sampleBufferBlocks = ["这是一段待发送内容", "在上方保留 Buffer 的当前状态"];

const layoutOptions = [
  { value: "single", label: "单栏" },
  { value: "dual", label: "双栏" },
] as const;

const activationOptions = [
  { value: "target", label: "输入目标" },
  { value: "browse", label: "浏览" },
  { value: "protected", label: "保护" },
] as const;

const activityOptions = [
  { value: "active", label: "Active" },
  { value: "passive", label: "Selected" },
] as const;

function copyItems(items: readonly ClipboardSurfaceItem[]) {
  return items.map((item) => ({ ...item }));
}

function boundedPreview(text: string, maximumCharacters = 160) {
  const normalized = text.replace(/[\r\n\t]+/g, " ");
  return normalized.length > maximumCharacters
    ? `${normalized.slice(0, maximumCharacters)}…`
    : normalized;
}

/**
 * Shared nonactivating-workbench chrome for the Buffer and Clipboard previews.
 * The caller supplies one or both content sections; controls stay in one fixed
 * utility shelf so section state never creates a second window metaphor.
 */
export function WorkbenchShell({
  children,
  className = "",
  clipboardSection,
  contextIndicators,
  controls,
  onClose,
  onRefresh,
  status,
  statusDetail,
}: WorkbenchShellProps) {
  const hasBufferSection = children !== null && children !== undefined;
  const hasClipboardSection = clipboardSection !== null && clipboardSection !== undefined;

  return (
    <section
      aria-label="RIMES 共享工作台"
      className={`workbench-shell ${className}`.trim()}
      data-sections={hasBufferSection && hasClipboardSection ? "dual" : "single"}
    >
      <header className="workbench-shell__shelf">
        <output className="workbench-shell__status" title={statusDetail}>
          {status}
        </output>
        {hasBufferSection ? (
          <div className="workbench-shell__controls">{controls}</div>
        ) : null}
        <span aria-hidden="true" className="workbench-shell__drag-space" />
        {hasBufferSection ? (
          <div className="workbench-shell__indicators">{contextIndicators}</div>
        ) : null}
        {hasBufferSection && onRefresh ? (
          <IconButton icon="refresh" label="刷新当前 Buffer" onClick={onRefresh} />
        ) : null}
        <IconButton icon="close" label="关闭当前区域" onClick={onClose} />
      </header>

      <div aria-hidden="true" className="workbench-shell__divider" />
      <div className="workbench-shell__sections">
        {hasBufferSection ? (
          <div className="workbench-shell__section workbench-shell__section--buffer">
            {children}
          </div>
        ) : null}
        {hasBufferSection && hasClipboardSection ? (
          <div aria-hidden="true" className="workbench-shell__divider" />
        ) : null}
        {hasClipboardSection ? (
          <div className="workbench-shell__section workbench-shell__section--clipboard">
            {clipboardSection}
          </div>
        ) : null}
      </div>
    </section>
  );
}

function BufferPreviewRail({
  blocks,
  onSend,
}: {
  blocks: readonly string[];
  onSend: () => void;
}) {
  return (
    <div aria-label="Buffer 内容预览" className="buffer-preview-rail">
      <Icon name="tray" size={14} weight="bold" />
      <div className="buffer-preview-rail__blocks">
        {blocks.map((block, index) => (
          <span className="buffer-preview-rail__chip" key={`${block}-${index}`}>
            {block}
          </span>
        ))}
      </div>
      <IconButton
        disabled={blocks.length === 0}
        icon="send"
        label="发送下一块"
        onClick={onSend}
      />
    </div>
  );
}

function ClipboardStateMessage({
  icon,
  children,
}: PropsWithChildren<{ icon: IconName }>) {
  return (
    <div className="clipboard-rail__state" role="status">
      <Icon name={icon} size={14} weight="bold" />
      <span>{children}</span>
    </div>
  );
}

function ClipboardRail({
  active,
  items,
  protectedContent,
  selectedID,
  onActivate,
  onSelect,
  onRequestActive,
}: {
  active: boolean;
  items: readonly ClipboardSurfaceItem[];
  protectedContent: boolean;
  selectedID?: string;
  onActivate: (id: string) => void;
  onRequestActive: () => void;
  onSelect: (id: string) => void;
}) {
  const rowRef = useRef<HTMLDivElement>(null);
  const cardRefs = useRef(new Map<string, HTMLButtonElement>());

  useEffect(() => {
    if (!selectedID) return;
    const row = rowRef.current;
    const card = cardRefs.current.get(selectedID);
    if (!row || !card) return;

    const cardLeft = card.offsetLeft;
    const cardRight = cardLeft + card.offsetWidth;
    const visibleLeft = row.scrollLeft;
    const visibleRight = visibleLeft + row.clientWidth;
    if (card.offsetWidth >= row.clientWidth || cardLeft < visibleLeft) {
      row.scrollTo({ left: cardLeft, behavior: "smooth" });
    } else if (cardRight > visibleRight) {
      row.scrollTo({ left: cardRight - row.clientWidth, behavior: "smooth" });
    }
  }, [items, selectedID]);

  function translateShiftWheel(event: WheelEvent<HTMLDivElement>) {
    if (!event.shiftKey || Math.abs(event.deltaX) > 0.01 || Math.abs(event.deltaY) < 0.01) {
      return;
    }
    event.preventDefault();
    event.currentTarget.scrollLeft += event.deltaY;
  }

  return (
    <div
      aria-label="剪贴板历史卡片"
      aria-orientation="horizontal"
      className={`clipboard-rail${active ? " is-active" : ""}${protectedContent ? " is-protected" : ""}`}
      data-state={protectedContent ? "protected" : active ? "active" : "selected"}
      onFocus={protectedContent ? undefined : onRequestActive}
      role="listbox"
    >
      {protectedContent ? (
        <ClipboardStateMessage icon="lock">安全输入期间剪贴板历史已遮蔽</ClipboardStateMessage>
      ) : items.length === 0 ? (
        <ClipboardStateMessage icon="clipboard">剪贴板历史为空</ClipboardStateMessage>
      ) : (
        <div className="clipboard-rail__scroller" onWheel={translateShiftWheel} ref={rowRef}>
          {items.map((item) => {
            const selected = item.id === selectedID;
            return (
              <button
                aria-label={boundedPreview(item.text, 512)}
                aria-selected={selected}
                className={`clipboard-card${selected ? " is-selected" : ""}`}
                data-active={active || undefined}
                key={item.id}
                onClick={() => onSelect(item.id)}
                onDoubleClick={() => onActivate(item.id)}
                ref={(node) => {
                  if (node) cardRefs.current.set(item.id, node);
                  else cardRefs.current.delete(item.id);
                }}
                role="option"
                title={`${boundedPreview(item.text, 512)}\n${selected ? "已选择；双击激活" : "单击选择；双击激活"}`}
                type="button"
              >
                {boundedPreview(item.text)}
              </button>
            );
          })}
        </div>
      )}
    </div>
  );
}

export function ClipboardSurface({
  className = "",
  initialActivationMode = "target",
  initialItems = sampleClipboardItems,
  initialLayout = "dual",
  initialRailActive = true,
  initialSelectedID,
  onActivate,
  onFeedback,
  onItemsChange,
  showControls = true,
}: ClipboardSurfaceProps) {
  const initialItemSnapshot = useMemo(() => copyItems(initialItems), [initialItems]);
  const [items, setItems] = useState<ClipboardSurfaceItem[]>(initialItemSnapshot);
  const [layout, setLayout] = useState<ClipboardLayoutMode>(initialLayout);
  const [activationMode, setActivationMode] =
    useState<ClipboardActivationMode>(initialActivationMode);
  const [railActive, setRailActive] = useState(initialRailActive);
  const [clipboardVisible, setClipboardVisible] = useState(true);
  const [selectedID, setSelectedID] = useState<string | undefined>(() => {
    if (initialSelectedID && initialItemSnapshot.some((item) => item.id === initialSelectedID)) {
      return initialSelectedID;
    }
    return initialItemSnapshot[0]?.id;
  });
  const [bufferBlocks, setBufferBlocks] = useState<string[]>(sampleBufferBlocks);
  const [feedback, setFeedback] = useState<ClipboardSurfaceFeedback | undefined>();

  const protectedContent = activationMode === "protected";
  const bufferVisible = layout === "dual";
  const selectedIndex = items.findIndex((item) => item.id === selectedID);
  const selectedItem = selectedIndex >= 0 ? items[selectedIndex] : undefined;

  useEffect(() => {
    if (selectedID && items.some((item) => item.id === selectedID)) return;
    setSelectedID(items[0]?.id);
  }, [items, selectedID]);

  function publishFeedback(next: ClipboardSurfaceFeedback) {
    setFeedback(next);
    onFeedback?.(next);
  }

  function publishItems(next: ClipboardSurfaceItem[]) {
    setItems(next);
    onItemsChange?.(next);
  }

  function promote(item: ClipboardSurfaceItem) {
    publishItems([item, ...items.filter((candidate) => candidate.id !== item.id)]);
    setSelectedID(item.id);
  }

  function activationDestination(): ClipboardActivationDestination | undefined {
    if (!clipboardVisible || protectedContent) return undefined;
    if (bufferVisible) return "buffer";
    return activationMode === "browse" ? "pasteboard" : "target";
  }

  function activateItem(id = selectedID) {
    const item = items.find((candidate) => candidate.id === id);
    if (!item) {
      publishFeedback({ message: "没有可激活的剪贴板条目", tone: "warning" });
      return;
    }
    setSelectedID(item.id);

    const destination = activationDestination();
    if (!destination) {
      publishFeedback({
        itemID: item.id,
        message: "当前输入目标不可验证",
        tone: "warning",
      });
      return;
    }

    if (destination === "buffer") {
      setBufferBlocks((current) => [...current, item.text]);
      promote(item);
      const next = {
        destination,
        itemID: item.id,
        message: "已加入缓冲区",
        tone: "accent" as const,
      };
      publishFeedback(next);
      onActivate?.(item, destination);
      return;
    }

    promote(item);
    const next = destination === "target"
      ? {
          destination,
          itemID: item.id,
          message: "已输入",
          tone: "accent" as const,
        }
      : {
          destination,
          itemID: item.id,
          message: "已置顶，可按 ⌘V 粘贴",
          tone: "accent" as const,
        };
    publishFeedback(next);
    onActivate?.(item, destination);
  }

  function deleteSelected() {
    if (protectedContent || selectedIndex < 0) {
      publishFeedback({ message: "当前没有可删除的条目", tone: "warning" });
      return;
    }
    const removed = items[selectedIndex];
    const next = items.filter((item) => item.id !== removed.id);
    const neighbor = next[selectedIndex] ?? next[next.length - 1];
    publishItems(next);
    setSelectedID(neighbor?.id);
    publishFeedback({
      itemID: removed.id,
      message: "已删除",
      tone: "neutral",
    });
  }

  function moveSelection(delta: -1 | 1) {
    if (protectedContent || items.length === 0) return;
    const current = selectedIndex < 0 ? 0 : selectedIndex;
    const nextIndex = Math.min(items.length - 1, Math.max(0, current + delta));
    setSelectedID(items[nextIndex].id);
    setRailActive(true);
  }

  function handleRailKeyboard(event: KeyboardEvent<HTMLDivElement>) {
    if (!clipboardVisible || protectedContent) return;
    switch (event.key) {
      case "ArrowLeft":
        event.preventDefault();
        moveSelection(-1);
        break;
      case "ArrowRight":
        event.preventDefault();
        moveSelection(1);
        break;
      case "Enter":
        event.preventDefault();
        activateItem();
        break;
      case "Backspace":
      case "Delete":
        event.preventDefault();
        deleteSelected();
        break;
      default:
        break;
    }
  }

  function resetItems() {
    const next = copyItems(initialItemSnapshot);
    publishItems(next);
    setSelectedID(next[0]?.id);
    setClipboardVisible(true);
    setFeedback(undefined);
  }

  function statusText() {
    if (protectedContent) return "安全输入已开启";
    if (!clipboardVisible) {
      return bufferVisible
        ? `Buffer · Clipboard 已隐藏 · ${items.length} 项保留`
        : `Clipboard 已隐藏 · ${items.length} 项保留`;
    }
    if (feedback) return feedback.message;
    if (bufferVisible) return `双栏 · ${items.length} 项`;
    return `剪贴板 · ${items.length} 项`;
  }

  function activationButton() {
    const destination = activationDestination();
    const configuration = !clipboardVisible
      ? { icon: "eye" as const, label: "Clipboard 已隐藏" }
      : destination === "buffer"
      ? { icon: "plus" as const, label: "加入 Buffer" }
      : destination === "target"
        ? { icon: "send" as const, label: "直接输入" }
        : destination === "pasteboard"
          ? { icon: "pin" as const, label: "置顶" }
          : { icon: "lock" as const, label: "目标不可验证" };

    return (
      <Button
        disabled={!selectedItem || !destination}
        icon={configuration.icon}
        kind="primary"
        onClick={() => activateItem()}
      >
        {configuration.label}
      </Button>
    );
  }

  const clipboardRail = clipboardVisible
    ? (
        <div
          className="clipboard-surface__keyboard-zone"
          onKeyDown={handleRailKeyboard}
          tabIndex={protectedContent ? -1 : 0}
        >
          <ClipboardRail
            active={railActive && !protectedContent}
            items={protectedContent ? [] : items}
            onActivate={activateItem}
            onRequestActive={() => setRailActive(true)}
            onSelect={(id) => {
              setSelectedID(id);
              setRailActive(true);
            }}
            protectedContent={protectedContent}
            selectedID={selectedID}
          />
        </div>
      )
    : !bufferVisible
      ? (
          <ClipboardStateMessage icon={protectedContent ? "lock" : "eye"}>
            {protectedContent
              ? "安全输入预览中，剪贴板区保持隐藏"
              : `剪贴板区已隐藏，${items.length} 项内容仍保留`}
          </ClipboardStateMessage>
        )
      : null;

  return (
    <section className={`clipboard-surface ${className}`.trim()}>
      {showControls ? (
        <header className="clipboard-surface__controls">
          <div className="clipboard-surface__control-group">
            <span className="clipboard-surface__control-label">工作台</span>
            <Segmented
              ariaLabel="剪贴板工作台布局"
              onChange={(value) => {
                setLayout(value);
                setClipboardVisible(true);
              }}
              options={layoutOptions}
              value={layout}
            />
          </div>
          <div className="clipboard-surface__control-group">
            <span className="clipboard-surface__control-label">打开权限</span>
            <Segmented
              ariaLabel="剪贴板激活权限"
              onChange={(value) => {
                setActivationMode(value);
                setClipboardVisible(true);
                setFeedback(undefined);
              }}
              options={activationOptions}
              value={activationMode}
            />
          </div>
          <div className="clipboard-surface__control-group">
            <span className="clipboard-surface__control-label">键盘所有权</span>
            <Segmented
              ariaLabel="剪贴板 rail 活跃状态"
              onChange={(value) => setRailActive(value === "active")}
              options={activityOptions}
              value={railActive ? "active" : "passive"}
            />
          </div>
          <div className="clipboard-surface__control-actions">
            {activationButton()}
            <Button icon="trash" kind="danger" onClick={deleteSelected}>
              删除
            </Button>
            <Button
              icon={clipboardVisible ? "close" : "eye"}
              kind="secondary"
              onClick={() => setClipboardVisible((visible) => !visible)}
            >
              {clipboardVisible ? "隐藏 Clipboard" : "显示 Clipboard"}
            </Button>
          </div>
        </header>
      ) : null}

      <div className="clipboard-surface__stage">
        <WorkbenchShell
          clipboardSection={clipboardRail}
          contextIndicators={feedback ? <Badge tone={feedback.tone}>{feedback.message}</Badge> : null}
          controls={(
            <>
              <SelectButton
                className="workbench-shell__plugin-select"
                onClick={() => publishFeedback({
                  message: "Clipboard 激活时仍保留当前 Buffer 插件",
                  tone: "neutral",
                })}
              >
                <span className="workbench-shell__plugin-label">
                  <Icon name="grid" size={13} weight="bold" />
                  Default
                </span>
              </SelectButton>
            </>
          )}
          onClose={() => {
            setClipboardVisible(false);
            publishFeedback({ message: "已关闭剪贴板区", tone: "neutral" });
          }}
          onRefresh={() => publishFeedback({ message: "Buffer 已刷新", tone: "neutral" })}
          status={statusText()}
          statusDetail={protectedContent
            ? "安全输入期间剪贴板历史已遮蔽"
            : "←/→ 选择，Enter 激活，Backspace 删除；双击也可激活"}
        >
          {bufferVisible ? (
            <BufferPreviewRail
              blocks={bufferBlocks}
              onSend={() => {
                if (bufferBlocks.length === 0) return;
                setBufferBlocks((current) => current.slice(1));
                publishFeedback({ message: "已发送下一块", tone: "accent" });
              }}
            />
          ) : null}
        </WorkbenchShell>
      </div>

      <footer className="clipboard-surface__legend">
        <span><kbd>←</kbd><kbd>→</kbd> 选择</span>
        <span><kbd>Enter</kbd> 激活</span>
        <span><kbd>Backspace</kbd> 删除</span>
        <span>双击卡片激活</span>
        <span className="clipboard-surface__legend-spacer" />
        <Button kind="ghost" onClick={() => publishItems([])}>空状态</Button>
        <Button kind="ghost" onClick={resetItems}>恢复示例</Button>
      </footer>
    </section>
  );
}
