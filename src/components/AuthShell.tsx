import type { ReactNode } from "react";
import { Link } from "react-router-dom";

/**
 * The frame for every page somebody can reach without signing in, and
 * for the ones they reach while signing in.
 *
 * It exists for one reason: none of those pages may be a dead end. The
 * TAMS name goes home, and each page says what else it can offer.
 */
export function AuthShell({
  title, intro, children, footer, width = "narrow", showHome = true,
}: {
  title: string;
  intro?: ReactNode;
  children: ReactNode;
  footer?: ReactNode;
  width?: "narrow" | "wide";
  showHome?: boolean;
}) {
  return (
    <div className="centre">
      <div className={`centre-card ${width}`}>
        <Link to="/" className="brand brand-link" aria-label="TAMS home">
          <div className="brand-mark" aria-hidden="true">T</div>
          <div>
            <div className="brand-name">TAMS</div>
            <div className="brand-sub">Traditional Authority</div>
          </div>
        </Link>

        {showHome ? <Link to="/" className="back-link" style={{ marginTop: 20 }}>← Back to home</Link> : null}

        <h1 style={{ fontSize: 24, marginTop: showHome ? 12 : 24 }}>{title}</h1>
        {intro ? <p className="auth-intro">{intro}</p> : null}

        {children}

        {footer ? <div className="auth-footer">{footer}</div> : null}
      </div>
    </div>
  );
}
