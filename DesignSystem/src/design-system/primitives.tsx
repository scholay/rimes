import { useId, type ButtonHTMLAttributes, type PropsWithChildren, type ReactNode } from "react";
import { Icon, type IconName } from "./Icon";

export function IconButton({
  icon,
  label,
  selected = false,
  className = "",
  ...props
}: ButtonHTMLAttributes<HTMLButtonElement> & {
  icon: IconName;
  label: string;
  selected?: boolean;
}) {
  return (
    <button
      aria-label={label}
      className={`r-icon-button${selected ? " is-selected" : ""}${className ? ` ${className}` : ""}`}
      title={label}
      type="button"
      {...props}
    >
      <Icon name={icon} size={16} weight={selected ? "bold" : "regular"} />
    </button>
  );
}

export function Button({
  icon,
  kind = "secondary",
  className = "",
  children,
  ...props
}: ButtonHTMLAttributes<HTMLButtonElement> & {
  icon?: IconName;
  kind?: "primary" | "secondary" | "ghost" | "danger";
}) {
  return (
    <button className={`r-button r-button--${kind}${className ? ` ${className}` : ""}`} type="button" {...props}>
      {icon ? <Icon name={icon} size={15} weight="bold" /> : null}
      <span>{children}</span>
    </button>
  );
}

export function Switch({
  checked,
  onChange,
  label,
  disabled = false,
}: {
  checked: boolean;
  onChange: (next: boolean) => void;
  label: string;
  disabled?: boolean;
}) {
  return (
    <button
      aria-checked={checked}
      aria-label={label}
      className={`r-switch${checked ? " is-on" : ""}`}
      disabled={disabled}
      onClick={() => onChange(!checked)}
      role="switch"
      title={label}
      type="button"
    >
      <span className="r-switch__thumb" />
    </button>
  );
}

export function Segmented<T extends string>({
  value,
  options,
  onChange,
  ariaLabel,
}: {
  value: T;
  options: readonly { value: T; label: string }[];
  onChange: (value: T) => void;
  ariaLabel: string;
}) {
  return (
    <div aria-label={ariaLabel} className="r-segmented" role="group">
      {options.map((option) => (
        <button
          aria-pressed={value === option.value}
          className={value === option.value ? "is-selected" : ""}
          key={option.value}
          onClick={() => onChange(option.value)}
          type="button"
        >
          {option.label}
        </button>
      ))}
    </div>
  );
}

export function SelectButton({
  children,
  onClick,
  className = "",
}: PropsWithChildren<{ onClick?: () => void; className?: string }>) {
  return (
    <button className={`r-select ${className}`} onClick={onClick} type="button">
      <span>{children}</span>
      <Icon name="down" size={12} weight="bold" />
    </button>
  );
}

export function MacWindow({
  title,
  children,
  className = "",
  toolbar,
}: PropsWithChildren<{ title: string; className?: string; toolbar?: ReactNode }>) {
  return (
    <section className={`mac-window ${className}`}>
      <header className="mac-window__titlebar">
        <div aria-hidden="true" className="mac-window__traffic">
          <Icon name="circle" size={13} weight="fill" />
          <Icon name="circle" size={13} weight="fill" />
          <Icon name="circle" size={13} weight="fill" />
        </div>
        <strong>{title}</strong>
        <div className="mac-window__toolbar">{toolbar}</div>
      </header>
      {children}
    </section>
  );
}

export function Badge({ children, tone = "neutral" }: PropsWithChildren<{ tone?: "neutral" | "accent" | "warning" }>) {
  return <span className={`r-badge r-badge--${tone}`}>{children}</span>;
}

export function Field({
  label,
  hint,
  children,
}: PropsWithChildren<{ label: string; hint?: string }>) {
  const labelID = useId();
  return (
    <div className="r-field">
      <span className="r-field__label" id={labelID}>{label}</span>
      <span aria-labelledby={labelID} className="r-field__control" role="group">{children}</span>
      {hint ? <span className="r-field__hint">{hint}</span> : null}
    </div>
  );
}
