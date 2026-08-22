import { useState } from "react";
import {
  act,
  cleanup,
  fireEvent,
  render,
  screen,
  within,
} from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { App } from "../src/App";
import { initialPlugins, type PluginRecord } from "../src/design-system/data";
import {
  BufferSurface,
  bufferInputContextKey,
} from "../src/surfaces/BufferSurface";
import { ExtensionsSurface } from "../src/surfaces/ExtensionsSurface";

afterEach(() => {
  cleanup();
  vi.useRealTimers();
});

function PluginHarness() {
  const [plugins, setPlugins] = useState<PluginRecord[]>(
    () => initialPlugins.map((plugin) => ({ ...plugin })),
  );
  return (
    <>
      <ExtensionsSurface plugins={plugins} setPlugins={setPlugins} />
      <button type="button">菜单外测试目标</button>
    </>
  );
}

describe("Buffer generation and delivery", () => {
  it("omits routine status space and keeps the main action icon-only", () => {
    const view = render(
      <BufferSurface
        defaultMode="normal"
        defaultPhase="ready"
        defaultSourceText="source"
      />,
    );

    expect(view.container.querySelector(".buffer-toolbar__status")).toBeNull();
    const sendButton = screen.getByRole("button", { name: "发送" });
    expect(sendButton.classList.contains("buffer-workbench__primary-action")).toBe(true);
    expect(sendButton.textContent).toBe("");
    expect(sendButton.getAttribute("title")).toBe("发送");
    expect(sendButton.querySelector("svg")).toBeTruthy();
    const sendIconMarkup = sendButton.querySelector("svg")?.innerHTML;

    view.rerender(
      <BufferSurface
        defaultMode="normal"
        defaultSourceText="source"
        phase="loading"
      />,
    );
    const status = view.container.querySelector(".buffer-toolbar__status");
    expect(status?.textContent).toBe("正在发送");
    const busyButton = screen.getByRole("button", { name: "发送中…" });
    expect(busyButton.textContent).toBe("");
    expect(busyButton.getAttribute("title")).toBe("发送中…");
    expect(busyButton.getAttribute("aria-busy")).toBe("true");
    expect(busyButton.querySelector("svg")).toBeTruthy();
    expect(busyButton.querySelector("svg")?.innerHTML).not.toBe(sendIconMarkup);
  });

  it("debounces live generation and ignores parent-only callback identity changes", async () => {
    vi.useFakeTimers();
    const firstCallback = vi.fn();
    const latestCallback = vi.fn();
    const view = render(
      <BufferSurface
        defaultMode="stream"
        defaultSourceText="ni hao"
        onGenerate={firstCallback}
      />,
    );

    await act(() => vi.advanceTimersByTimeAsync(100));
    expect(firstCallback).not.toHaveBeenCalled();

    view.rerender(
      <BufferSurface
        defaultMode="stream"
        defaultSourceText="ni hao"
        onGenerate={latestCallback}
      />,
    );
    await act(() => vi.advanceTimersByTimeAsync(319));
    expect(firstCallback).not.toHaveBeenCalled();
    expect(latestCallback).not.toHaveBeenCalled();

    await act(() => vi.advanceTimersByTimeAsync(1));
    expect(firstCallback).not.toHaveBeenCalled();
    expect(latestCallback).toHaveBeenCalledTimes(1);

    await act(() => vi.advanceTimersByTimeAsync(500));
    expect(latestCallback).toHaveBeenCalledTimes(1);
  });

  it("pauses hidden generation and resumes only when the Buffer becomes active", async () => {
    vi.useFakeTimers();
    const onGenerate = vi.fn();
    const view = render(
      <BufferSurface
        defaultMode="stream"
        defaultSourceText="ni hao"
        onGenerate={onGenerate}
      />,
    );

    await act(() => vi.advanceTimersByTimeAsync(200));
    view.rerender(
      <BufferSurface
        defaultMode="stream"
        defaultSourceText="ni hao"
        onGenerate={onGenerate}
        paused
      />,
    );
    await act(() => vi.advanceTimersByTimeAsync(1_000));
    expect(onGenerate).not.toHaveBeenCalled();

    view.rerender(
      <BufferSurface
        defaultMode="stream"
        defaultSourceText="ni hao"
        onGenerate={onGenerate}
      />,
    );
    await act(() => vi.advanceTimersByTimeAsync(420));
    expect(onGenerate).toHaveBeenCalledTimes(1);
  });

  it("still emits a debounced generation intent when phase is controlled", async () => {
    vi.useFakeTimers();
    const onGenerate = vi.fn();
    render(
      <BufferSurface
        mode="translation"
        phase="idle"
        sourceText="hello"
        onGenerate={onGenerate}
      />,
    );

    await act(() => vi.advanceTimersByTimeAsync(419));
    expect(onGenerate).not.toHaveBeenCalled();
    await act(() => vi.advanceTimersByTimeAsync(1));
    expect(onGenerate).toHaveBeenCalledTimes(1);
    expect(onGenerate).toHaveBeenCalledWith(
      "translation",
      "hello",
      expect.objectContaining({ contextKey: expect.any(String), requestID: expect.any(Number) }),
    );
  });

  it("tombstones a controlled generation result that arrives after pause", async () => {
    vi.useFakeTimers();
    const onGenerate = vi.fn();
    const view = render(
      <BufferSurface
        mode="translation"
        phase="idle"
        sourceText="hello"
        onGenerate={onGenerate}
      />,
    );

    await act(() => vi.advanceTimersByTimeAsync(420));
    const firstRequest = onGenerate.mock.calls[0]?.[2];
    expect(firstRequest).toEqual(expect.objectContaining({
      contextKey: expect.any(String),
      requestID: expect.any(Number),
      signal: expect.any(AbortSignal),
    }));

    view.rerender(
      <BufferSurface
        mode="translation"
        phase="idle"
        sourceText="hello"
        onGenerate={onGenerate}
        paused
      />,
    );
    expect(firstRequest.signal.aborted).toBe(true);

    view.rerender(
      <BufferSurface
        activeRequestID={firstRequest.requestID}
        mode="translation"
        phase="ready"
        sourceText="hello"
        onGenerate={onGenerate}
        targetContext={{
          requestID: firstRequest.requestID,
          contextKey: firstRequest.contextKey,
        }}
        targets={["late result"]}
      />,
    );
    expect(screen.getByRole("button", { name: "发送" }).hasAttribute("disabled")).toBe(true);

    await act(() => vi.advanceTimersByTimeAsync(420));
    expect(onGenerate).toHaveBeenCalledTimes(2);
    expect(onGenerate.mock.calls[1]?.[2].requestID).not.toBe(firstRequest.requestID);
  });

  it("preserves a settled controlled result across pause", async () => {
    vi.useFakeTimers();
    const onGenerate = vi.fn();
    const view = render(
      <BufferSurface mode="ai" phase="ready" sourceText="source" onGenerate={onGenerate} />,
    );
    fireEvent.click(screen.getByRole("button", { name: "生成" }));
    const request = onGenerate.mock.calls[0]?.[2];

    view.rerender(
      <BufferSurface
        activeRequestID={request.requestID}
        mode="ai"
        phase="ready"
        sourceText="source"
        onGenerate={onGenerate}
        targetContext={{ requestID: request.requestID, contextKey: request.contextKey }}
        targets={["settled result"]}
      />,
    );
    expect(screen.getByRole("button", { name: "发送" }).hasAttribute("disabled")).toBe(false);

    view.rerender(
      <BufferSurface
        activeRequestID={request.requestID}
        mode="ai"
        phase="ready"
        sourceText="source"
        onGenerate={onGenerate}
        paused
        targetContext={{ requestID: request.requestID, contextKey: request.contextKey }}
        targets={["settled result"]}
      />,
    );
    expect(request.signal.aborted).toBe(true);

    view.rerender(
      <BufferSurface
        activeRequestID={request.requestID}
        mode="ai"
        phase="ready"
        sourceText="source"
        onGenerate={onGenerate}
        targetContext={{ requestID: request.requestID, contextKey: request.contextKey }}
        targets={["settled result"]}
      />,
    );
    expect(screen.getByRole("button", { name: "发送" }).hasAttribute("disabled")).toBe(false);
  });

  it("aborts managed exchange work when controlled source or mode changes", () => {
    const onGenerate = vi.fn();
    const view = render(
      <BufferSurface mode="ai" phase="ready" sourceText="first" onGenerate={onGenerate} />,
    );
    fireEvent.click(screen.getByRole("button", { name: "生成" }));
    const sourceRequest = onGenerate.mock.calls[0]?.[2];

    view.rerender(
      <BufferSurface mode="ai" phase="ready" sourceText="second" onGenerate={onGenerate} />,
    );
    expect(sourceRequest.signal.aborted).toBe(true);

    fireEvent.click(screen.getByRole("button", { name: "生成" }));
    const modeRequest = onGenerate.mock.calls[1]?.[2];
    view.rerender(
      <BufferSurface mode="marine" phase="ready" sourceText="second" onGenerate={onGenerate} />,
    );
    expect(modeRequest.signal.aborted).toBe(true);
  });

  it("offers explicit translation when continuous translation is disabled", async () => {
    vi.useFakeTimers();
    const onGenerate = vi.fn();
    render(
      <BufferSurface
        defaultMode="translation"
        defaultSourceText="hello"
        onGenerate={onGenerate}
        translationContinuously={false}
      />,
    );

    await act(() => vi.advanceTimersByTimeAsync(1_000));
    expect(onGenerate).not.toHaveBeenCalled();

    fireEvent.click(screen.getByRole("button", { name: "翻译" }));
    expect(onGenerate).toHaveBeenCalledTimes(1);
    expect(onGenerate).toHaveBeenCalledWith(
      "translation",
      "hello",
      expect.objectContaining({ contextKey: expect.any(String), requestID: expect.any(Number) }),
    );
  });

  it("swaps an auto-detected source into a valid explicit target", () => {
    const onLanguageChange = vi.fn();
    render(
      <BufferSurface
        defaultMode="translation"
        defaultSourceLanguage="auto"
        defaultSourceText="hello"
        defaultTargetLanguage="zh-Hans"
        onLanguageChange={onLanguageChange}
        translationContinuously={false}
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: "交换源语言和目标语言" }));
    expect(onLanguageChange).toHaveBeenCalledWith("zh-Hans", "en");
    expect((screen.getByRole("combobox", { name: "源语言" }) as HTMLSelectElement).value)
      .toBe("zh-Hans");
    expect((screen.getByRole("combobox", { name: "目标语言" }) as HTMLSelectElement).value)
      .toBe("en");
  });

  it("keeps an exchange result after failed delivery and consumes it only after success", async () => {
    const failedSend = vi.fn().mockResolvedValue(false);
    const failedView = render(
      <BufferSurface
        defaultMode="ai"
        defaultPhase="ready"
        defaultSourceText="source"
        defaultTargets={["generated result"]}
        onSend={failedSend}
      />,
    );

    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "发送" }));
      await Promise.resolve();
    });
    expect(failedSend.mock.calls[0]?.slice(0, 2)).toEqual(["generated result", "ai"]);
    expect(screen.getAllByText("发送失败，请重试")).toHaveLength(2);
    expect(screen.getByText("generated result")).toBeTruthy();
    failedView.unmount();

    const successfulSend = vi.fn().mockResolvedValue(true);
    render(
      <BufferSurface
        defaultMode="ai"
        defaultPhase="ready"
        defaultSourceText="source"
        defaultTargets={["generated result"]}
        onSend={successfulSend}
      />,
    );
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "发送" }));
      await Promise.resolve();
    });
    expect(successfulSend.mock.calls[0]?.slice(0, 2)).toEqual(["generated result", "ai"]);
    expect(screen.queryByText("generated result")).toBeNull();
    expect((screen.getByRole("textbox", { name: "缓冲正文" }) as HTMLInputElement).value)
      .toBe("source");
  });

  it("keeps an exchange result until the host explicitly confirms delivery", async () => {
    render(
      <BufferSurface
        defaultMode="ai"
        defaultPhase="ready"
        defaultSourceText="source"
        defaultTargets={["generated result"]}
      />,
    );

    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "发送" }));
      await Promise.resolve();
    });
    expect(screen.getAllByText("发送失败，请重试")).toHaveLength(2);
    expect(screen.getByText("generated result")).toBeTruthy();
  });

  it("returns to the source rail and abandons the current exchange result", () => {
    render(
      <BufferSurface
        defaultMode="ai"
        defaultPhase="ready"
        defaultSourceText="source"
        defaultTargets={["prior result"]}
      />,
    );
    expect(screen.getByText("prior result")).toBeTruthy();

    fireEvent.click(screen.getByRole("button", {
      name: "返回编辑原文（保留原文，放弃当前结果）",
    }));
    expect(screen.queryByText("prior result")).toBeNull();
    expect((screen.getByRole("textbox", { name: "缓冲正文" }) as HTMLInputElement).value)
      .toBe("source");
    expect(screen.getByRole("button", { name: "生成" })).toBeTruthy();
  });

  it("keeps a settled controlled result sendable after a later request fails", async () => {
    const onGenerate = vi.fn();
    const onSend = vi.fn().mockResolvedValue(true);
    const view = render(
      <BufferSurface
        mode="ai"
        onGenerate={onGenerate}
        onSend={onSend}
        phase="ready"
        sourceText="source"
      />,
    );
    fireEvent.click(screen.getByRole("button", { name: "生成" }));
    const firstRequest = onGenerate.mock.calls[0]?.[2];

    view.rerender(
      <BufferSurface
        activeRequestID={firstRequest.requestID}
        mode="ai"
        onGenerate={onGenerate}
        onSend={onSend}
        phase="ready"
        sourceText="source"
        targetContext={{
          requestID: firstRequest.requestID,
          contextKey: firstRequest.contextKey,
        }}
        targets={["prior result"]}
      />,
    );

    view.rerender(
      <BufferSurface
        activeRequestID={firstRequest.requestID}
        mode="ai"
        onGenerate={onGenerate}
        onSend={onSend}
        phase="error"
        sourceText="source"
        targetContext={{
          requestID: firstRequest.requestID,
          contextKey: firstRequest.contextKey,
        }}
        targets={["prior result"]}
      />,
    );
    expect(screen.getAllByText("处理失败")).toHaveLength(1);
    expect(screen.getByText(
      "处理失败，已保留上次结果。候选 1 / 1：prior result",
    )).toBeTruthy();

    const sendButton = screen.getByRole("button", { name: "发送" });
    expect(sendButton.hasAttribute("disabled")).toBe(false);
    await act(async () => {
      fireEvent.click(sendButton);
      await Promise.resolve();
    });
    expect(onSend.mock.calls[0]?.slice(0, 2)).toEqual(["prior result", "ai"]);
  });

  it("hides rather than deletes a completed result during protected input", () => {
    const view = render(
      <BufferSurface
        defaultMode="translation"
        defaultSourceText="source"
        defaultTargets={["translated result"]}
        phase="ready"
        translationContinuously={false}
      />,
    );
    expect(screen.getByText("translated result")).toBeTruthy();

    view.rerender(
      <BufferSurface
        defaultMode="translation"
        defaultSourceText="source"
        defaultTargets={["translated result"]}
        phase="protected"
        translationContinuously={false}
      />,
    );
    expect(screen.queryByText("translated result")).toBeNull();
    expect(screen.getByText("内容已隐藏")).toBeTruthy();

    view.rerender(
      <BufferSurface
        defaultMode="translation"
        defaultSourceText="source"
        defaultTargets={["translated result"]}
        phase="ready"
        translationContinuously={false}
      />,
    );
    expect(screen.getByText("translated result")).toBeTruthy();
  });

  it("rejects a controlled result whose request context is stale", async () => {
    const onSend = vi.fn().mockResolvedValue(true);
    const view = render(
      <BufferSurface
        activeRequestID="request-1"
        mode="ai"
        onSend={onSend}
        phase="ready"
        sourceText="first source"
        targetContext={{
          requestID: "request-1",
          contextKey: bufferInputContextKey(
            "ai", "first source", "zh-Hans", "en", "apple", 5, "balanced",
          ),
        }}
        targets={["first result"]}
      />,
    );
    expect(screen.getByRole("button", { name: "发送" }).hasAttribute("disabled")).toBe(false);

    view.rerender(
      <BufferSurface
        activeRequestID="request-2"
        mode="marine"
        onSend={onSend}
        phase="ready"
        sourceText="second source"
        targetContext={{
          requestID: "request-1",
          contextKey: bufferInputContextKey(
            "ai", "first source", "zh-Hans", "en", "apple", 5, "balanced",
          ),
        }}
        targets={["first result"]}
      />,
    );
    expect(screen.getByRole("button", { name: "发送" }).hasAttribute("disabled")).toBe(true);
    fireEvent.click(screen.getByRole("button", { name: "发送" }));
    expect(onSend).not.toHaveBeenCalled();
  });

  it("invalidates a controlled translation result when its provider context changes", () => {
    const appleContext = bufferInputContextKey(
      "translation", "hello", "auto", "zh-Hans", "apple", 5, "balanced",
    );
    const view = render(
      <BufferSurface
        activeRequestID="request-1"
        mode="translation"
        phase="ready"
        sourceLanguage="auto"
        sourceText="hello"
        targetContext={{ requestID: "request-1", contextKey: appleContext }}
        targetLanguage="zh-Hans"
        targets={["apple result"]}
        translationContinuously={false}
        translationProvider="apple"
      />,
    );
    expect(screen.getByRole("button", { name: "发送" }).hasAttribute("disabled")).toBe(false);

    view.rerender(
      <BufferSurface
        activeRequestID="request-1"
        mode="translation"
        phase="ready"
        sourceLanguage="auto"
        sourceText="hello"
        targetContext={{ requestID: "request-1", contextKey: appleContext }}
        targetLanguage="zh-Hans"
        targets={["apple result"]}
        translationContinuously={false}
        translationProvider="ai"
      />,
    );
    expect(screen.getByRole("button", { name: "翻译" }).hasAttribute("disabled")).toBe(false);
  });

  it("keeps controlled live candidates usable after a confirmed send", async () => {
    const onGenerate = vi.fn();
    const onSend = vi.fn().mockResolvedValue(true);
    const view = render(
      <BufferSurface
        mode="translation"
        onGenerate={onGenerate}
        onSend={onSend}
        phase="ready"
        sourceText="source"
        translationContinuously={false}
      />,
    );
    fireEvent.click(screen.getByRole("button", { name: "翻译" }));
    const request = onGenerate.mock.calls[0]?.[2];
    view.rerender(
      <BufferSurface
        activeRequestID={request.requestID}
        mode="translation"
        onGenerate={onGenerate}
        onSend={onSend}
        phase="ready"
        sourceText="source"
        targetContext={{ requestID: request.requestID, contextKey: request.contextKey }}
        targets={["first result", "second result"]}
        translationContinuously={false}
      />,
    );

    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "发送" }));
      await Promise.resolve();
    });
    fireEvent.click(screen.getByRole("button", { name: "下一条候选" }));
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "发送" }));
      await Promise.resolve();
    });
    expect(onSend.mock.calls.map((call) => call.slice(0, 2))).toEqual([
      ["first result", "translation"],
      ["second result", "translation"],
    ]);
  });

  it("announces delivery progress over a retained live-generation error", async () => {
    let resolveSend: ((result: boolean) => void) | undefined;
    const pendingSend = vi.fn(() => new Promise<boolean>((resolve) => {
      resolveSend = resolve;
    }));
    const view = render(
      <BufferSurface
        defaultMode="stream"
        defaultPhase="error"
        defaultSourceText="source"
        defaultTargets={["prior result", "second result"]}
        onSend={pendingSend}
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: "下一条候选" }));
    expect(screen.getByText(
      "处理失败，已保留上次结果。候选 2 / 2：second result",
    )).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "发送" }));
    expect(screen.getAllByText("正在发送")).toHaveLength(2);
    expect(screen.queryByText("处理失败")).toBeNull();
    await act(async () => {
      resolveSend?.(false);
      await Promise.resolve();
    });
    expect(screen.getAllByText("发送失败，请重试")).toHaveLength(2);

    const successfulSend = vi.fn().mockResolvedValue(true);
    view.rerender(
      <BufferSurface
        defaultMode="stream"
        defaultPhase="error"
        defaultSourceText="source"
        defaultTargets={["prior result", "second result"]}
        onSend={successfulSend}
      />,
    );
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "发送" }));
      await Promise.resolve();
    });
    expect(screen.getAllByText("已发送")).toHaveLength(2);
    expect(screen.getByText("second result")).toBeTruthy();
  });

  it("caps externally supplied result pages at five", () => {
    render(
      <BufferSurface
        defaultMode="stream"
        defaultPhase="ready"
        defaultSourceText="source"
        defaultTargets={["one", "two", "three", "four", "five", "six"]}
        translationContinuously={false}
      />,
    );
    expect(screen.getByText("1/5")).toBeTruthy();
    expect(screen.queryByText("six")).toBeNull();
  });

  it("freezes delivery context and aborts an in-flight send when paused", async () => {
    let resolveSend: ((result: boolean) => void) | undefined;
    let deliverySignal: AbortSignal | undefined;
    const onSend = vi.fn((_text: string, _mode: string, signal: AbortSignal) => {
      deliverySignal = signal;
      return new Promise<boolean>((resolve) => { resolveSend = resolve; });
    });
    const view = render(
      <BufferSurface
        defaultMode="stream"
        defaultPhase="ready"
        defaultSourceText="source"
        defaultTargets={["first", "second"]}
        onSend={onSend}
        translationContinuously={false}
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: "发送" }));
    expect((screen.getByRole("combobox", { name: "工作台插件" }) as HTMLSelectElement).disabled)
      .toBe(true);
    expect((screen.getByRole("textbox", { name: "缓冲正文" }) as HTMLInputElement).disabled)
      .toBe(true);
    expect((screen.getByRole("button", { name: "下一条候选" }) as HTMLButtonElement).disabled)
      .toBe(true);

    view.rerender(
      <BufferSurface
        defaultMode="stream"
        defaultPhase="ready"
        defaultSourceText="source"
        defaultTargets={["first", "second"]}
        onSend={onSend}
        paused
        translationContinuously={false}
      />,
    );
    expect(deliverySignal?.aborted).toBe(true);
    await act(async () => {
      resolveSend?.(true);
      await Promise.resolve();
    });
    expect(screen.getByText("first")).toBeTruthy();
  });

  it("clamps a controlled target index before selection and delivery", async () => {
    const onTargetSelect = vi.fn();
    const onSend = vi.fn().mockResolvedValue(true);
    render(
      <BufferSurface
        mode="ai"
        activeRequestID="request-1"
        phase="ready"
        selectedTarget={99}
        sourceText="source"
        targetContext={{
          requestID: "request-1",
          contextKey: bufferInputContextKey(
            "ai", "source", "zh-Hans", "en", "apple", 5, "balanced",
          ),
        }}
        targets={["only result"]}
        onSend={onSend}
        onTargetSelect={onTargetSelect}
      />,
    );

    await act(async () => {
      await Promise.resolve();
    });
    expect(onTargetSelect).toHaveBeenCalledWith(0, "only result");

    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "发送" }));
      await Promise.resolve();
    });
    expect(onSend.mock.calls[0]?.slice(0, 2)).toEqual(["only result", "ai"]);
  });
});

describe("External source inbox", () => {
  it("keeps exactly three menu destinations and supports inbox review", async () => {
    render(<PluginHarness />);
    const menu = screen.getByRole("menu", { name: "RIMES 输入法菜单" });
    expect(within(menu).getAllByRole("menuitem").map((item) => item.textContent)).toEqual([
      "设置…",
      "外部来源收件箱…（2 项待审）",
      "维护…",
    ]);

    fireEvent.click(within(menu).getByRole("menuitem", { name: "维护…" }));
    expect(within(menu).getByRole("menu", { name: "维护" })).toBeTruthy();
    expect(
      within(menu).getByRole("menuitem", { name: "关闭缓冲工作台（保留内容）" }),
    ).toBeTruthy();
    expect(
      within(menu).getByRole("menuitemcheckbox", {
        name: "剪贴板历史（⇧⌘V；仅工作台显示时读取）",
      }),
    ).toBeTruthy();

    fireEvent.click(within(menu).getByRole("menuitem", { name: /外部来源收件箱/ }));
    const dialog = screen.getByRole("dialog", { name: "外部来源收件箱" });
    expect(within(dialog).getByText("2 项待审")).toBeTruthy();

    fireEvent.click(within(dialog).getByRole("button", {
      name: "接受 Marine Chrome 内容并加入 Buffer",
    }));
    expect(within(dialog).getByText(/待审 1 · 已接受 1 · 已拒绝 0/)).toBeTruthy();
    expect(document.activeElement).toBe(
      within(dialog).getByRole("button", {
        name: "接受 配对设备 · iPhone 内容并加入 Buffer",
      }),
    );

    fireEvent.click(within(dialog).getByRole("button", {
      name: "接受 配对设备 · iPhone 内容并加入 Buffer",
    }));
    expect(document.activeElement).toBe(
      within(dialog).getByRole("button", { name: "加入模拟待审项" }),
    );

    fireEvent.click(within(dialog).getByRole("button", { name: "加入模拟待审项" }));
    expect(document.activeElement).toBe(
      within(dialog).getByRole("button", {
        name: "接受 Marine Chrome 内容并加入 Buffer",
      }),
    );

    fireEvent.keyDown(dialog, { key: "Escape" });
    expect(screen.queryByRole("dialog", { name: "外部来源收件箱" })).toBeNull();
  });

  it("closes the menu when focus moves to an outside pointer target", () => {
    render(<PluginHarness />);
    expect(screen.getByRole("menu", { name: "RIMES 输入法菜单" })).toBeTruthy();
    fireEvent.pointerDown(screen.getByRole("button", { name: "菜单外测试目标" }));
    expect(screen.queryByRole("menu", { name: "RIMES 输入法菜单" })).toBeNull();
  });

  it("closes the menu when keyboard focus tabs outside it", async () => {
    render(<PluginHarness />);
    const menu = screen.getByRole("menu", { name: "RIMES 输入法菜单" });
    const firstItem = within(menu).getByRole("menuitem", { name: "设置…" });
    firstItem.focus();
    fireEvent.keyDown(firstItem, { key: "Tab" });
    await act(() => new Promise<void>((resolve) => {
      window.requestAnimationFrame(() => resolve());
    }));
    expect(screen.queryByRole("menu", { name: "RIMES 输入法菜单" })).toBeNull();
    expect(document.activeElement).toBe(screen.getByRole("button", { name: "模拟故障" }));

    const trigger = screen.getByRole("button", { name: "中" });
    fireEvent.click(trigger);
    const reopenedMenu = screen.getByRole("menu", { name: "RIMES 输入法菜单" });
    const reopenedFirstItem = within(reopenedMenu).getByRole("menuitem", { name: "设置…" });
    reopenedFirstItem.focus();
    fireEvent.keyDown(reopenedFirstItem, { key: "Tab", shiftKey: true });
    await act(() => new Promise<void>((resolve) => {
      window.requestAnimationFrame(() => resolve());
    }));
    expect(document.activeElement).toBe(trigger);
  });
});

describe("Design lab configuration integration", () => {
  it("carries saved translation settings into the Buffer surface", () => {
    window.history.replaceState(null, "", "/?surface=extensions&theme=night");
    render(<App />);

    fireEvent.click(screen.getByRole("button", { name: "配置 实时翻译" }));
    const configurationDialog = screen.getByRole("dialog", { name: "实时翻译 设置" });
    const continuousSwitch = within(configurationDialog).getByRole("switch", {
      name: "连续翻译",
    });
    expect(continuousSwitch.getAttribute("aria-checked")).toBe("true");
    fireEvent.click(continuousSwitch);
    fireEvent.click(within(configurationDialog).getByRole("button", { name: "保存配置" }));
    fireEvent.click(within(configurationDialog).getByRole("button", {
      name: "关闭插件设置",
    }));

    fireEvent.click(screen.getByRole("button", { name: /^Buffer/ }));
    fireEvent.change(screen.getByRole("combobox", { name: "工作台插件" }), {
      target: { value: "translation" },
    });

    expect((screen.getByRole("combobox", { name: "源语言" }) as HTMLSelectElement).value)
      .toBe("auto");
    expect((screen.getByRole("combobox", { name: "目标语言" }) as HTMLSelectElement).value)
      .toBe("zh-Hans");
    expect(screen.getByRole("button", { name: "翻译" })).toBeTruthy();
  });

  it("moves accepted inbox content into the persistent Buffer draft", () => {
    window.history.replaceState(null, "", "/?surface=extensions&theme=night");
    render(<App />);

    fireEvent.click(screen.getByRole("menuitem", { name: /外部来源收件箱/ }));
    const dialog = screen.getByRole("dialog", { name: "外部来源收件箱" });
    fireEvent.click(within(dialog).getByRole("button", {
      name: "接受 Marine Chrome 内容并加入 Buffer",
    }));
    fireEvent.click(screen.getByRole("button", { name: /^Buffer/ }));
    const firstDraft = (screen.getByRole("textbox", { name: "缓冲正文" }) as HTMLInputElement).value;
    expect(firstDraft).toContain("请把这段缓冲内容整理为一段清晰的产品说明。");
    expect(firstDraft).toContain("[Marine Chrome] 把这一段加入 Buffer");

    fireEvent.click(screen.getByRole("button", { name: /扩展与菜单/ }));
    const persistentDialog = screen.getByRole("dialog", { name: "外部来源收件箱" });
    expect(within(persistentDialog).queryByRole("button", {
      name: "接受 Marine Chrome 内容并加入 Buffer",
    })).toBeNull();
    fireEvent.click(within(persistentDialog).getByRole("button", {
      name: "接受 配对设备 · iPhone 内容并加入 Buffer",
    }));
    fireEvent.click(screen.getByRole("button", { name: /^Buffer/ }));
    const secondDraft = (screen.getByRole("textbox", { name: "缓冲正文" }) as HTMLInputElement).value;
    expect(secondDraft).toContain("[Marine Chrome]");
    expect(secondDraft).toContain("[配对设备 · iPhone]");
  });

  it("keeps the Buffer draft when the workbench is closed and reopened", () => {
    window.history.replaceState(null, "", "/?surface=buffer&theme=night");
    render(<App />);
    const editor = screen.getByRole("textbox", { name: "缓冲正文" });
    fireEvent.change(editor, { target: { value: "保留这段草稿" } });
    fireEvent.click(screen.getByRole("button", { name: "关闭并暂停缓冲（保留内容）" }));
    fireEvent.click(screen.getByRole("button", { name: /^Buffer/ }));
    expect((screen.getByRole("textbox", { name: "缓冲正文" }) as HTMLInputElement).value)
      .toBe("保留这段草稿");
  });
});
