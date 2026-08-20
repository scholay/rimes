import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const sourcePath = path.join(root, "src/design-system/tokens/themes.json");
const outputPath = path.join(root, "generated/RimeDesignTokens.generated.swift");
const source = JSON.parse(fs.readFileSync(sourcePath, "utf8"));

const swiftName = (value) => value[0].toUpperCase() + value.slice(1);
const hex = (value) => `0x${value.slice(1).toUpperCase()}`;
const colorKeys = [
  "accent", "accentForeground", "buffer", "bufferSecondary", "bufferBorder",
  "surface", "surfaceSecondary", "surfaceTertiary", "border", "borderStrong",
  "textPrimary", "textSecondary", "textMuted", "selection", "selectionText", "candidate",
];

let output = "// Generated from DesignSystem/src/design-system/tokens/themes.json.\n";
output += "// Design reference only; production adoption should be reviewed in the native target.\n\n";
output += "enum RimeDesignTokensGenerated {\n";
for (const [id, theme] of Object.entries(source.themes)) {
  output += `    enum ${swiftName(id)} {\n`;
  output += `        static let title = ${JSON.stringify(theme.title)}\n`;
  for (const key of colorKeys) output += `        static let ${key}: UInt32 = ${hex(theme[key])}\n`;
  output += "    }\n";
}
output += "}\n";

fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(outputPath, output);
console.log(path.relative(root, outputPath));
