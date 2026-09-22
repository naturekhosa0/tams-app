import { useEffect, useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { Loading, Notice } from "../../components/ui";
import { formatDate } from "../../lib/format";
import { verifyPto } from "../../registry/landApi";
import { LAND_TYPE_LABELS } from "../../registry/landTypes";
import type { PtoVerification } from "../../registry/landTypes";

const STATUS_WORDS: Record<string, { label: string; kind: "success" | "error" | "info" }> = {
  active:     { label: "Valid", kind: "success" },
  expired:    { label: "Expired", kind: "error" },
  revoked:    { label: "Revoked", kind: "error" },
  renewed:    { label: "Replaced by a renewal", kind: "info" },
  superseded: { label: "Superseded", kind: "info" },
};

/**
 * The page a QR code leads to. Anybody may open it — that is what makes
 * a printed permission checkable.
 *
 * It says only enough to establish that the document is genuine: no
 * identity number, no date of birth, no contact details, and no
 * internal identifiers.
 */
export function VerifyPto() {
  const { token = "" } = useParams();
  const navigate = useNavigate();
  const [result, setResult] = useState<PtoVerification | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [typed, setTyped] = useState("");

  useEffect(() => {
    if (!token) { setResult(null); setError(null); return; }
    let cancelled = false;
    verifyPto(token).then((response) => {
      if (cancelled) return;
      if (response.ok) setResult(response.data);
      else setError(response.message);
    });
    return () => { cancelled = true; };
  }, [token]);

  return (
    <div className="centre">
      <div className="centre-card narrow">
        <Link to="/" className="brand brand-link" aria-label="TAMS home">
          <div className="brand-mark" aria-hidden="true">T</div>
          <div>
            <div className="brand-name">TAMS</div>
            <div className="brand-sub">Traditional Authority</div>
          </div>
        </Link>

        <Link to="/" className="back-link" style={{ marginTop: 20 }}>← Back to TAMS home</Link>

        <h1 style={{ fontSize: 24, marginTop: 12 }}>Permission to occupy</h1>

        {error ? <div style={{ marginTop: 16 }}><Notice kind="error">{error}</Notice></div> : null}
        {token && !result && !error ? <Loading what="Checking" /> : null}

        {!token
          ? (
            <form
              style={{ marginTop: 18 }}
              onSubmit={(event) => {
                event.preventDefault();
                const value = typed.trim();
                if (value) navigate(`/verify/pto/${encodeURIComponent(value)}`);
              }}
            >
              <p className="auth-intro">
                Enter the verification reference printed on the document, or scan the code on it.
                Anybody may check a permission; no account is needed.
              </p>
              <div className="input-with-button">
                <input value={typed} aria-label="Verification reference"
                       placeholder="Reference from the document"
                       onChange={(event) => setTyped(event.target.value)} />
                <button type="submit" className="btn btn-primary" disabled={!typed.trim()}>
                  Check
                </button>
              </div>
            </form>
          )
          : null}

        {result && !result.found
          ? (
            <div style={{ marginTop: 16 }}>
              <Notice kind="error">
                No permission to occupy matches this code. It may have been mistyped, or the
                document may not be genuine.
              </Notice>
            </div>
          )
          : null}

        {result && result.found
          ? (
            <>
              <div style={{ margin: "16px 0 20px" }}>
                <Notice kind={STATUS_WORDS[result.status]?.kind ?? "info"}>
                  <strong>{STATUS_WORDS[result.status]?.label ?? result.status}</strong>
                  {result.status === "expired" ? " — this permission has passed its expiry date." : ""}
                  {result.status === "revoked" ? " — this permission was withdrawn." : ""}
                  {result.status === "active" ? " — this is a genuine, current permission to occupy." : ""}
                </Notice>
              </div>

              <div className="detail-list">
                <div className="detail-item">
                  <span className="label">PTO number</span>
                  <span className="value">{result.pto_number}</span>
                </div>
                <div className="detail-item">
                  <span className="label">Held by</span>
                  <span className="value">{result.holder_name}</span>
                </div>
                <div className="detail-item">
                  <span className="label">Land type</span>
                  <span className="value">{LAND_TYPE_LABELS[result.land_type] ?? result.land_type}</span>
                </div>
                <div className="detail-item">
                  <span className="label">Site</span>
                  <span className="value">{result.site_code}</span>
                </div>
                {result.village_section || result.village_name
                  ? (
                    <div className="detail-item">
                      <span className="label">Location</span>
                      <span className="value">
                        {[result.village_section, result.village_name].filter(Boolean).join(", ")}
                      </span>
                    </div>
                  )
                  : null}
                <div className="detail-item">
                  <span className="label">Issued</span>
                  <span className="value">{formatDate(result.issue_date)}</span>
                </div>
                <div className="detail-item">
                  <span className="label">Expires</span>
                  <span className="value">
                    {result.perpetual ? "Perpetual" : formatDate(result.expiry_date)}
                  </span>
                </div>
              </div>

              <p className="muted-note" style={{ marginTop: 18 }}>
                Checked against the Traditional Authority's records just now.
              </p>
            </>
          )
          : null}

        {token
          ? (
            <div className="auth-footer">
              <div className="row" style={{ justifyContent: "center" }}>
                <Link to="/verify/pto" className="btn btn-ghost">Verify another PTO</Link>
                <Link to="/" className="btn btn-ghost">Back to TAMS home</Link>
              </div>
            </div>
          )
          : null}
      </div>
    </div>
  );
}
