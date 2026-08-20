import { readFile } from "node:fs/promises";

const tokenURL = new URL("../src/design-system/tokens/themes.json", import.meta.url);
const source = JSON.parse(await readFile(tokenURL, "utf8"));

function rgb(hex) {
  const value = hex.replace("#", "");
  if (!/^[0-9a-f]{6}$/i.test(value)) {
    throw new Error(`Invalid color token: ${hex}`);
  }
  return [0, 2, 4].map((offset) => Number.parseInt(value.slice(offset, offset + 2), 16) / 255);
}

function luminance(hex) {
  return rgb(hex)
    .map((channel) =>
      channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4,
    )
    .reduce((sum, channel, index) => sum + channel * [0.2126, 0.7152, 0.0722][index], 0);
}

function contrast(foreground, background) {
  const [lighter, darker] = [luminance(foreground), luminance(background)].sort((a, b) => b - a);
  return (lighter + 0.05) / (darker + 0.05);
}

const textPairs = [
  ["accentForeground", "accent"],
  ["accentText", "surfaceSecondary"],
  ["accentText", "settingsBackground"],
  ["textPrimary", "surfaceSecondary"],
  ["textSecondary", "surfaceSecondary"],
  ["textMuted", "surfaceSecondary"],
  ["selectionText", "selection"],
  ["bufferMuted", "candidate"],
  ["warningText", "warningSurface"],
  ["dangerText", "surfaceSecondary"],
  ["dangerForeground", "dangerFill"],
];

const failures = [];
for (const [themeID, theme] of Object.entries(source.themes)) {
  for (const [foregroundKey, backgroundKey] of textPairs) {
    const ratio = contrast(theme[foregroundKey], theme[backgroundKey]);
    if (ratio < 4.5) {
      failures.push(
        `${themeID}: ${foregroundKey}/${backgroundKey} = ${ratio.toFixed(2)}:1 (minimum 4.50:1)`,
      );
    }
  }
}

if (failures.length > 0) {
  console.error(["Color contrast check failed:", ...failures.map((item) => `- ${item}`)].join("\n"));
  process.exitCode = 1;
} else {
  console.log(`Color contrast check passed for ${Object.keys(source.themes).length} themes.`);
}
