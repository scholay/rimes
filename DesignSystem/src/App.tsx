import { useEffect, useMemo, useState, type CSSProperties } from "react";
import { Icon } from "./design-system/Icon";
import {
  initialPlugins,
  surfaces,
  type PluginRecord,
  type SurfaceID,
} from "./design-system/data";
import { Button, Segmented } from "./design-system/primitives";
import {
  metrics,
  serializeDraft,
  themeCSSVariables,
  themes,
  type MetricTokens,
  type ThemeID,
  type ThemeTokens,
} from "./design-system/tokens";
import { BufferSurface } from "./surfaces/BufferSurface";
import { CandidateSurface } from "./surfaces/CandidateSurface";
import { ClipboardSurface } from "./surfaces/ClipboardSurface";
import { ExtensionsSurface } from "./surfaces/ExtensionsSurface";
import type {
  PluginConfiguration,
  PluginConfigurationMap,
} from "./surfaces/ExtensionsSurface";
import { SettingsSurface } from "./surfaces/SettingsSurface";

const themeOptions = (Object.entries(themes) as [ThemeID, ThemeTokens][]).map(
  ([value, theme]) => ({ value, label: theme.title }),
);

const zoomOptions = [
  { value: "75", label: "75%" },
  { value: "90", label: "90%" },
  { value: "100", label: "100%" },
] as const;

function validSurface(value: string | null): value is SurfaceID {
  return surfaces.some((surface) => surface.id === value);
}

function validTheme(value: string | null): value is ThemeID {
  return value !== null && Object.hasOwn(themes, value);
}

function initialQueryState() {
  const params = new URLSearchParams(window.location.search);
  const surface = params.get("surface");
  const theme = params.get("theme");
  return {
    surface: validSurface(surface) ? surface : "settings" as SurfaceID,
    theme: validTheme(theme) ? theme : "night" as ThemeID,
  };
}

function copyPluginFixtures(): PluginRecord[] {
  return initialPlugins.map((plugin) => ({ ...plugin }));
}

export function App() {
  const query = useMemo(initialQueryState, []);
  const [surfaceID, setSurfaceID] = useState<SurfaceID>(query.surface);
  const [themeID, setThemeID] = useState<ThemeID>(query.theme);
  const [plugins, setPlugins] = useState<PluginRecord[]>(copyPluginFixtures);
  const [pluginConfigurations, setPluginConfigurations] = useState<PluginConfigurationMap>({});
  const [zoom, setZoom] = useState<"75" | "90" | "100">("90");
  const [showInspector, setShowInspector] = useState(true);
  const [showGrid, setShowGrid] = useState(false);
  const [themeOverrides, setThemeOverrides] = useState<Partial<ThemeTokens>>({});
  const [metricOverrides, setMetricOverrides] = useState<Partial<MetricTokens>>({});
  const [notice, setNotice] = useState("设计场景已就绪");

  const activeTheme = { ...themes[themeID], ...themeOverrides } as ThemeTokens;
  const activeSurface = surfaces.find((surface) => surface.id === surfaceID) ?? surfaces[0];
  const availableBufferPluginIDs = useMemo(() => plugins
    .filter((plugin) => (
      plugin.category === "buffer"
      && plugin.enabled
      && (plugin.installState === "bundled" || plugin.installState === "installed")
    ))
    .map((plugin) => plugin.id), [plugins]);
  const draft = serializeDraft(themeID, activeTheme, metricOverrides);
  const rootStyle = {
    ...themeCSSVariables(themes[themeID], themeOverrides, metricOverrides),
    "--studio-zoom": Number(zoom) / 100,
  } as CSSProperties;

  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    params.set("surface", surfaceID);
    params.set("theme", themeID);
    window.history.replaceState(null, "", `${window.location.pathname}?${params}`);
  }, [surfaceID, themeID]);

  useEffect(() => {
    setThemeOverrides({});
  }, [themeID]);

  const updateThemeColor = (
    key: "accent" | "selection" | "surface" | "surfaceSecondary",
    value: string,
  ) => {
    setThemeOverrides((current) => ({ ...current, [key]: value.toUpperCase() }));
    setNotice(`${key} 已更新为 ${value.toUpperCase()}`);
  };

  const copyTokens = async () => {
    try {
      await navigator.clipboard.writeText(draft);
      setNotice("当前 token JSON 已复制");
    } catch {
      setNotice("浏览器未授权复制，可使用导出 JSON");
    }
  };

  const exportTokens = () => {
    const blob = new Blob([draft], { type: "application/json" });
    const href = URL.createObjectURL(blob);
    const anchor = document.createElement("a");
    anchor.href = href;
    anchor.download = `rimes-${themeID}-tokens.json`;
    anchor.click();
    URL.revokeObjectURL(href);
    setNotice("当前 token JSON 已导出");
  };

  const savePluginConfiguration = (
    plugin: PluginRecord,
    configuration: PluginConfiguration,
  ) => {
    setPluginConfigurations((current) => ({
      ...current,
      [plugin.id]: configuration,
    }));
    setNotice(`${plugin.name} 配置已同步到全部设计场景`);
  };

  const renderSurface = () => {
    switch (surfaceID) {
      case "settings":
        return (
          <SettingsSurface
            onThemeChange={setThemeID}
            onPluginConfigurationChange={savePluginConfiguration}
            pluginConfigurations={pluginConfigurations}
            plugins={plugins}
            setPlugins={setPlugins}
            themeID={themeID}
          />
        );
      case "extensions":
        return (
          <ExtensionsSurface
            onOpenSettings={() => setSurfaceID("settings")}
            onPluginConfigurationChange={savePluginConfiguration}
            pluginConfigurations={pluginConfigurations}
            plugins={plugins}
            setPlugins={setPlugins}
          />
        );
      case "candidate":
        return (
          <CandidateSurface
            onActivateBuffer={() => {
              setSurfaceID("buffer");
              setNotice("已打开 Buffer 设计场景");
            }}
            onCommit={(candidate) => setNotice(`候选“${candidate.text}”已提交到模拟状态`)}
            onOpenSettings={() => setSurfaceID("settings")}
          />
        );
      case "buffer":
        return (
          <BufferSurface
            availablePluginIDs={availableBufferPluginIDs}
            onGenerate={(mode) => setNotice(`${mode} 已开始生成`)}
            onClose={() => {
              setSurfaceID("settings");
              setNotice("Buffer 已关闭；设计状态仍保留在当前会话");
            }}
            onSend={(_, mode) => setNotice(`${mode} 内容已发送到模拟目标`)}
          />
        );
      case "clipboard":
        return <ClipboardSurface onFeedback={(feedback) => setNotice(feedback.message)} />;
    }
  };

  return (
    <div
      className={`design-lab${showInspector ? "" : " is-inspector-hidden"}`}
      data-dark={activeTheme.dark ? "true" : "false"}
      data-theme={themeID}
      style={rootStyle}
    >
      <header className="studio-toolbar">
        <div className="studio-brand">
          <span className="studio-brand__mark"><Icon name="grid" size={18} weight="fill" /></span>
          <span className="studio-brand__copy">
            <strong>RIMES Design System</strong>
            <small>React · design/react-system</small>
          </span>
        </div>

        <div className="studio-toolbar__themes">
          <span>主题</span>
          <Segmented
            ariaLabel="设计系统主题"
            onChange={setThemeID}
            options={themeOptions}
            value={themeID}
          />
        </div>

        <span className="studio-toolbar__spacer" />
        <Button icon="copy" kind="ghost" onClick={copyTokens}>复制 token</Button>
        <Button icon="export" kind="secondary" onClick={exportTokens}>导出 JSON</Button>
      </header>

      <aside className="studio-navigation">
        <header className="studio-navigation__header">
          <span>产品界面</span>
          <small>5 个可操作场景</small>
        </header>
        <nav aria-label="设计场景">
          {surfaces.map((surface) => (
            <button
              aria-current={surface.id === surfaceID ? "page" : undefined}
              className={`studio-nav-item${surface.id === surfaceID ? " is-selected" : ""}`}
              key={surface.id}
              onClick={() => setSurfaceID(surface.id)}
              type="button"
            >
              <span className="studio-nav-item__icon"><Icon name={surface.icon} size={18} weight="duotone" /></span>
              <span className="studio-nav-item__copy">
                <strong>{surface.title}</strong>
                <small>{surface.caption}</small>
              </span>
            </button>
          ))}
        </nav>

        <section className="studio-navigation__note">
          <Icon name="code" size={17} weight="duotone" />
          <span>
            <strong>网页是设计母版</strong>
            <small>正式输入焦点与窗口行为仍由 AppKit 实现。</small>
          </span>
        </section>
      </aside>

      <main className="studio-main">
        <header className="studio-canvas-toolbar">
          <span className="studio-canvas-toolbar__title">
            <Icon name={activeSurface.icon} size={17} weight="duotone" />
            <strong>{activeSurface.title}</strong>
            <small>{activeSurface.caption}</small>
          </span>
          <label className="studio-grid-toggle">
            <input checked={showGrid} onChange={(event) => setShowGrid(event.target.checked)} type="checkbox" />
            <span>布局辅助线</span>
          </label>
          <Segmented
            ariaLabel="画布缩放"
            onChange={setZoom}
            options={zoomOptions}
            value={zoom}
          />
          <Button
            icon="sliders"
            kind={showInspector ? "secondary" : "ghost"}
            onClick={() => setShowInspector((visible) => !visible)}
          >
            Inspector
          </Button>
        </header>

        <div className={`studio-canvas${showGrid ? " is-grid-visible" : ""}`}>
          <div className="studio-canvas__viewport">
            <div className="studio-canvas__zoom">{renderSurface()}</div>
          </div>
        </div>

        <footer className="studio-statusbar">
          <span className="studio-statusbar__dot" />
          <span aria-live="polite">{notice}</span>
          <span className="studio-statusbar__spacer" />
          <span>1 CSS px = 1 macOS logical pt</span>
        </footer>
      </main>

      {showInspector ? (
        <aside className="studio-inspector">
          <header className="studio-inspector__header">
            <span>
              <strong>Design tokens</strong>
              <small>{themes[themeID].title} · 实时作用于全部组件</small>
            </span>
          </header>

          <section className="inspector-section">
            <h2>颜色</h2>
            {([
              ["accent", "产品强调色"],
              ["selection", "选中背景"],
              ["surface", "主表面"],
              ["surfaceSecondary", "卡片表面"],
            ] as const).map(([key, label]) => (
              <label className="color-token-row" key={key}>
                <input
                  onChange={(event) => updateThemeColor(key, event.target.value)}
                  type="color"
                  value={activeTheme[key] as string}
                />
                <span><strong>{label}</strong><small>{activeTheme[key] as string}</small></span>
              </label>
            ))}
          </section>

          <section className="inspector-section">
            <h2>形状与密度</h2>
            <label className="inspector-range-row">
              <span><strong>卡片圆角</strong><small>{metricOverrides.radiusCard ?? metrics.radiusCard}px</small></span>
              <input
                max="20"
                min="4"
                onChange={(event) => setMetricOverrides((current) => ({
                  ...current,
                  radiusCard: Number(event.target.value),
                }))}
                type="range"
                value={metricOverrides.radiusCard ?? metrics.radiusCard}
              />
            </label>
            <label className="inspector-range-row">
              <span><strong>控件圆角</strong><small>{metricOverrides.radiusControl ?? metrics.radiusControl}px</small></span>
              <input
                max="16"
                min="3"
                onChange={(event) => setMetricOverrides((current) => ({
                  ...current,
                  radiusControl: Number(event.target.value),
                }))}
                type="range"
                value={metricOverrides.radiusControl ?? metrics.radiusControl}
              />
            </label>
          </section>

          <section className="inspector-section">
            <h2>语义色板</h2>
            <div className="token-swatch-grid">
              {([
                ["Accent", activeTheme.accent],
                ["Surface", activeTheme.surface],
                ["Surface 2", activeTheme.surfaceSecondary],
                ["Surface 3", activeTheme.surfaceTertiary],
                ["Border", activeTheme.border],
                ["Text", activeTheme.textPrimary],
              ] as const).map(([label, color]) => (
                <span className="token-swatch" key={label}>
                  <i style={{ backgroundColor: color }} />
                  <small>{label}</small>
                </span>
              ))}
            </div>
          </section>

          <div className="studio-inspector__actions">
            <Button
              icon="refresh"
              kind="ghost"
              onClick={() => {
                setThemeOverrides({});
                setMetricOverrides({});
                setNotice("已恢复当前主题的原生 token");
              }}
            >
              恢复原生值
            </Button>
          </div>
        </aside>
      ) : null}
    </div>
  );
}
