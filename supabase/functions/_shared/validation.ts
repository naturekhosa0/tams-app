// Shared field validation. The same rules are enforced again by check
// constraints in the database, so a malformed request cannot slip past
// by calling the database directly.

export type StaffDetails = {
  employee_number: string;
  first_name: string;
  last_name: string;
  email: string;
  contact_number: string;
};

const EMAIL_PATTERN = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const CONTACT_PATTERN = /^[0-9+][0-9 ()+-]{8,19}$/;

export function validateStaffDetails(input: Record<string, unknown>): {
  values?: StaffDetails;
  errors: Record<string, string>;
} {
  const errors: Record<string, string> = {};
  const text = (key: string) =>
    typeof input[key] === "string" ? (input[key] as string).trim() : "";

  const employee_number = text("employee_number");
  const first_name = text("first_name");
  const last_name = text("last_name");
  const email = text("email").toLowerCase();
  const contact_number = text("contact_number");

  if (!employee_number) errors.employee_number = "Employee number is required.";
  else if (employee_number.length > 30) errors.employee_number = "Employee number is too long.";

  if (!first_name) errors.first_name = "First name is required.";
  if (!last_name) errors.last_name = "Surname is required.";

  if (!email) errors.email = "Email address is required.";
  else if (!EMAIL_PATTERN.test(email)) errors.email = "Enter a valid email address.";

  if (!contact_number) errors.contact_number = "Contact number is required.";
  else if (!CONTACT_PATTERN.test(contact_number)) {
    errors.contact_number = "Enter a valid contact number (at least 9 digits).";
  }

  if (Object.keys(errors).length > 0) return { errors };
  return {
    values: { employee_number, first_name, last_name, email, contact_number },
    errors: {},
  };
}

export function isUuid(value: unknown): value is string {
  return typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
}
