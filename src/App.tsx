import { BrowserRouter, Navigate, Route, Routes } from "react-router-dom";
import { SessionProvider } from "./auth/SessionProvider";
import { RequireAdministrator, RequireRegistryClerk, RequireStaff } from "./components/guards";
import { isConfigured } from "./lib/supabaseClient";
import { Landing } from "./pages/Landing";
import { SignIn } from "./pages/SignIn";
import { SetPassword } from "./pages/SetPassword";
import { AdminDashboard } from "./pages/AdminDashboard";
import { StaffAccounts } from "./pages/StaffAccounts";
import { CreateStaffAccount } from "./pages/CreateStaffAccount";
import { StaffHome } from "./pages/StaffHome";
import { NoAccess } from "./pages/NoAccess";
import { RegistryDashboard } from "./pages/registry/RegistryDashboard";
import { Residents } from "./pages/registry/Residents";
import { ResidentDetail } from "./pages/registry/ResidentDetail";
import { ResidentForm } from "./pages/registry/ResidentForm";
import { Households } from "./pages/registry/Households";
import { HouseholdDetail } from "./pages/registry/HouseholdDetail";
import { FamilyLineage } from "./pages/registry/FamilyLineage";
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

          {/* The active Registry Clerk only */}
          <Route path="/registry" element={<RequireRegistryClerk><RegistryDashboard /></RequireRegistryClerk>} />
          <Route path="/registry/residents" element={<RequireRegistryClerk><Residents /></RequireRegistryClerk>} />
          <Route path="/registry/residents/new" element={<RequireRegistryClerk><ResidentForm mode="create" /></RequireRegistryClerk>} />
          <Route path="/registry/residents/:residentId" element={<RequireRegistryClerk><ResidentDetail /></RequireRegistryClerk>} />
          <Route path="/registry/residents/:residentId/edit" element={<RequireRegistryClerk><ResidentForm mode="update" /></RequireRegistryClerk>} />
          <Route path="/registry/households" element={<RequireRegistryClerk><Households /></RequireRegistryClerk>} />
          <Route path="/registry/households/:householdId" element={<RequireRegistryClerk><HouseholdDetail /></RequireRegistryClerk>} />
          <Route path="/registry/lineage" element={<RequireRegistryClerk><FamilyLineage /></RequireRegistryClerk>} />
          <Route path="/registry/lineage/:residentId" element={<RequireRegistryClerk><FamilyLineage /></RequireRegistryClerk>} />

          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </BrowserRouter>
    </SessionProvider>
  );
}
