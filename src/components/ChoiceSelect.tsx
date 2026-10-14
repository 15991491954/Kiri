import { useEffect, useId, useLayoutEffect, useRef, useState } from "react";
import type { CSSProperties, KeyboardEvent, ReactNode } from "react";
import { createPortal } from "react-dom";
import { Check, ChevronDown } from "lucide-react";
import "./ChoiceSelect.css";

export type ChoiceOption<T extends string = string> = { value: T; label: string; description?: string; trailing?: ReactNode };
export type ChoiceSelectProps<T extends string> = {
  value: T; onChange(value: T): void; options: ChoiceOption<T>[]; label: string;
  disabled?: boolean; className?: string; menuClassName?: string; menuMinWidth?: number;
  onOpen?(): void; menuHeader?: string; menuStatus?: string;
};

export function ChoiceSelect<T extends string>({ value, onChange, options, label, disabled = false,
  className = "", menuClassName = "", menuMinWidth = 280, onOpen, menuHeader, menuStatus }: ChoiceSelectProps<T>) {
  const [open, setOpen] = useState(false), [active, setActive] = useState<string>(value);
  const [position, setPosition] = useState<CSSProperties>({});
  const trigger = useRef<HTMLButtonElement>(null), menu = useRef<HTMLDivElement>(null);
  const id = useId();
  const selected = options.find(option => option.value === value) ?? options[0];
  const optionValues = JSON.stringify(options.map(option => option.value));
  function close(restore = false) { setOpen(false); if (restore) trigger.current?.focus(); }
  function show() {
    if (disabled || !options.length) return;
    onOpen?.(); setActive(selected.value); setOpen(true);
  }
  function choose(index: number) {
    const option = options[index]; if (!option) return;
    onChange(option.value); close(true);
  }
  useLayoutEffect(() => {
    if (!open) return;
    const place = () => {
      const rect = trigger.current?.getBoundingClientRect(); if (!rect) return;
      const width = Math.min(Math.max(rect.width, menuMinWidth), window.innerWidth - 16);
      const below = Math.max(0, window.innerHeight - rect.bottom - 12), above = Math.max(0, rect.top - 12);
      const up = below < Math.min(280, options.length * 70) && above > below;
      setPosition({ position: "fixed", width, left: Math.max(8, Math.min(rect.left, window.innerWidth - width - 8)),
        ...(up ? { bottom: window.innerHeight - rect.top + 5 } : { top: rect.bottom + 5 }),
        maxHeight: Math.min(360, up ? above : below) });
    };
    place(); window.addEventListener("resize", place); window.addEventListener("scroll", place, true);
    return () => { window.removeEventListener("resize", place); window.removeEventListener("scroll", place, true); };
  }, [open, options.length, menuMinWidth]);
  useLayoutEffect(() => {
    if (!open) return;
    if (!options.length) { close(true); return; }
    // Device refreshes can reorder/remove options while the menu is open.
    // Keep the focused value if possible; never leave keyboard focus on body.
    const index = Math.max(0, options.findIndex(option => option.value === active));
    if (options[index].value !== active) setActive(options[index].value);
    menu.current?.querySelectorAll<HTMLButtonElement>("[role=option]")[index]?.focus();
  }, [open, active, optionValues]);
  useEffect(() => {
    if (!open) return;
    const outside = (event: Event) => {
      const target = event.target as Node;
      if (!trigger.current?.contains(target) && !menu.current?.contains(target)) setOpen(false);
    };
    document.addEventListener("pointerdown", outside, true); document.addEventListener("focusin", outside);
    return () => { document.removeEventListener("pointerdown", outside, true); document.removeEventListener("focusin", outside); };
  }, [open]);
  useEffect(() => { if (disabled) setOpen(false); }, [disabled]);
  function navigate(event: KeyboardEvent) {
    if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); close(true); return; }
    const index = Math.max(0, options.findIndex(option => option.value === active));
    const delta = event.key === "ArrowDown" ? 1 : event.key === "ArrowUp" ? -1 : 0;
    if (delta && options.length) {
      event.preventDefault(); event.stopPropagation(); setActive(options[(index + delta + options.length) % options.length].value);
    } else if (event.key === "Home" || event.key === "End") {
      event.preventDefault(); event.stopPropagation(); setActive(options[event.key === "Home" ? 0 : options.length - 1]?.value ?? "");
    } else if (event.key === "Enter" || event.key === " ") {
      event.preventDefault(); event.stopPropagation(); choose(index);
    }
  }
  return <><button ref={trigger} type="button" className={`kiri-choice-trigger ${className}`} disabled={disabled}
    title={selected?.label} aria-label={label} aria-haspopup="listbox" aria-expanded={open} aria-controls={open ? id : undefined}
    onClick={() => open ? close() : show()} onKeyDown={event => {
      if (open && event.key === "Escape") { navigate(event); return; }
      if (["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)) {
        event.preventDefault(); event.stopPropagation(); show();
        if (event.key === "End") setActive(options[options.length - 1]?.value ?? "");
        if (event.key === "Home") setActive(options[0]?.value ?? "");
      }
    }}>
    <span className="kiri-choice-trigger-label">{selected?.label}</span>
    {selected?.trailing && <span className="kiri-choice-trailing">{selected.trailing}</span>}<ChevronDown size={14} />
  </button>{open && createPortal(<div ref={menu} id={id} role="listbox" aria-label={label}
    className={`kiri-choice-menu ${menuClassName}`} style={position} onKeyDown={navigate}>
    {menuHeader && <div className="kiri-choice-menu-header">{menuHeader}</div>}
    {options.map((option, index) => <button type="button" role="option" key={option.value} tabIndex={option.value === active ? 0 : -1}
      aria-selected={option.value === value} className="kiri-choice-option" onClick={() => choose(index)} onFocus={() => setActive(option.value)}>
      <span className="kiri-choice-option-copy"><span className="kiri-choice-option-title">{option.label}</span>
        {option.description && <span className="kiri-choice-description">{option.description}</span>}</span>
      {option.trailing && <span className="kiri-choice-trailing">{option.trailing}</span>}<Check size={14} className={option.value === value ? "" : "kiri-choice-check-hidden"} />
    </button>)}
    {menuStatus && <div className="kiri-choice-menu-status" role="status">{menuStatus}</div>}
  </div>, document.body)}</>;
}
