// =====================================================================
// TAMS is a finished system, and the writing has to say so.
//
// A page that explains how the application works, or what it will do
// later, reads as a prototype however complete the code behind it is.
// This suite reads every page and component and refuses the phrases
// that give that away.
//
// It is deliberately narrow. Warnings, eligibility rules and the
// instructions somebody genuinely needs in order to finish what they
// are doing all stay — those are part of the product, not commentary
// on it.
// =====================================================================

import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");
const srcDir = path.join(root, "src");

function sourceFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((entry) => {
    const full = path.join(dir, entry);
    if (statSync(full).isDirectory()) return sourceFiles(full);
    return /\.tsx?$/.test(entry) ? [full] : [];
  });
}

/** A file's user-facing text, with the code comments taken out. */
function copy(file: string): string {
  return readFileSync(file, "utf8")
    .replace(/\/\*[\s\S]*?\*\//g, " ")   // block comments
    .replace(/^\s*\/\/.*$/gm, " ");      // line comments
}

const FILES = sourceFiles(srcDir);
const relative = (file: string) => path.relative(root, file);

// Phrases that only ever appear while a system is still being built or
// demonstrated. Each is matched against the text a user would read.
const PROTOTYPE_PHRASES: RegExp[] = [
  /what you can do(?: right now)?/i,
  /how (?:this|it) works/i,
  /how the council record works/i,
  /how land works here/i,
  /coming (?:soon|next)/i,
  /this page lets you/i,
  /has not been added yet/i,
  /have not been added yet/i,
  /when the .{0,40}work is built/i,
  /will appear in the menu/i,
  /\bfor now\b/i,
  /this will later/i,
  /not yet implemented/i,
  /under construction/i,
  /work in progress/i,
  /\btodo\b/i,
  /\bfixme\b/i,
  /lorem ipsum/i,
];

test("no page explains how the application works", () => {
  const found: string[] = [];

  for (const file of FILES) {
    const text = copy(file);
    for (const phrase of PROTOTYPE_PHRASES) {
      const hit = text.match(phrase);
      if (!hit) continue;
      const line = text.slice(0, hit.index).split("\n").length;
      found.push(`${relative(file)}:${line} — "${hit[0]}"`);
    }
  }

  assert.deepEqual(found, [], `prototype language:\n${found.join("\n")}`);
});

test("the word placeholder only ever appears as a form attribute", () => {
  for (const file of FILES) {
    const text = copy(file);
    // placeholder="…" on an input is a real HTML attribute. The word on
    // its own, in prose, means the screen is not finished.
    const prose = text.replace(/placeholder=/g, "");
    assert.ok(
      !/placeholder/i.test(prose),
      `${relative(file)} uses the word "placeholder" in its text`,
    );
  }
});

// ---------------------------------------------------------------------
// The landing page, which is the first thing anybody sees.
// ---------------------------------------------------------------------

const landing = copy(path.join(srcDir, "pages", "Landing.tsx"));

test("the landing page offers exactly two ways in, and names them plainly", () => {
  assert.match(landing, />\s*Sign in\s*</);
  assert.match(landing, />\s*Create account\s*</);
  assert.ok(
    !/Create a resident account/.test(landing),
    "the second button should read 'Create account'",
  );
});

test("the landing page no longer explains staff and resident accounts", () => {
  assert.ok(!/<strong>Staff<\/strong>/.test(landing), "the staff explanation is still there");
  assert.ok(!/<strong>Residents<\/strong>/.test(landing), "the resident explanation is still there");
  assert.ok(
    !/creates your account and invites/.test(landing),
    "the invitation explanation is still there",
  );
});

test("the landing page keeps the PTO explanation, which a visitor genuinely needs", () => {
  assert.match(landing, /Checking a permission to occupy\?/);
  assert.match(landing, /Verify a PTO/);
  assert.match(landing, /You do not need an account/);
});

test("the landing page stays short", () => {
  // Three paragraphs of prose would be a brochure. One is a product.
  const paragraphs = landing.match(/<p>/g) ?? [];
  assert.ok(paragraphs.length <= 3, `the landing page has ${paragraphs.length} paragraphs`);
});

// ---------------------------------------------------------------------
// The dashboards, which are for working, not for learning.
// ---------------------------------------------------------------------

const DASHBOARDS = [
  ["Council Administrator", "pages/AdminDashboard.tsx"],
  ["Registry Clerk", "pages/registry/RegistryDashboard.tsx"],
  ["Land Officer", "pages/land/LandDashboard.tsx"],
  ["Council Secretary", "pages/secretary/SecretaryDashboard.tsx"],
] as const;

for (const [role, file] of DASHBOARDS) {
  test(`the ${role} dashboard has quick actions, not a tutorial`, () => {
    const text = copy(path.join(srcDir, file));
    assert.match(text, /Quick actions/, `${file} should offer quick actions`);
    assert.match(text, /quick-actions/, `${file} should use the shared action row`);
  });
}

test("every dashboard keeps its operational cards", () => {
  for (const [role, file] of DASHBOARDS) {
    const text = copy(path.join(srcDir, file));
    // Counts and a needs-attention list are what make a dashboard useful.
    const operational = /Needs attention|stat-value|Active staff by role/.test(text);
    assert.ok(operational, `the ${role} dashboard lost its operational cards`);
  }
});

// ---------------------------------------------------------------------
// Empty states say what is empty.
// ---------------------------------------------------------------------

test("no empty state says only \"No data\"", () => {
  for (const file of FILES) {
    const text = copy(file);
    assert.ok(!/>\s*No data\.?\s*</.test(text), `${relative(file)} has a bare "No data" empty state`);
    assert.ok(!/>\s*Nothing\.?\s*</.test(text), `${relative(file)} has a bare "Nothing" empty state`);
  }
});

// ---------------------------------------------------------------------
// Accessibility: the parts a keyboard or a screen reader depends on.
// ---------------------------------------------------------------------

const ui = copy(path.join(srcDir, "components", "ui.tsx"));

test("a field's hint and error are tied to the control, not merely near it", () => {
  assert.match(ui, /aria-describedby/);
  assert.match(ui, /aria-invalid/);
  // Ids derived from the control's own id, so they always match.
  assert.match(ui, /const hintId = `\$\{htmlFor\}-hint`/);
  assert.match(ui, /const errorId = `\$\{htmlFor\}-error`/);
});

test("a field looks inside a wrapper for its control", () => {
  // A password box wraps its input next to a Show button. The
  // attributes have to reach the input, not the wrapper.
  assert.match(ui, /CONTROLS\.has\(node\.type\)/);
  assert.match(ui, /Children\.map\(inner, walk\)/);
});

test("a field never overwrites an attribute the caller set", () => {
  assert.match(ui, /existing\["aria-describedby"\] === undefined/);
  assert.match(ui, /existing\["aria-invalid"\] === undefined/);
});

test("a validation message announces itself", () => {
  assert.match(ui, /className="error"[^>]*role="alert"/);
});

test("an error notice is an alert and the others are not", () => {
  assert.match(ui, /role=\{kind === "error" \? "alert" : "status"\}/);
});

test("a loading panel announces itself rather than sitting silent", () => {
  assert.match(ui, /className="loading" role="status" aria-live="polite"/);
});

test("every field has a label bound to its control", () => {
  assert.match(ui, /<label htmlFor=\{htmlFor\}>\{label\}<\/label>/);
});

test("the mobile menu says whether it is open, and what it controls", () => {
  const shell = copy(path.join(srcDir, "components", "AppShell.tsx"));
  assert.match(shell, /aria-expanded=\{menuOpen\}/);
  assert.match(shell, /aria-controls="main-navigation"/);
  assert.match(shell, /<nav id="main-navigation"/);
  assert.match(shell, /aria-label="Main"/);
});

test("status is never carried by colour alone", () => {
  // Every badge and every milestone state has a word as well as a hue.
  assert.match(ui, /const label = status === "active" \? "Active" : "Deactivated"/);
});

test("focus is visible on everything that can take it", () => {
  const css = readFileSync(path.join(srcDir, "styles.css"), "utf8");
  const rule = css.slice(css.indexOf(".brand-link:focus-visible"));
  const block = rule.slice(0, rule.indexOf("}"));
  for (const selector of ["a:focus-visible", "button:focus-visible"]) {
    assert.ok(rule.slice(0, rule.indexOf("{")).includes(selector), `${selector} has no focus ring`);
  }
  assert.match(block, /outline: 2px solid/);
});

// ---------------------------------------------------------------------
// Alignment: one height for every control, set in one place.
// ---------------------------------------------------------------------

const css = readFileSync(path.join(srcDir, "styles.css"), "utf8");

test("every control takes its height from one shared token", () => {
  assert.match(css, /--control-height:\s*\d+px/);
  const shared = css.slice(css.indexOf(".field input,\n.field select {"));
  assert.match(shared.slice(0, shared.indexOf("}")), /height: var\(--control-height\)/);
});

test("a button is the same height as the controls beside it", () => {
  const button = css.slice(css.indexOf("\n.btn {"));
  assert.match(button.slice(0, button.indexOf("}")), /height: var\(--control-height\)/);
});

test("a filter row aligns to the top, so a hint cannot shift its neighbours", () => {
  const filters = css.slice(css.indexOf("\n.filters {"));
  const block = filters.slice(0, filters.indexOf("}"));
  assert.match(block, /align-items: start/);
  assert.ok(!/align-items:\s*end/.test(block), "align-items: end is what made the rows crooked");
});

test("a form grid aligns to the top for the same reason", () => {
  const grid = css.slice(css.indexOf("\n.form-grid {"));
  assert.match(grid.slice(0, grid.indexOf("}")), /align-items: start/);
});

test("a label reserves its line, so a long one does not shift the control", () => {
  const label = css.slice(css.indexOf(".field label {"));
  assert.match(label.slice(0, label.indexOf("}")), /min-height: 18px/);
});
