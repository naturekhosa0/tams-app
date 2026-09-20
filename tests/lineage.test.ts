// The direction of a family relationship is easy to get backwards, and
// getting it backwards would put someone's grandchildren under
// "Grandparents". These tests pin it down.

import { test } from "node:test";
import assert from "node:assert/strict";
import { groupLineage, relationshipSentence, RELATIONSHIP_GROUPS } from "../src/registry/lineage.ts";
import type { LineageRow } from "../src/registry/types.ts";

const row = (type: string, name: string): LineageRow => ({
  relationship_id: `${type}-${name}`,
  relationship_type: type as LineageRow["relationship_type"],
  relationship_status: "active",
  related_resident_id: name,
  related_full_name: name,
  related_id_number: "SYN0000000000",
  related_status: "active",
  related_household_code: "HH-0001",
});

test("someone this resident is the parent of is shown as their child", () => {
  const groups = groupLineage([row("parent", "Kabelo")]);
  assert.deepEqual(groups.map((g) => g.heading), ["Children"]);
  assert.equal(groups[0].rows[0].related_full_name, "Kabelo");
});

test("someone this resident is the child of is shown as their parent", () => {
  const groups = groupLineage([row("child", "Samuel")]);
  assert.deepEqual(groups.map((g) => g.heading), ["Parents"]);
});

test("someone this resident is the grandparent of is shown as their grandchild", () => {
  const groups = groupLineage([row("grandparent", "Thato")]);
  assert.deepEqual(groups.map((g) => g.heading), ["Grandchildren"]);
});

test("someone this resident is the grandchild of is shown as their grandparent", () => {
  const groups = groupLineage([row("grandchild", "Samuel")]);
  assert.deepEqual(groups.map((g) => g.heading), ["Grandparents"]);
});

test("a guardian relationship is shown as a dependant, and the other way round", () => {
  assert.deepEqual(groupLineage([row("guardian", "Ward")]).map((g) => g.heading), ["Dependants"]);
  assert.deepEqual(groupLineage([row("dependant", "Carer")]).map((g) => g.heading), ["Guardians"]);
});

test("spouse and sibling read the same in both directions", () => {
  assert.deepEqual(groupLineage([row("spouse", "Maria")]).map((g) => g.heading), ["Spouse"]);
  assert.deepEqual(groupLineage([row("sibling", "Lerato")]).map((g) => g.heading), ["Siblings"]);
});

test("groups come back in reading order, and empty ones are left out", () => {
  const groups = groupLineage([
    row("grandparent", "Thato"),
    row("spouse", "Maria"),
    row("parent", "Kabelo"),
    row("child", "Elder"),
  ]);
  assert.deepEqual(groups.map((g) => g.heading), ["Parents", "Children", "Spouse", "Grandchildren"]);
});

test("every relationship type has somewhere to go", () => {
  const covered = RELATIONSHIP_GROUPS.map((group) => group.fromType).sort();
  assert.deepEqual(covered, [
    "child", "dependant", "grandchild", "grandparent", "guardian", "parent", "sibling", "spouse",
  ]);
});

test("the long form states the direction in words", () => {
  assert.equal(
    relationshipSentence("Samuel Rachidi", row("parent", "Kabelo Rachidi")),
    "Samuel Rachidi is the parent of Kabelo Rachidi",
  );
});
