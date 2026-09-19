import { BrowserRouter, Navigate, Route, Routes } from "react-router-dom";
import { SessionProvider } from "./auth/SessionProvider";
import { RequireAdministrator, RequireStaff } from "./components/guards";
import { isConfigured } from "./lib/supabaseClient";
import { Landing } from "./pages/Landing";
import { SignIn } from "./pages/SignIn";
import { SetPassword } from "./pages/SetPassword";
import { AdminDashboard } from "./pages/AdminDashboard";
import { StaffAccounts } from "./pages/StaffAccounts";
import { CreateStaffAccount } from "./pages/CreateStaffAccount";
import { StaffHome } from "./pages/StaffHome";
import { NoAccess } from "./pages/NoAccess";
import { Notice } from "./components/ui";

function NotConfigured() {
  return (
    <div className="centre">
      <div className="centre-card narrow">
        <h1 style={{ fontSize: 22 }}>TAMS is not connected yet</h1>
        <div style={{ marginTop: 16 }}>
          <Notice kind="info">
            Copy <code>.env.example</code> to <code>.env</code> and fill in{" "}
            <code>VITE_SUPABASE_URL</code> and <code>VITE_SUPABASE_ANON_KEY</code> from your
            Supabase project, then restart the development server.
          </Notice>
        </div>
      </div>
    </div>
  );
}

export default function App() {
  if (!isConfigured) return <NotConfigured />;

  return (
    <SessionProvider>
      <BrowserRouter>
        <Routes>
          <Route path="/" element={<Landing />} />
          <Route path="/auth" element={<SignIn />} />
          <Route path="/set-password" element={<SetPassword />} />
          <Route path="/no-access" element={<NoAccess />} />

          {/* Any active staff member */}
          <Route path="/home" element={<RequireStaff><StaffHome /></RequireStaff>} />

          {/* The active Council Administrator only */}
          <Route path="/dashboard" element={<RequireAdministrator><AdminDashboard /></RequireAdministrator>} />
          <Route path="/staff" element={<RequireAdministrator><StaffAccounts /></RequireAdministrator>} />
          <Route path="/staff/new" element={<RequireAdministrator><CreateStaffAccount /></RequireAdministrator>} />

          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </BrowserRouter>
    </SessionProvider>
  );
}
