import { Link, Navigate, useNavigate } from "react-router-dom";
import { homePathFor, useSession } from "../auth/SessionProvider";
import { Loading } from "../components/ui";

export function Landing() {
  const { loading, session, profile } = useSession();
  const navigate = useNavigate();

  if (loading) return <Loading />;
  if (session) return <Navigate to={homePathFor(profile)} replace />;

  return (
    <div className="centre">
      <div className="centre-card wide">
        <div className="brand">
          <div className="brand-mark" aria-hidden="true">T</div>
          <div>
            <div className="brand-name">TAMS</div>
            <div className="brand-sub">Traditional Authority</div>
          </div>
        </div>

        <h1>Traditional Authority<br />Management System</h1>
        <p>
          The traditional authority's records: the village register, land and permissions to
          occupy, the council's own minutes and resolutions, and what the community is told.
        </p>

        <div className="row">
          <button type="button" className="btn btn-primary" onClick={() => navigate("/auth")}>
            Sign in
          </button>
          <button type="button" className="btn btn-ghost" onClick={() => navigate("/register")}>
            Create a resident account
          </button>
        </div>

        <div className="landing-links">
          <p>
            <strong>Staff</strong> — the Council Administrator creates your account and invites
            you by email. <Link to="/auth">Sign in</Link> once you have set your password.
          </p>
          <p>
            <strong>Residents</strong> — <Link to="/register">create an account</Link>, send your
            details to be verified, and then apply for land and read the community updates.
          </p>
          <p>
            <strong>Checking a permission to occupy?</strong>{" "}
            <Link to="/verify/pto">Verify a PTO</Link> using the reference on the document, or
            scan the code printed on it. You do not need an account.
          </p>
        </div>
      </div>
    </div>
  );
}
