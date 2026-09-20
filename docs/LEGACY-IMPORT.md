# The legacy village data import

A one-time load of the village's existing records, so Registry Clerks
and Land Officers never have to retype history. It is a command you run
yourself — there is no page for it, and there never will be.

## What it loads

| File | Into | Rows supplied |
| --- | --- | --- |
| `land_sites.csv` | `land_sites` | 20 |
| `residents.csv` | `residents` | 70 |
| `households.csv` | `households` | 20 |
| `household_memberships.csv` | `residents.household_id` | 70 |
| `family_relationships.csv` | `family_relationships` | 200 |
| `land_allocations.csv` | `land_allocations` | 20 |

The files live in `data/legacy-import/`.

## Import keys are not database columns

The files identify things by code — `RES-0001`, `R-0001`, `HH-0001`,
`ALLOC-0001`. Those codes are how the six files refer to each other, and
nothing more. `site_code` and `household_code` are genuine identifiers
the village uses, so they are kept; `resident_code` is not, so it is
not.

While the import runs, each code is held against a freshly generated
UUID in a temporary table that disappears when the transaction ends:

```
RES-0001  →  land_sites.id
R-0001    →  residents.id
HH-0001   →  households.id
```

Everything is then written with those UUIDs. `household_memberships.csv`
has no table of its own at all — it becomes `residents.household_id`,
which is what makes it impossible for one resident to be in two
households.

Columns the database has no home for — `notes`, `data_source`,
`current_allocation`, `occupancy_status`, `household_category`,
`established_year`, `member_status`, `relationship_to_head` — are
reported when read and left out. Nothing is dropped silently.

## Running it

```bash
npm run import:dry-run       # read and check the files, send nothing

SUPABASE_URL=https://<your-ref>.supabase.co \
SUPABASE_SERVICE_ROLE_KEY=<service role key> \
npm run import:legacy
```

The service role key belongs in that terminal and nowhere else. It is
never in `.env`, never in `src/`, and never reaches a browser.

Afterwards:

```bash
psql "<your connection string>" -f scripts/verify-village-import.sql
```

or paste that file into the Supabase SQL Editor. It prints the totals,
a list of integrity checks that must all be zero, and worked examples of
a site through to its household, its head, its members and its
allocation holder.

## Nothing is written unless everything passes

The whole dataset goes to the database as one document, and
`import_legacy_village_data()` checks all of it before writing a single
row:

* duplicate site codes, stand numbers, resident codes, identity
  numbers, household codes and allocation references;
* references to sites, residents or households that do not exist;
* a household head who is not a member of that household;
* a resident listed in more than one household;
* a resident related to themselves, an unrecognised relationship type,
  and the same relationship recorded twice;
* more than one current household on a site;
* more than one active allocation on a site;
* dates that are not dates, and statuses this system does not accept.

Every problem found is reported at once, each naming its file and line,
so a broken export can be fixed in one pass. A single problem means
nothing at all is written.

The import also refuses to run if the village tables already hold
anything, so it cannot be applied twice.

## Head of household is not allocation holder

These are separate facts and the data says so. In the supplied package:

| Household | Site | Head of household | Land allocated to |
| --- | --- | --- | --- |
| HH-0012 | RES-0012 | Tshifhiwa Mulaudzi | Nyambeni Mulaudzi |
| HH-0015 | RES-0015 | Nomvula Mabuza | Bongani Mabuza |

HH-0012 is the ordinary case: the site was allocated to the grandparent
in 2011, and his child heads the household today. Nothing in the schema
assumes the two are the same person.

## Who can read any of this

Nobody yet. Row Level Security is on for all five tables with no
policies at all, so neither a signed-out visitor nor a signed-in staff
member — the Council Administrator included — can read or write them.
Access arrives with the Registry Clerk and Land Officer functions, which
will bring their own rules. Only trusted server-side code reaches these
tables today.
