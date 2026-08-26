import { useMemo, useState } from "react";
import { Badge, Button, MacWindow } from "../design-system/primitives";

export type MailboxMessage = {
  id: string;
  role: "inbound" | "user" | "system";
  author: string;
  body: string;
  time: string;
};

export type MailboxThread = {
  id: string;
  dateLabel: string;
  sequence: string;
  source: string;
  preview: string;
  messages: readonly MailboxMessage[];
};

export const MAILBOX_THREADS: readonly MailboxThread[] = [
  {
    id: "thread-today-03",
    dateLabel: "今天",
    sequence: "#03",
    source: "Claude Code",
    preview: "请把这段说明改成发布公告…",
    messages: [
      {
        id: "m1",
        role: "system",
        author: "Mailbox",
        body: "来自本地网关的新推送已进入会话，等待你确认。",
        time: "10:42",
      },
      {
        id: "m2",
        role: "inbound",
        author: "Claude Code",
        body: "请把这段说明改成发布公告：\nRIMES 0.5 增加了窗口化 Mailbox，外部草稿先在这里审阅，再进入 Buffer。",
        time: "10:42",
      },
      {
        id: "m3",
        role: "user",
        author: "你",
        body: "先保留原文，再给我一个更短的标题。",
        time: "10:44",
      },
      {
        id: "m4",
        role: "inbound",
        author: "Claude Code",
        body: "标题候选：\n1. RIMES 0.5：窗口化 Mailbox\n2. 外部草稿先审后发",
        time: "10:44",
      },
    ],
  },
  {
    id: "thread-today-02",
    dateLabel: "今天",
    sequence: "#02",
    source: "Codex",
    preview: "补一段安装后的验收清单…",
    messages: [
      {
        id: "m5",
        role: "inbound",
        author: "Codex",
        body: "补一段安装后的验收清单：打开设置 › 窗口 › Mailbox，确认双栏会话可切换。",
        time: "09:18",
      },
      {
        id: "m6",
        role: "system",
        author: "Mailbox",
        body: "已标记为待加入 Buffer。",
        time: "09:20",
      },
    ],
  },
  {
    id: "thread-yesterday-01",
    dateLabel: "昨天",
    sequence: "#01",
    source: "HTTP Push",
    preview: "会议纪要草稿已到达…",
    messages: [
      {
        id: "m7",
        role: "inbound",
        author: "HTTP Push",
        body: "会议纪要草稿已到达。主题：跨平台预览打包；结论：先冻结 Mailbox 交互稿。",
        time: "18:05",
      },
      {
        id: "m8",
        role: "user",
        author: "你",
        body: "接受，稍后发到 Buffer。",
        time: "18:07",
      },
      {
        id: "m9",
        role: "system",
        author: "Mailbox",
        body: "已接受。内容仍留在本会话，不会自动上屏。",
        time: "18:07",
      },
    ],
  },
];

export type MailboxPaneProps = {
  className?: string;
  selectedThreadID?: string;
  onSelectedThreadChange?: (threadID: string) => void;
  onActivity?: (message: string) => void;
};

export function MailboxPane({
  className = "",
  selectedThreadID,
  onSelectedThreadChange,
  onActivity,
}: MailboxPaneProps) {
  const [internalSelectedID, setInternalSelectedID] = useState(
    MAILBOX_THREADS[0]?.id ?? "",
  );
  const resolvedSelectedID = selectedThreadID ?? internalSelectedID;
  const selectedThread = MAILBOX_THREADS.find((thread) => thread.id === resolvedSelectedID)
    ?? MAILBOX_THREADS[0];

  const mailboxGroups = useMemo(() => MAILBOX_THREADS.reduce<
    { dateLabel: string; threads: MailboxThread[] }[]
  >((groups, thread) => {
    const current = groups[groups.length - 1];
    if (current?.dateLabel === thread.dateLabel) {
      current.threads.push(thread);
      return groups;
    }
    groups.push({ dateLabel: thread.dateLabel, threads: [thread] });
    return groups;
  }, []), []);

  const selectThread = (thread: MailboxThread) => {
    if (selectedThreadID === undefined) setInternalSelectedID(thread.id);
    onSelectedThreadChange?.(thread.id);
    onActivity?.(`已打开 ${thread.dateLabel} ${thread.sequence}`);
  };

  return (
    <div
      aria-label="Mailbox 双栏预览"
      className={`mailbox-pane${className ? ` ${className}` : ""}`}
    >
      <aside className="mailbox-pane__index" aria-label="会话列表">
        {mailboxGroups.map((group) => (
          <div className="mailbox-index-group" key={group.dateLabel}>
            <div className="mailbox-index-group__date">{group.dateLabel}</div>
            {group.threads.map((thread) => (
              <button
                aria-current={selectedThread?.id === thread.id ? "true" : undefined}
                className={`mailbox-index-item${selectedThread?.id === thread.id ? " is-selected" : ""}`}
                key={thread.id}
                onClick={() => selectThread(thread)}
                type="button"
              >
                <span className="mailbox-index-item__seq">{thread.sequence}</span>
                <span className="mailbox-index-item__copy">
                  <strong>{thread.source}</strong>
                  <small>{thread.preview}</small>
                </span>
              </button>
            ))}
          </div>
        ))}
      </aside>

      <section
        aria-label={selectedThread
          ? `${selectedThread.dateLabel} ${selectedThread.sequence} 对话`
          : "对话内容"}
        className="mailbox-pane__chat"
      >
        {selectedThread ? (
          <>
            <header className="mailbox-chat__header">
              <span>
                <strong>{selectedThread.source}</strong>
                <small>{selectedThread.dateLabel} · {selectedThread.sequence}</small>
              </span>
              <Badge tone="accent">会话</Badge>
            </header>
            <div className="mailbox-chat__transcript" role="log">
              {selectedThread.messages.map((message) => (
                <article
                  className={`mailbox-bubble mailbox-bubble--${message.role}`}
                  key={message.id}
                >
                  <header className="mailbox-bubble__meta">
                    <strong>{message.author}</strong>
                    <time>{message.time}</time>
                  </header>
                  <p>{message.body}</p>
                </article>
              ))}
            </div>
            <footer className="mailbox-chat__composer" aria-label="回复草稿">
              <input
                aria-label="写入回复"
                className="r-text-input"
                placeholder="回复或备注…（设计预览）"
                readOnly
                type="text"
              />
              <Button
                icon="send"
                kind="secondary"
                onClick={() => onActivity?.("设计预览：回复不会真正发送")}
              >
                发送
              </Button>
            </footer>
          </>
        ) : (
          <div className="mailbox-chat__empty">选择左侧会话以查看内容</div>
        )}
      </section>
    </div>
  );
}

export type MailboxSurfaceProps = {
  onActivity?: (message: string) => void;
  onClose?: () => void;
};

export function MailboxSurface({
  onActivity,
  onClose,
}: MailboxSurfaceProps) {
  return (
    <div className="mailbox-surface">
      <MacWindow
        className="mailbox-window"
        title="RIMES Mailbox"
        toolbar={(
          <span className="mailbox-window__shortcut" title="唤出快捷键">
            ⌘⇧M
          </span>
        )}
      >
        <div className="mailbox-surface__body">
          <header className="mailbox-surface__heading">
            <span>
              <strong>Mailbox</strong>
              <small>外部推送会话窗口 · 快捷键 ⌘⇧M</small>
            </span>
            {onClose ? (
              <Button kind="ghost" onClick={onClose}>关闭</Button>
            ) : null}
          </header>
          <MailboxPane
            className="mailbox-pane--surface"
            onActivity={onActivity}
          />
        </div>
      </MacWindow>
    </div>
  );
}
