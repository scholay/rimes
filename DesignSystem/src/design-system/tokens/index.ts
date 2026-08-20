import type { CSSProperties } from "react";
import source from "./themes.json";

export type ThemeID = keyof typeof source.themes;
export type ThemeTokens = (typeof source.themes)[ThemeID];
export type MetricTokens = typeof source.metrics;

export const themes = source.themes;
export const metrics = source.metrics;

export function themeCSSVariables(
  theme: ThemeTokens,
  overrides: Partial<ThemeTokens> = {},
  metricOverrides: Partial<MetricTokens> = {},
): CSSProperties {
  const value = { ...theme, ...overrides };
  const sizes = { ...metrics, ...metricOverrides };
  return {
    "--r-accent": value.accent,
    "--r-accent-foreground": value.accentForeground,
    "--r-buffer": value.buffer,
    "--r-buffer-2": value.bufferSecondary,
    "--r-buffer-border": value.bufferBorder,
    "--r-surface": value.surface,
    "--r-surface-2": value.surfaceSecondary,
    "--r-surface-3": value.surfaceTertiary,
    "--r-border": value.border,
    "--r-border-strong": value.borderStrong,
    "--r-text": value.textPrimary,
    "--r-text-2": value.textSecondary,
    "--r-text-3": value.textMuted,
    "--r-selection": value.selection,
    "--r-selection-text": value.selectionText,
    "--r-candidate": value.candidate,
    "--r-window-radius": `${sizes.radiusWindow}px`,
    "--r-card-radius": `${sizes.radiusCard}px`,
    "--r-control-radius": `${sizes.radiusControl}px`,
    "--r-chip-radius": `${sizes.radiusChip}px`,
  } as CSSProperties;
}

export function serializeDraft(
  themeID: ThemeID,
  theme: ThemeTokens,
  metricOverrides: Partial<MetricTokens>,
) {
  return JSON.stringify(
    {
      schemaVersion: 1,
      source: "RIMES Design Lab",
      themeID,
      theme,
      metrics: { ...metrics, ...metricOverrides },
    },
    null,
    2,
  );
}
