import {
  useEffect,
  useMemo,
  useState,
  type KeyboardEvent,
} from "react";
import { Icon } from "../design-system/Icon";
import { IconButton } from "../design-system/primitives";

export type CandidateLayout = "compact" | "matrix";

export type CandidateItem = {
  id?: string;
  text: string;
  /** Optional label supplied by the input engine. Falls back to 1...9. */
  label?: string;
  annotation?: string;
  disabled?: boolean;
};

export type CandidateSurfaceProps = {
  candidates?: readonly CandidateItem[];
  preedit?: string;
  layout?: CandidateLayout;
  defaultLayout?: CandidateLayout;
  selectedIndex?: number;
  defaultSelectedIndex?: number;
  page?: number;
  defaultPage?: number;
  compactPageSize?: number;
  matrixColumns?: number;
  matrixRows?: number;
  bufferActive?: boolean;
  showLayoutControl?: boolean;
  className?: string;
  onLayoutChange?: (layout: CandidateLayout) => void;
  onSelectedIndexChange?: (index: number, candidate: CandidateItem) => void;
  onPageChange?: (page: number) => void;
  onCommit?: (candidate: CandidateItem, index: number) => void;
  onActivateBuffer?: () => void;
  onOpenSettings?: () => void;
};

const DEFAULT_CANDIDATES: readonly CandidateItem[] = [
  { text: "你好" },
  { text: "拟好" },
  { text: "你" },
  { text: "尼" },
  { text: "泥" },
  { text: "逆" },
  { text: "拟" },
  { text: "腻" },
  { text: "妮" },
  { text: "你好呀" },
  { text: "你好吗" },
  { text: "你好世界" },
];

function clamp(value: number, minimum: number, maximum: number) {
  return Math.min(Math.max(value, minimum), maximum);
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

/**
 * Interactive design-system mirror of the non-activating AppKit candidate panel.
 * It intentionally models visual and selection state only; IMK focus ownership
 * remains a native runtime concern.
 */
export function CandidateSurface({
  candidates = DEFAULT_CANDIDATES,
  preedit = "ni hao",
  layout: controlledLayout,
  defaultLayout = "compact",
  selectedIndex: controlledSelectedIndex,
  defaultSelectedIndex = 0,
  page: controlledPage,
  defaultPage = 0,
  compactPageSize = 6,
  matrixColumns = 3,
  matrixRows = 3,
  bufferActive = true,
  showLayoutControl = true,
  className = "",
  onLayoutChange,
  onSelectedIndexChange,
  onPageChange,
  onCommit,
  onActivateBuffer,
  onOpenSettings,
}: CandidateSurfaceProps) {
  const [layout, setLayout] = useControllableState(
    controlledLayout,
    defaultLayout,
    onLayoutChange,
  );
  const [selectedIndex, setSelectedIndexState] = useControllableState(
    controlledSelectedIndex,
    defaultSelectedIndex,
  );
  const [page, setPageState] = useControllableState(
    controlledPage,
    defaultPage,
    onPageChange,
  );

  const safeRows = clamp(Math.round(matrixRows), 1, 3);
  const safeColumns = clamp(Math.round(matrixColumns), 1, 9);
  const pageSize = layout === "compact"
    ? clamp(Math.round(compactPageSize), 1, 9)
    : safeRows * safeColumns;
  const pageCount = Math.max(1, Math.ceil(candidates.length / pageSize));
  const safePage = clamp(page, 0, pageCount - 1);
  const pageStart = safePage * pageSize;
  const visibleCandidates = useMemo(
    () => candidates.slice(pageStart, pageStart + pageSize),
    [candidates, pageStart, pageSize],
  );
  const pageEnd = pageStart + visibleCandidates.length;
  const selectedCandidateIsVisible = selectedIndex >= pageStart
    && selectedIndex < pageEnd
    && !candidates[selectedIndex]?.disabled;
  const firstEnabledVisibleOffset = visibleCandidates.findIndex((candidate) => !candidate.disabled);
  const visibleSelectedIndex = selectedCandidateIsVisible
    ? selectedIndex
    : firstEnabledVisibleOffset >= 0
      ? pageStart + firstEnabledVisibleOffset
      : -1;

  useEffect(() => {
    if (page !== safePage) setPageState(safePage);
  }, [page, safePage, setPageState]);

  useEffect(() => {
    if (visibleSelectedIndex < 0 || visibleSelectedIndex === selectedIndex) return;
    const candidate = candidates[visibleSelectedIndex];
    if (!candidate) return;
    setSelectedIndexState(visibleSelectedIndex);
    onSelectedIndexChange?.(visibleSelectedIndex, candidate);
  }, [selectedIndex, visibleSelectedIndex]);

  const selectCandidate = (index: number, commit = false) => {
    const candidate = candidates[index];
    if (!candidate || candidate.disabled) return;
    setSelectedIndexState(index);
    onSelectedIndexChange?.(index, candidate);
    if (commit) onCommit?.(candidate, index);
  };

  const goToPage = (nextPage: number) => {
    const resolvedPage = clamp(nextPage, 0, pageCount - 1);
    setPageState(resolvedPage);
    const firstEnabledIndex = candidates.findIndex(
      (candidate, index) => index >= resolvedPage * pageSize && !candidate.disabled,
    );
    if (firstEnabledIndex >= 0 && firstEnabledIndex < (resolvedPage + 1) * pageSize) {
      selectCandidate(firstEnabledIndex);
    }
  };

  const moveSelection = (delta: number) => {
    if (candidates.length === 0) return;
    let next = visibleSelectedIndex >= 0
      ? visibleSelectedIndex
      : delta > 0
        ? pageStart - 1
        : pageEnd;
    for (let attempts = 0; attempts < candidates.length; attempts += 1) {
      next = (next + delta + candidates.length) % candidates.length;
      if (!candidates[next]?.disabled) break;
    }
    selectCandidate(next);
    const nextPage = Math.floor(next / pageSize);
    if (nextPage !== safePage) setPageState(nextPage);
  };

  const handleKeyDown = (event: KeyboardEvent<HTMLElement>) => {
    const target = event.target as HTMLElement | null;
    const focusedCandidate = target?.closest<HTMLButtonElement>(".candidate-option");
    const interactiveControl = target?.closest<HTMLElement>(
      "button, input, select, textarea, a[href], [role='button'], [role='tab'], [contenteditable='true']",
    );

    // The surface-level router models IME candidate keys, but events bubble
    // here from its own Settings/layout/pagination controls too. Let every
    // non-candidate control retain native Enter and Arrow semantics.
    if (interactiveControl && !focusedCandidate) return;

    if (event.key === "ArrowRight" || event.key === "ArrowDown") {
      event.preventDefault();
      moveSelection(1);
      return;
    }
    if (event.key === "ArrowLeft" || event.key === "ArrowUp") {
      event.preventDefault();
      moveSelection(-1);
      return;
    }
    if (event.key === "PageDown") {
      event.preventDefault();
      goToPage(safePage + 1);
      return;
    }
    if (event.key === "PageUp") {
      event.preventDefault();
      goToPage(safePage - 1);
      return;
    }
    if (event.key === "Enter") {
      const focusedIndex = Number(focusedCandidate?.dataset.candidateIndex);
      const commitIndex = Number.isInteger(focusedIndex)
        ? focusedIndex
        : visibleSelectedIndex;
      const candidate = candidates[commitIndex];
      if (
        commitIndex < pageStart
        || commitIndex >= pageEnd
        || !candidate
        || candidate.disabled
      ) return;
      event.preventDefault();
      selectCandidate(commitIndex, true);
      return;
    }
    if (/^[1-9]$/.test(event.key)) {
      const localIndex = Number(event.key) - 1;
      const index = pageStart + localIndex;
      if (localIndex < visibleCandidates.length) {
        event.preventDefault();
        selectCandidate(index, true);
      }
    }
  };

  return (
    <section
      aria-label="输入法候选框"
      className={`candidate-surface candidate-surface--${layout}${className ? ` ${className}` : ""}`}
      data-layout={layout}
      onKeyDown={handleKeyDown}
    >
      {showLayoutControl ? (
        <div aria-label="候选框布局" className="candidate-surface__view-controls" role="group">
          <IconButton
            icon="textbox"
            label="单行布局"
            onClick={() => setLayout("compact")}
            selected={layout === "compact"}
          />
          <IconButton
            icon="grid"
            label="矩阵布局"
            onClick={() => setLayout("matrix")}
            selected={layout === "matrix"}
          />
        </div>
      ) : null}

      <div className="candidate-panel" data-has-preedit={Boolean(preedit)}>
        {preedit ? (
          <div aria-label={`正在输入：${preedit}`} className="candidate-panel__preedit">
            {preedit}
          </div>
        ) : null}

        <div className="candidate-panel__strip">
          <div
            aria-label={`候选词，第 ${safePage + 1} 页，共 ${pageCount} 页`}
            className="candidate-panel__candidates"
            role="listbox"
          >
            {visibleCandidates.length > 0 ? visibleCandidates.map((candidate, localIndex) => {
              const index = pageStart + localIndex;
              const isSelected = visibleSelectedIndex === index;
              return (
                <div className="candidate-option-wrap" key={candidate.id ?? `${candidate.text}-${index}`}>
                  <button
                    aria-label={`${candidate.label ?? localIndex + 1} ${candidate.text}${candidate.annotation ? `，${candidate.annotation}` : ""}`}
                    aria-selected={isSelected}
                    className={`candidate-option${isSelected ? " is-selected" : ""}`}
                    disabled={candidate.disabled}
                    data-candidate-index={index}
                    onClick={() => selectCandidate(index)}
                    onDoubleClick={() => selectCandidate(index, true)}
                    role="option"
                    type="button"
                  >
                    <span className="candidate-option__label">{candidate.label ?? localIndex + 1}</span>
                    <span className="candidate-option__text">{candidate.text}</span>
                    {candidate.annotation ? (
                      <span className="candidate-option__annotation">{candidate.annotation}</span>
                    ) : null}
                  </button>
                  {layout === "compact" && localIndex < visibleCandidates.length - 1 ? (
                    <span aria-hidden="true" className="candidate-option__separator">|</span>
                  ) : null}
                </div>
              );
            }) : (
              <span className="candidate-panel__empty">暂无候选</span>
            )}
          </div>

          {!bufferActive ? (
            <button
              className="candidate-panel__buffer-action"
              onClick={onActivateBuffer}
              title="开启缓冲区"
              type="button"
            >
              <span className="candidate-panel__buffer-label">0</span>
              <Icon name="tray" size={13} weight="bold" />
            </button>
          ) : null}

          <div className="candidate-panel__pagination">
            <button
              aria-label="上一页候选"
              className="candidate-panel__page-button"
              disabled={safePage === 0}
              onClick={() => goToPage(safePage - 1)}
              type="button"
            >
              上页
            </button>
            <span aria-live="polite" className="candidate-panel__page-status">
              {safePage + 1}/{pageCount}
            </span>
            <button
              aria-label="下一页候选"
              className="candidate-panel__page-button"
              disabled={safePage >= pageCount - 1}
              onClick={() => goToPage(safePage + 1)}
              type="button"
            >
              下页
            </button>
          </div>

          <IconButton icon="gear" label="打开设置" onClick={onOpenSettings} />
        </div>
      </div>
    </section>
  );
}
