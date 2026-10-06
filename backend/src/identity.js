// Resolves provider filer names to bioguide IDs from the bundled congressional roster.
// Chamber and state are hard constraints when supplied; district and party only break ties,
// because providers lag redistricting and party changes.

export const STATE_CODES = {
  alabama: "AL", alaska: "AK", arizona: "AZ", arkansas: "AR", california: "CA", colorado: "CO",
  connecticut: "CT", delaware: "DE", florida: "FL", georgia: "GA", hawaii: "HI", idaho: "ID",
  illinois: "IL", indiana: "IN", iowa: "IA", kansas: "KS", kentucky: "KY", louisiana: "LA",
  maine: "ME", maryland: "MD", massachusetts: "MA", michigan: "MI", minnesota: "MN",
  mississippi: "MS", missouri: "MO", montana: "MT", nebraska: "NE", nevada: "NV",
  "new hampshire": "NH", "new jersey": "NJ", "new mexico": "NM", "new york": "NY",
  "north carolina": "NC", "north dakota": "ND", ohio: "OH", oklahoma: "OK", oregon: "OR",
  pennsylvania: "PA", "rhode island": "RI", "south carolina": "SC", "south dakota": "SD",
  tennessee: "TN", texas: "TX", utah: "UT", vermont: "VT", virginia: "VA", washington: "WA",
  "west virginia": "WV", wisconsin: "WI", wyoming: "WY", "district of columbia": "DC",
  "puerto rico": "PR", guam: "GU", "virgin islands": "VI", "american samoa": "AS",
  "northern mariana islands": "MP"
};

const HONORIFICS = new Set([
  "hon", "honorable", "sen", "senator", "rep", "representative", "dr", "mr", "mrs", "ms",
  "jr", "sr", "ii", "iii", "iv", "md", "facs", "phd", "dds", "cpa", "esq"
]);

const CREDENTIALS = new Set(["md", "facs", "phd", "dds", "cpa", "esq", "jr", "sr", "ii", "iii", "iv"]);

const GIVEN_NAME_ALIASES = {
  bill: "william", will: "william", bob: "robert", rob: "robert", chris: "christopher",
  chuck: "charles", dan: "daniel", don: "donald", ed: "edward", jack: "john", jim: "james",
  jimmy: "james", joe: "joseph", ken: "kenneth", matt: "matthew", mike: "michael",
  rick: "richard", rich: "richard", dick: "richard", ron: "ronald", tom: "thomas",
  tim: "timothy", val: "valerie", gil: "gilbert", greg: "gregory", steve: "steven",
  stephen: "steven", dave: "david", andy: "andrew", tony: "anthony", pat: "patrick",
  pete: "peter", sam: "samuel", ted: "edward", nick: "nicholas", vince: "vincent",
  liz: "elizabeth", beth: "elizabeth", kathy: "katherine", cathy: "catherine", debbie: "deborah",
  sue: "susan", abe: "abraham", fred: "frederick", jerry: "gerald", larry: "lawrence",
  mitch: "mitchell", josh: "joshua", zach: "zachary", ben: "benjamin", buddy: "earl"
};

export function stateCode(value) {
  const text = String(value ?? "").trim();
  if (!text) return null;
  if (/^[A-Za-z]{2}$/.test(text)) return text.toUpperCase();
  return STATE_CODES[text.toLowerCase()] ?? null;
}

export function normalizePersonName(value = "") {
  let text = String(value);
  // "Pelosi, Nancy" is surname-first; "Neal Patrick MD, FACS Dunn" only has a credential comma.
  const comma = text.indexOf(",");
  const afterComma = text.slice(comma + 1).trim().split(/[^A-Za-z]+/)[0]?.toLowerCase();
  if (comma > 0 && !CREDENTIALS.has(afterComma)) {
    text = `${text.slice(comma + 1)} ${text.slice(0, comma)}`;
  } else {
    text = text.replaceAll(",", " ");
  }
  return text
    .normalize("NFKD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter((token) => token && !HONORIFICS.has(token))
    .join(" ");
}

function canonicalGiven(token) {
  return GIVEN_NAME_ALIASES[token] ?? token;
}

function tokens(normalized) {
  return normalized.split(" ").filter(Boolean);
}

export function createResolver(roster) {
  const people = roster.map((person) => {
    const normalized = normalizePersonName(person.name);
    const parts = tokens(normalized);
    return {
      id: person.id,
      chamber: person.chamber,
      state: stateCode(person.state),
      district: person.district ?? null,
      party: String(person.party ?? "").slice(0, 1).toUpperCase(),
      normalized,
      given: parts[0],
      surname: parts.at(-1)
    };
  });
  const ids = new Set(people.map((person) => person.id));

  return function resolve({ politicianID, name, chamber, state, district, party } = {}) {
    if (politicianID && ids.has(politicianID)) return { id: politicianID, confidence: 1 };
    const normalized = normalizePersonName(name);
    const parts = tokens(normalized);
    if (parts.length === 0) return null;
    const code = stateCode(state);
    const pool = people.filter((person) =>
      (!chamber || person.chamber === chamber) && (!code || person.state === code)
    );
    const tieBreak = (matches) => {
      if (matches.length <= 1) return matches;
      const byDistrict = district == null ? [] : matches.filter((person) => person.district === Number(district));
      if (byDistrict.length === 1) return byDistrict;
      const partyInitial = String(party ?? "").slice(0, 1).toUpperCase();
      const byParty = partyInitial ? matches.filter((person) => person.party === partyInitial) : [];
      return byParty.length === 1 ? byParty : matches;
    };
    const unique = (matches, confidence) => {
      const narrowed = tieBreak(matches);
      return narrowed.length === 1 ? { id: narrowed[0].id, confidence } : null;
    };

    const exact = pool.filter((person) => person.normalized === normalized);
    if (exact.length) return unique(exact, 1);

    const given = parts[0];
    const surname = parts.at(-1);
    const sameSurname = pool.filter((person) => person.surname === surname);
    const byGiven = sameSurname.filter((person) => canonicalGiven(person.given) === canonicalGiven(given));
    if (byGiven.length) return unique(byGiven, 0.95);

    const byInitial = sameSurname.filter((person) => person.given?.[0] === given[0]);
    if (byInitial.length) return unique(byInitial, 0.85);

    // A surname unique within a known state delegation is a strong identity signal.
    if (code && sameSurname.length) return unique(sameSurname, 0.75);

    const ranked = pool
      .map((person) => ({ person, score: similarity(normalized, person.normalized) }))
      .filter((item) => item.score >= 0.75)
      .sort((a, b) => b.score - a.score || a.person.id.localeCompare(b.person.id));
    if (!ranked.length) return null;
    if (ranked[1] && ranked[0].score - ranked[1].score < 0.05) return null;
    return { id: ranked[0].person.id, confidence: Number((ranked[0].score * 0.9).toFixed(4)) };
  };
}

function similarity(lhs, rhs) {
  const distance = levenshtein(lhs, rhs);
  const edit = 1 - distance / Math.max(lhs.length, rhs.length, 1);
  const left = new Set(tokens(lhs));
  const right = new Set(tokens(rhs));
  const shared = [...left].filter((token) => right.has(token)).length;
  const token = (shared * 2) / Math.max(left.size + right.size, 1);
  return Math.max(edit, token);
}

function levenshtein(lhs, rhs) {
  let previous = Array.from({ length: rhs.length + 1 }, (_, index) => index);
  for (let i = 0; i < lhs.length; i += 1) {
    const current = [i + 1];
    for (let j = 0; j < rhs.length; j += 1) {
      current[j + 1] = Math.min(previous[j + 1] + 1, current[j] + 1, previous[j] + (lhs[i] === rhs[j] ? 0 : 1));
    }
    previous = current;
  }
  return previous[rhs.length];
}

export function houseStateDistrict(value) {
  const match = String(value ?? "").trim().toUpperCase().match(/^([A-Z]{2})(\d{1,2})?$/);
  if (!match) return { state: null, district: null };
  const district = match[2] == null ? null : Number(match[2]);
  return { state: match[1], district: district === 0 ? null : district };
}
