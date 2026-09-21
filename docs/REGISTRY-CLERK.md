# Registry Clerk

Keeping the village register: who lives here, which household they
belong to, who heads it, and how people are related.

## Who may use it

An active staff member whose current role is **Registry Clerk**, and
nobody else. Every one of the functions below starts by asking the
database `is_active_registry_clerk()`, which checks — from `auth.uid()`,
never from anything the browser sends — that there is a valid auth user,
a linked `user_accounts` row, `account_type = 'staff'`,
`account_status = 'active'`, a linked staff record, and a current role of
Registry Clerk. A clerk who is deactivated, or whose role is changed,
loses access on their next request.

The Council Administrator's staff management is untouched by any of
this, and a Registry Clerk cannot reach it.

## What they can and cannot change

| | Read | Write |
| --- | --- | --- |
| residents | yes | through `registry_*` functions |
| households | yes | through `registry_*` functions |
| family_relationships | yes | through `registry_*` functions |
| land_sites | yes | **no** |
| land_allocations | yes | **no** |

Reads go through Row Level Security. Writes do not: there is no insert,
update or delete policy on any village table, so the only way a row
changes is a function that agreed to it. A clerk who tries to write a
table directly gets `permission denied`, and there is a test for each
one.

Land sites and allocations are readable because a household without its
address is meaningless and the clerk needs to see who holds the
allocation — but they are the Land Officer's to change.

## Searching

`registry_search_residents(search)` matches, case-insensitively, on
identity number, first name, surname, full name, contact number, email,
household code, site code and street address. `registry_search_households`
matches household code, site code, stand number, address, section and
the names or identity numbers of members.

What is typed is matched literally: `%` and `_` are escaped, so a search
for `%` finds the residents whose details contain a percent sign, not
everybody.

## Residents

**Create** requires an identity number, first name, surname, date of
birth, gender and status; contact number, email and household are
optional. The identity number must not already be on the register, and
the date must be a real one.

Creating a resident record creates **no** Supabase Auth user and **no**
`user_accounts` row. It is the village's record of a person, not a way
in. Resident accounts are a later phase.

**Update** changes the same fields in place. The resident keeps their
id, their household, their relationships and their land history. The
identity number can change, and is still checked for uniqueness against
everyone else.

Nothing is ever deleted. Someone who has died is recorded as
`deceased`, which leaves every other record about them intact.

Household membership is deliberately *not* editable from the update
form — that has its own rules, below.

## Households

A household is identified by its `household_code`. Surnames are not
identity: two households may share one, and members of one household may
have different surnames.

**Create** suggests the next code by reading the highest `HH-####`
actually in the database rather than assuming. The site must exist, be
`residential`, and have no current household on it — and since a clerk
cannot create sites, only sites that already exist are offered. A new
household starts with no head:

```
create the household → link residents to it → designate a head
```

## Linking a resident to a household

A resident belongs to one household, so linking them to another moves
them. That is never silent: the database refuses until the move is
confirmed, and the interface turns that refusal into a confirmation step
showing which household they are leaving.

A head of household cannot be moved out from under their own household —
designate a new head first.

## Head of household

The head must be a member of that household and must not be recorded as
deceased. A household has one head: designating a new one replaces the
old, and replacing a sitting head has to be confirmed. It never creates
a second household.

## Family relationships

Recorded from one resident's point of view:

```
Samuel  is the parent of  Kabelo
```

and the database records the other side of the same fact:

```
Kabelo  is the child of  Samuel
```

The pairs are `parent ↔ child`, `grandparent ↔ grandchild`,
`guardian ↔ dependant`, `spouse ↔ spouse`, `sibling ↔ sibling`. If the
other side already exists — as it does throughout the imported data —
nothing is duplicated.

Relatives do not have to share a household.

**Which way round it reads matters.** A stored `parent` row on Samuel's
record means Samuel is the parent of that person, so on screen that
person appears under **Children**. Filing it the other way round would
show a resident's grandchildren as their grandparents; there are tests
that pin this down.

Relationships are never deleted. One that is no longer current is set to
`inactive`, and its inverse follows it.

## Pages

| Page | What it does |
| --- | --- |
| `/registry` | Dashboard: counts, and what needs attention |
| `/registry/residents` | Search the register |
| `/registry/residents/new` | Create a resident |
| `/registry/residents/:id` | The resident record, household, address and lineage |
| `/registry/residents/:id/edit` | Update a resident |
| `/registry/households` | Search households, create one |
| `/registry/households/:id` | Household, site, allocation context, members |
| `/registry/lineage/:id` | Full family lineage, and recording relationships |

## "Could not find the function public.registry_… in the schema cache"

That message comes from PostgREST, not from TAMS, and it means one of
two things.

**The migration has not been applied to your project.** Run:

```bash
npm run db:push
```

or paste `supabase/migrations/20260922090000_registry_clerk.sql` into
the Supabase SQL Editor. It is safe to run more than once.

**Or the migration is applied and PostgREST has not noticed yet.** It
keeps its own cache of what the database offers. Run this in the SQL
Editor:

```sql
notify pgrst, 'reload schema';
```

To find out which of the two it is, run
[`scripts/check-registry-functions.sql`](../scripts/check-registry-functions.sql)
in the SQL Editor. It counts the functions (there should be 15), lists
them with whether a signed-in user may call them, and reloads the cache
for you.
