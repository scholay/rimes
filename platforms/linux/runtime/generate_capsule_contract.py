#!/usr/bin/env python3
"""Import the reviewed macOS Capsule navigation and manager geometry."""
import argparse
import hashlib
import json
from pathlib import Path
import re
ROOT = Path(__file__).resolve().parents[3]
SOURCES = ["OfficialPlugins/native/macos/CapsuleModules.swift", "Sources/RimeBuffer/CapsuleWindowController.swift",
           "Sources/RimeBuffer/CapsuleRailSmoke.swift"]
def extract():
    modules, window, smoke = [(ROOT / name).read_text() for name in SOURCES]
    module_part = modules.split("enum CapsuleModuleID:")[1].split("enum CapsuleModuleFilter:")[0]
    names = re.search(r"case ([^\n]+)", module_part).group(1).split(", ")
    titles = dict(re.findall(r'case \.(\w+): return "([^"]+)"', module_part.split("var symbolName")[0]))
    icons = dict(re.findall(r'case \.(\w+): return "([^"]+)"', module_part.split("var symbolName")[1].split("var filters")[0]))
    filters = dict(re.findall(r"case \.(\w+): return \[(.*?)\]", module_part.split("var defaultFilters")[1]))
    filter_part = modules.split("enum CapsuleModuleFilter:")[1].split("enum CapsuleModuleClassification")[0]
    labels = dict(re.findall(r'case \.(\w+): return "([^"]+)"', filter_part))
    if names != ["temporary", "capture", "notes", "resources", "passwords"]:
        raise ValueError("Review the native Capsule module contract")
    navigation = [{"id": name, "plugin": "builtin.capsule." + name, "title": titles[name], "icon": icons[name],
                   "filters": [{"id": f.strip().removeprefix("."), "title": labels[f.strip().removeprefix(".")]} for f in filters[name].split(",")]} for name in names]
    def number(pattern):
        found = re.search(pattern, window, re.S)
        if not found: raise ValueError("Review Capsule geometry: " + pattern)
        return float(found.group(1))
    metrics = {
        "width": number(r"defaultContentSize = NSSize\(width: (\d+)"),
        "height": number(r"defaultContentSize = NSSize\(width: \d+, height: (\d+)"),
        "minimumWidth": number(r"minimumContentSize = NSSize\(width: (\d+)"),
        "minimumHeight": number(r"minimumContentSize = NSSize\(width: \d+, height: (\d+)"),
        "moduleWidth": number(r"equalToConstant: usesModules \? (\d+)"),
        "rowHeight": number(r"tableView.rowHeight = (\d+)"),
        "listFraction": number(r"equalTo: root.widthAnchor,\s*multiplier: ([\d.]+)"),
        "headerInset": number(r"header.leadingAnchor.constraint\(equalTo: root.leadingAnchor, constant: (\d+)"),
        "headerHeight": number(r"header.heightAnchor.constraint\(equalToConstant: (\d+)"),
    }
    samples = smoke.split("static func renderManagerPreview", 1)[1].split("for (title, content)", 1)[0]
    manager_preview = [{"title": title, "content": json.loads('"' + content + '"')}
                       for title, content in re.findall(r'\("([^"]+)", "((?:\\.|[^"\\])*)"\)', samples)]
    if len(manager_preview) != 3: raise ValueError("Review native Capsule preview fixtures")
    return {"modules": navigation, "metrics": metrics, "managerPreview": manager_preview,
            "sources": {n: hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in SOURCES}}
if __name__ == "__main__":
    parser = argparse.ArgumentParser(); parser.add_argument("--output", type=Path, required=True); args = parser.parse_args()
    data = json.dumps(extract(), ensure_ascii=False, separators=(",", ":"))
    text = '#pragma once\nnamespace rimes::capsule::native { inline constexpr char kContract[] = R"CAPSULE(' + data + ')CAPSULE"; }\n'
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if not args.output.exists() or args.output.read_text() != text: args.output.write_text(text)
