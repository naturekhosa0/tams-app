import { useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { useSession } from "../../auth/SessionProvider";
import { homeFor } from "../../components/navigation";
import { QrCode } from "../../components/QrCode";
import { Loading, Notice } from "../../components/ui";
import { formatDate } from "../../lib/format";
import { ptoDocument } from "../../registry/landApi";
import { LAND_TYPE_LABELS } from "../../registry/landTypes";
import type { PtoDocument } from "../../registry/landTypes";

/**
 * The permission itself, laid out to be printed or saved as a PDF by
 * the browser — which is all a document like this needs.
 *
 * It carries the holder's name and nothing else about them: no identity
 * number, no date of birth, no contact details.
 */
export function PtoDocumentPage() {
  const { ptoId = "" } = useParams();
  const { session, profile } = useSession();
  const home = homeFor(profile, Boolean(session));
  // A Land Officer came from the permissions list; a resident from
  // their own portal. Either way it is a link, never browser history.
  const isOfficer = profile?.role_name === "Land Officer";
  const backTo = isOfficer ? "/land/ptos" : "/resident";
  const backLabel = isOfficer ? "Back to permissions" : "Back to my land";
  const [document_, setDocument] = useState<PtoDocument | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    ptoDocument(ptoId).then((result) => {
      if (cancelled) return;
      if (result.ok) setDocument(result.data);
      else setError(result.message);
    });
    return () => { cancelled = true; };
  }, [ptoId]);

  if (error) {
    return (
      <div className="centre">
        <div className="centre-card narrow">
          <h1 style={{ fontSize: 22 }}>That permission is not available</h1>
          <div style={{ margin: "16px 0 20px" }}><Notice kind="error">{error}</Notice></div>
          <div className="row" style={{ justifyContent: "center" }}>
            <Link to={backTo} className="btn btn-primary">{backLabel}</Link>
            <Link to={home} className="btn btn-ghost">Go to my dashboard</Link>
          </div>
        </div>
      </div>
    );
  }
  if (!document_) return <Loading what="Loading the permission" />;

  const verificationUrl = `${window.location.origin}/verify/pto/${document_.verification_token}`;

  return (
    <div className="page">
      <div className="row-between no-print" style={{ marginBottom: 18 }}>
        <div className="row">
          <Link to={backTo} className="btn btn-ghost">← {backLabel}</Link>
          <Link to={home} className="btn btn-ghost">Home</Link>
        </div>
        <button type="button" className="btn btn-primary" onClick={() => window.print()}>
          Print or save as PDF
        </button>
      </div>

      <article className="certificate">
        <header className="certificate-head">
          <div className="brand-mark" aria-hidden="true">T</div>
          <div>
            <div className="certificate-authority">Traditional Authority</div>
            <h1>Permission to Occupy</h1>
            <div className="certificate-village">{document_.village_name ?? "Mhinga Village"}</div>
          </div>
          <div className="certificate-number">
            <div className="lineage-heading">PTO number</div>
            <div className="certificate-number-value">{document_.pto_number}</div>
          </div>
        </header>

        <section className="certificate-body">
          <div className="certificate-fields">
            <Field label="Held by" value={document_.holder_name} />
            {document_.household_code
              ? <Field label="Household" value={document_.household_code} />
              : null}
            <Field label="Land type" value={LAND_TYPE_LABELS[document_.land_type] ?? document_.land_type} />
            <Field label="Site code" value={document_.site_code} />
            {document_.stand_number ? <Field label="Stand number" value={document_.stand_number} /> : null}
            <Field label="Address" value={document_.street_address} />
            {document_.village_section ? <Field label="Village section" value={document_.village_section} /> : null}
            <Field label="Date of issue" value={formatDate(document_.issue_date)} />
            <Field
              label="Expiry"
              value={document_.perpetual ? "Perpetual — this permission does not expire"
                                         : formatDate(document_.expiry_date)}
            />
            <Field label="Status" value={
              document_.effective_status === "active" ? "Valid"
                : document_.effective_status.charAt(0).toUpperCase() + document_.effective_status.slice(1)
            } />
          </div>

          <div className="certificate-qr">
            <QrCode value={verificationUrl} size={148} />
            <div className="lineage-heading" style={{ marginTop: 10 }}>Verify this document</div>
            <div className="certificate-token">{document_.verification_token.slice(0, 16)}…</div>
            <p className="muted-note" style={{ marginTop: 8, fontSize: 11 }}>
              Scan the code, or go to {window.location.host}/verify/pto and enter the reference.
            </p>
          </div>
        </section>

        <footer className="certificate-foot">
          Issued by the Traditional Authority through the Traditional Authority Management System.
          This document records a permission to occupy land; it is not a title deed.
        </footer>
      </article>
    </div>
  );
}

function Field({ label, value }: { label: string; value: string }) {
  return (
    <div className="certificate-field">
      <div className="lineage-heading">{label}</div>
      <div className="certificate-value">{value}</div>
    </div>
  );
}
