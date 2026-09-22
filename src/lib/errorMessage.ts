// =====================================================================
// Turning a refusal into a sentence.
//
// Almost every refusal in TAMS is deliberate: a database function
// raises with wording written for whoever is looking at the screen, and
// that wording is what should be shown. This exists for the rest — the
// failures nobody wrote, where PostgreSQL or PostgREST says something
// true but unreadable.
//
// Nobody using TAMS should ever see the words "violates unique
// constraint", a SQLSTATE, a relation name or a stack trace.
// =====================================================================

/** A SQLSTATE and its leading colon, which Supabase sometimes prepends. */
const SQLSTATE_PREFIX = /^[A-Z0-9]{5}:\s*/;

/** Anything that reads as the database talking to a developer. */
const RAW_DATABASE_SHAPES = [
  /violates (unique|foreign key|check|not-null) constraint/i,
  /duplicate key value/i,
  /relation "[^"]+" does not exist/i,
  /column "[^"]+" (of relation|does not exist)/i,
  /function [\w.]+\([^)]*\) does not exist/i,
  /invalid input syntax for/i,
  /syntax error at or near/i,
  /permission denied for (table|relation|function|schema)/i,
  /could not serialize access/i,
  /deadlock detected/i,
  /^JSON object requested/i,
  /schema cache/i,
  /\bpg_\w+/,
  /\bSQLSTATE\b/i,
  /^\s*at\s+\w+.*\(.*:\d+:\d+\)/m,
];

/** What to say instead, for the shapes worth naming. */
const FRIENDLY: { when: RegExp; say: string }[] = [
  {
    when: /duplicate key value|violates unique constraint/i,
    say: "That would duplicate a record that already exists. Check the reference or identity number and try again.",
  },
  {
    when: /violates foreign key constraint/i,
    say: "That refers to a record that is no longer there. Reload the page and try again.",
  },
  {
    when: /violates not-null constraint/i,
    say: "Something required was left out. Check the form and try again.",
  },
  {
    when: /violates check constraint/i,
    say: "That value is not one TAMS accepts here. Check the form and try again.",
  },
  {
    when: /could not serialize access|deadlock detected/i,
    say: "Somebody else changed this at the same moment. Reload the page and try again.",
  },
  {
    when: /permission denied for/i,
    say: "Your role does not allow that. Ask the Council Administrator if this looks wrong.",
  },
];

export const GENERIC_FAILURE = "That could not be completed. Please try again.";

/**
 * The sentence to put on screen for a refusal.
 *
 * Wording TAMS wrote is passed through untouched. Wording the database
 * wrote is replaced, because it was written for somebody reading a log.
 */
export function readableError(raw: string | null | undefined): string {
  const message = (raw ?? "").replace(SQLSTATE_PREFIX, "").trim();
  if (!message) return GENERIC_FAILURE;

  for (const { when, say } of FRIENDLY) {
    if (when.test(message)) return say;
  }
  if (RAW_DATABASE_SHAPES.some((shape) => shape.test(message))) return GENERIC_FAILURE;

  return message;
}
