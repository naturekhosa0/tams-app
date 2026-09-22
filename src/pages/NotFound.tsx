import { Link } from "react-router-dom";
import { useSession } from "../auth/SessionProvider";
import { homeFor } from "../components/navigation";
import { AuthShell } from "../components/AuthShell";

/**
 * An address that leads nowhere. It still has to lead somewhere: home
 * means this person's own home, not a page they would only be turned
 * away from.
 */
export function NotFound() {
  const { session, profile } = useSession();
  const home = homeFor(profile, Boolean(session));

  return (
    <AuthShell
      title="That page could not be found"
      intro="The address may have been mistyped, or the page may have been renamed."
      showHome={false}
      footer={
        <div className="row" style={{ justifyContent: "center" }}>
          <Link to={home} className="btn btn-primary">
            {session ? "Go to my dashboard" : "Go to home"}
          </Link>
          {!session ? <Link to="/auth" className="btn btn-ghost">Sign in</Link> : null}
        </div>
      }
    >
      <div />
    </AuthShell>
  );
}
