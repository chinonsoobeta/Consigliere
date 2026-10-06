// Regenerates the bundled congressional roster from the public-domain
// unitedstates/congress-legislators dataset. Existing display names, photos, and
// service-start years are preserved so a refresh only adds, removes, or re-districts members.
//
//   node scripts/update-roster.mjs
import { readFile, writeFile } from "node:fs/promises";

const SOURCE = "https://unitedstates.github.io/congress-legislators/legislators-current.json";
const ROSTER_PATH = new URL("../../Consigliere/Resources/Data/current-politicians.json", import.meta.url);
const STATE_NAMES = {
  AL: "Alabama", AK: "Alaska", AZ: "Arizona", AR: "Arkansas", CA: "California", CO: "Colorado",
  CT: "Connecticut", DE: "Delaware", FL: "Florida", GA: "Georgia", HI: "Hawaii", ID: "Idaho",
  IL: "Illinois", IN: "Indiana", IA: "Iowa", KS: "Kansas", KY: "Kentucky", LA: "Louisiana",
  ME: "Maine", MD: "Maryland", MA: "Massachusetts", MI: "Michigan", MN: "Minnesota",
  MS: "Mississippi", MO: "Missouri", MT: "Montana", NE: "Nebraska", NV: "Nevada",
  NH: "New Hampshire", NJ: "New Jersey", NM: "New Mexico", NY: "New York", NC: "North Carolina",
  ND: "North Dakota", OH: "Ohio", OK: "Oklahoma", OR: "Oregon", PA: "Pennsylvania",
  RI: "Rhode Island", SC: "South Carolina", SD: "South Dakota", TN: "Tennessee", TX: "Texas",
  UT: "Utah", VT: "Vermont", VA: "Virginia", WA: "Washington", WV: "West Virginia",
  WI: "Wisconsin", WY: "Wyoming", DC: "District of Columbia", PR: "Puerto Rico", GU: "Guam",
  VI: "Virgin Islands", AS: "American Samoa", MP: "Northern Mariana Islands"
};

const response = await fetch(SOURCE);
if (!response.ok) throw new Error(`Roster source returned ${response.status}`);
const legislators = await response.json();
const existing = new Map(
  JSON.parse(await readFile(ROSTER_PATH, "utf8")).map((person) => [person.id, person])
);

const roster = legislators.map((legislator) => {
  const id = legislator.id.bioguide;
  const term = legislator.terms.at(-1);
  const chamber = term.type === "sen" ? "senate" : "house";
  const previous = existing.get(id);
  const sameChamberStarts = legislator.terms
    .filter((item) => item.type === term.type)
    .map((item) => Number(item.start.slice(0, 4)));
  return {
    id,
    name: previous?.name ?? legislator.name.official_full ?? `${legislator.name.first} ${legislator.name.last}`,
    party: term.party === "Democrat" ? "Democratic" : term.party,
    state: STATE_NAMES[term.state] ?? term.state,
    district: chamber === "house" && term.district > 0 ? term.district : null,
    chamber,
    imageURL: previous?.imageURL ?? `https://www.congress.gov/img/member/${id.toLowerCase()}_200.jpg`,
    serviceStart: previous?.serviceStart ?? Math.min(...sameChamberStarts)
  };
});
// Keep the existing file order so refresh diffs only show real roster changes.
const order = new Map([...existing.keys()].map((id, index) => [id, index]));
roster.sort((a, b) => (order.get(a.id) ?? Infinity) - (order.get(b.id) ?? Infinity)
  || a.state.localeCompare(b.state) || a.name.localeCompare(b.name));

const added = roster.filter((person) => !existing.has(person.id)).map((person) => person.name);
const removed = [...existing.values()]
  .filter((person) => !roster.some((item) => item.id === person.id))
  .map((person) => person.name);
await writeFile(ROSTER_PATH, `${JSON.stringify(roster, null, 2)}\n`);
console.log(`Wrote ${roster.length} members. Added: ${added.join(", ") || "none"}. Removed: ${removed.join(", ") || "none"}.`);
