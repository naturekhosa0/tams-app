import { Navigate, useNavigate } from "react-router-dom";
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
          A clean foundation for the traditional authority's internal records. Sign in to the
          workspace — the record pages will be built on this same look.
        </p>

        <button type="button" className="btn btn-primary" onClick={() => navigate("/auth")}>
          Sign in
        </button>
      </div>
    </div>
  );
}
