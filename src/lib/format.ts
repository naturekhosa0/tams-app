/** 17 Sept 2026 */
export function formatDate(value: string | null): string {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "—";
  return new Intl.DateTimeFormat("en-ZA", {
    day: "numeric",
    month: "short",
    year: "numeric",
  }).format(date);
}

/** 17 Sept 2026 at 14:05 */
export function formatDateTime(value: string | null): string {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "—";
  return `${formatDate(value)} at ${
    new Intl.DateTimeFormat("en-ZA", { hour: "2-digit", minute: "2-digit", hour12: false }).format(date)
  }`;
}

export function initialsOf(name: string | null, fallback: string): string {
  const source = (name ?? fallback).trim();
  if (!source) return "??";
  const parts = source.split(/[\s@.]+/).filter(Boolean);
  const letters = parts.length >= 2 ? parts[0][0] + parts[1][0] : source.slice(0, 2);
  return letters.toUpperCase();
}
