import { useMemo } from "react";
import qrCodeGenerator from "qrcode-generator";

/**
 * A QR code drawn as inline SVG.
 *
 * Inline rather than a canvas or an image so it survives printing at
 * whatever size the paper wants, which is the whole point of putting it
 * on a permission to occupy.
 */
export function QrCode({ value, size = 140 }: { value: string; size?: number }) {
  const path = useMemo(() => {
    const code = qrCodeGenerator(0, "M");
    code.addData(value);
    code.make();

    const count = code.getModuleCount();
    const parts: string[] = [];
    for (let row = 0; row < count; row++) {
      for (let column = 0; column < count; column++) {
        if (code.isDark(row, column)) parts.push(`M${column} ${row}h1v1h-1z`);
      }
    }
    return { d: parts.join(""), count };
  }, [value]);

  return (
    <svg
      width={size}
      height={size}
      viewBox={`-1 -1 ${path.count + 2} ${path.count + 2}`}
      role="img"
      aria-label="QR code for verifying this permission to occupy"
      style={{ background: "#fff" }}
    >
      <rect x={-1} y={-1} width={path.count + 2} height={path.count + 2} fill="#fff" />
      <path d={path.d} fill="#000" />
    </svg>
  );
}
