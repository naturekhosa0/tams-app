import type { ReactNode } from "react";
import { Link } from "react-router-dom";

export type Crumb = { label: string; to?: string };

/**
 * The same header on every page: where you are, how you got here, how
 * you go back, and the one thing this page is chiefly for.
 *
 * `back` is the contextual way out — the list a detail page came from —
 * and is separate from the navigation, which is always there anyway.
 */
export function PageHead({
  title, description, crumbs, back, actions,
}: {
  title: string;
  description?: ReactNode;
  crumbs?: Crumb[];
  back?: { to: string; label: string };
  actions?: ReactNode;
}) {
  return (
    <div className="page-head">
      {crumbs && crumbs.length > 0
        ? (
          <nav className="crumbs" aria-label="Breadcrumb">
            {crumbs.map((crumb, index) => (
              <span key={`${crumb.label}-${index}`}>
                {crumb.to
                  ? <Link to={crumb.to}>{crumb.label}</Link>
                  : <span aria-current="page">{crumb.label}</span>}
                {index < crumbs.length - 1 ? <span className="crumb-sep" aria-hidden="true">›</span> : null}
              </span>
            ))}
          </nav>
        )
        : null}

      {back ? <Link to={back.to} className="back-link">← {back.label}</Link> : null}

      <div className="row-between">
        <div>
          <h1>{title}</h1>
          {description ? <p>{description}</p> : null}
        </div>
        {actions ? <div className="row">{actions}</div> : null}
      </div>
    </div>
  );
}
