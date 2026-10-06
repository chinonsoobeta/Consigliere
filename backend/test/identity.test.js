import test from "node:test";
import assert from "node:assert/strict";
import { createResolver, houseStateDistrict, normalizePersonName, stateCode } from "../src/identity.js";
import roster from "../src/roster.js";

const resolve = createResolver(roster);

test("matches filers by two-letter state codes for every state, not a partial list", () => {
  // Production filers that were dropped because their states were missing from the old lookup.
  assert.equal(resolve({ name: "April McClain Delaney", chamber: "house", state: "MD", district: 6 })?.id, "M001232");
  assert.equal(resolve({ name: "Kevin Hern", chamber: "house", state: "OK", district: 1 })?.id, "H001082");
  assert.equal(resolve({ name: "Kelly Louise Morrison", chamber: "house", state: "MN", district: 3 })?.id, "M001234");
  for (const person of roster) assert.ok(stateCode(person.state), `missing code for ${person.state}`);
});

test("treats district as a tie-breaker because providers lag redistricting", () => {
  // The provider still reports GA-6; the member now represents GA-7.
  const match = resolve({ name: "Richard Dean Dr McCormick", chamber: "house", state: "GA", district: 6 });
  assert.equal(match?.id, "M001218");
});

test("chamber and state remain hard constraints", () => {
  assert.equal(resolve({ name: "April McClain Delaney", chamber: "senate", state: "MD" }), null);
  assert.equal(resolve({ name: "April McClain Delaney", chamber: "house", state: "VA" }), null);
});

test("refuses ambiguous surname matches and accepts unique ones with lower confidence", () => {
  const people = [
    { id: "A1", name: "John Smith", chamber: "house", state: "Texas", district: 1, party: "Republican" },
    { id: "A2", name: "Jane Smith", chamber: "house", state: "Texas", district: 2, party: "Democratic" },
    { id: "A3", name: "Mike Lee", chamber: "senate", state: "Utah", district: null, party: "Republican" }
  ];
  const local = createResolver(people);
  assert.equal(local({ name: "J. Smith", chamber: "house", state: "TX" }), null);
  assert.equal(local({ name: "J. Smith", chamber: "house", state: "TX", district: 2 })?.id, "A2");
  assert.deepEqual(local({ name: "Michael S. Lee", chamber: "senate", state: "UT" }), { id: "A3", confidence: 0.95 });
  assert.deepEqual(local({ name: "Senator Lee", chamber: "senate", state: "UT" }), { id: "A3", confidence: 0.75 });
});

test("normalizes honorifics, suffixes, and Last, First order", () => {
  assert.equal(normalizePersonName("Hon. Pelosi, Nancy"), "nancy pelosi");
  assert.equal(normalizePersonName("Everton Blair Jr."), "everton blair");
  assert.equal(normalizePersonName("Neal Patrick MD, Facs Dunn"), "neal patrick dunn");
  assert.deepEqual(houseStateDistrict("CA11"), { state: "CA", district: 11 });
  assert.deepEqual(houseStateDistrict("AK00"), { state: "AK", district: null });
});
