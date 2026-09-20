-- =====================================================================
-- TAMS — resident accounts and verification requests
--
-- The principle this is built on: creating an online account does not
-- make anyone a resident of the village. The residents table remains
-- the authoritative register, and an applicant only becomes linked to
-- it when a Registry Clerk matches them to a record that was already
-- there. Registration never writes to residents.
--
--   auth.users  →  user_accounts (resident, pending)
--                        │
--                        └─< resident_account_requests  (one per attempt)
--                                    │
--                                    └─< resident_request_documents
--
-- A declined applicant keeps their account and applies again; the
-- earlier attempt is kept exactly as it was.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. user_accounts learns about residents
-- ---------------------------------------------------------------------

alter table public.user_accounts
  drop constraint if exists user_accounts_account_type_allowed;
alter table public.user_accounts
  add constraint user_accounts_account_type_allowed
  check (account_type in ('staff', 'resident'));

alter table public.user_accounts
  drop constraint if exists user_accounts_account_status_allowed;
alter table public.user_accounts
  add constraint user_accounts_account_status_allowed
  check (account_status in ('active', 'deactivated', 'pending', 'declined'));

-- A resident account never points at a staff record, and only a
-- resident account may be linked to a resident.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'user_accounts_resident_shape') then
    alter table public.user_accounts
      add constraint user_accounts_resident_shape check (
        account_type <> 'resident' or staff_id is null
      );
  end if;

  if not exists (select 1 from pg_constraint where conname = 'user_accounts_resident_id_fkey') then
    alter table public.user_accounts
      add constraint user_accounts_resident_id_fkey
      foreign key (resident_id) references public.residents (id);
  end if;
end;
$$;

comment on column public.user_accounts.resident_id is
  'The official resident this account was matched to, set only by a Registry Clerk approving a verification request.';

-- One resident record, at most one resident account.
create unique index if not exists user_accounts_one_account_per_resident_idx
  on public.user_accounts (resident_id)
  where resident_id is not null;

create index if not exists user_accounts_account_type_idx on public.user_accounts (account_type);

-- ---------------------------------------------------------------------
-- 2. One row per application attempt
-- ---------------------------------------------------------------------

create table if not exists public.resident_account_requests (
  id                       uuid primary key default gen_random_uuid(),
  user_account_id          uuid not null references public.user_accounts (id) on delete cascade,

  -- What the applicant claims about themselves. Evidence for matching,
  -- never authoritative: it is not copied into residents.
  first_name               text not null,
  middle_names             text,
  last_name                text not null,
  previous_surname         text,
  id_number                text not null,
  date_of_birth            date not null,
  gender                   text not null,

  cellphone_number         text not null,

  house_number             text not null,
  street_address           text not null,

  household_head_name             text not null,
  relationship_to_household_head  text not null,

  request_status           text not null default 'pending',

  submitted_at             timestamptz not null default now(),
  reviewed_at              timestamptz,
  reviewed_by_staff_id     uuid references public.staff (id),
  decline_reason           text,
  matched_resident_id      uuid references public.residents (id),

  constraint resident_account_requests_status_allowed
    check (request_status in ('pending', 'approved', 'declined')),
  constraint resident_account_requests_names_present
    check (btrim(first_name) <> '' and btrim(last_name) <> ''),
  constraint resident_account_requests_identity_present
    check (btrim(id_number) <> '' and btrim(gender) <> ''),
  constraint resident_account_requests_contact_present
    check (btrim(cellphone_number) <> ''),
  constraint resident_account_requests_address_present
    check (btrim(house_number) <> '' and btrim(street_address) <> ''),
  constraint resident_account_requests_household_claim_present
    check (btrim(household_head_name) <> '' and btrim(relationship_to_household_head) <> ''),
  -- A decision has a reviewer and a time; a decline also has a reason.
  constraint resident_account_requests_review_shape check (
    (request_status = 'pending'  and reviewed_at is null and reviewed_by_staff_id is null
      and decline_reason is null and matched_resident_id is null)
    or (request_status = 'approved' and reviewed_at is not null and reviewed_by_staff_id is not null
      and matched_resident_id is not null and decline_reason is null)
    or (request_status = 'declined' and reviewed_at is not null and reviewed_by_staff_id is not null
      and btrim(coalesce(decline_reason, '')) <> '' and matched_resident_id is null)
  )
);

comment on table public.resident_account_requests is
  'One application attempt. Declined attempts are kept: the applicant reapplies with a new row, not a new account.';

create index if not exists resident_account_requests_user_account_idx
  on public.resident_account_requests (user_account_id);
create index if not exists resident_account_requests_status_idx
  on public.resident_account_requests (request_status);
create index if not exists resident_account_requests_id_number_idx
  on public.resident_account_requests (id_number);

-- An account may have many attempts behind it, but only one waiting.
create unique index if not exists resident_account_requests_one_pending_idx
  on public.resident_account_requests (user_account_id)
  where request_status = 'pending';

-- ---------------------------------------------------------------------
-- 3. The documents attached to an attempt
--
--    Only where the file lives, never the file itself.
-- ---------------------------------------------------------------------

create table if not exists public.resident_request_documents (
  id              uuid primary key default gen_random_uuid(),
  request_id      uuid not null references public.resident_account_requests (id) on delete cascade,
  document_type   text not null,
  storage_path    text not null,
  file_name       text not null,
  mime_type       text not null,
  file_size_bytes bigint not null,
  uploaded_at     timestamptz not null default now(),

  constraint resident_request_documents_type_allowed
    check (document_type in ('certified_id_copy', 'proof_of_residence')),
  constraint resident_request_documents_mime_allowed
    check (mime_type in ('application/pdf', 'image/jpeg', 'image/png')),
  constraint resident_request_documents_size_allowed
    check (file_size_bytes > 0 and file_size_bytes <= 2097152),
  constraint resident_request_documents_path_present
    check (btrim(storage_path) <> '' and btrim(file_name) <> ''),
  -- One certified ID copy and one proof of residence per attempt.
  constraint resident_request_documents_one_of_each unique (request_id, document_type)
);

comment on table public.resident_request_documents is
  'Where an uploaded document lives in the private storage bucket. The bytes are never in PostgreSQL.';

create index if not exists resident_request_documents_request_idx
  on public.resident_request_documents (request_id);

-- ---------------------------------------------------------------------
-- 4. The private bucket
--
--    Created here so the limits travel with the migration. Supabase
--    enforces the size and the accepted types on upload itself, which
--    no browser can talk its way around.
-- ---------------------------------------------------------------------

do $$
begin
  if to_regclass('storage.buckets') is null then
    return;  -- not a Supabase database; the local test harness stubs this
  end if;

  begin
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('resident-verification-documents', 'resident-verification-documents', false,
            2097152, array['application/pdf', 'image/jpeg', 'image/png'])
    on conflict (id) do update
      set public = false,
          file_size_limit = 2097152,
          allowed_mime_types = array['application/pdf', 'image/jpeg', 'image/png'];
  exception when undefined_column then
    -- An older storage schema without the limit columns.
    insert into storage.buckets (id, name, public)
    values ('resident-verification-documents', 'resident-verification-documents', false)
    on conflict (id) do update set public = false;
  end;
end;
$$;

-- Applicants reach only their own folder; Registry Clerks may read the
-- whole bucket to review what was submitted. Nobody else gets in, and
-- there is no update or delete policy at all.
do $$
begin
  if to_regclass('storage.objects') is null then
    return;
  end if;

  execute $policy$
    drop policy if exists resident_documents_insert_own on storage.objects;
    create policy resident_documents_insert_own on storage.objects
      for insert to authenticated
      with check (
        bucket_id = 'resident-verification-documents'
        and split_part(name, '/', 1) = auth.uid()::text
      );
  $policy$;

  execute $policy$
    drop policy if exists resident_documents_read_own on storage.objects;
    create policy resident_documents_read_own on storage.objects
      for select to authenticated
      using (
        bucket_id = 'resident-verification-documents'
        and split_part(name, '/', 1) = auth.uid()::text
      );
  $policy$;

  execute $policy$
    drop policy if exists resident_documents_read_by_registry_clerk on storage.objects;
    create policy resident_documents_read_by_registry_clerk on storage.objects
      for select to authenticated
      using (
        bucket_id = 'resident-verification-documents'
        and public.is_active_registry_clerk()
      );
  $policy$;
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Row Level Security on the new tables
--
--    Applicants read their own attempts and their own documents. An
--    active Registry Clerk reads all of them. There is no insert,
--    update or delete policy: every change goes through the functions
--    below.
-- ---------------------------------------------------------------------

alter table public.resident_account_requests  enable row level security;
alter table public.resident_request_documents enable row level security;
alter table public.resident_account_requests  force row level security;
alter table public.resident_request_documents force row level security;

drop policy if exists resident_requests_readable_by_owner_or_clerk on public.resident_account_requests;
create policy resident_requests_readable_by_owner_or_clerk
  on public.resident_account_requests for select to authenticated
  using (
    public.is_active_registry_clerk()
    or exists (select 1 from public.user_accounts ua
                where ua.id = resident_account_requests.user_account_id
                  and ua.auth_user_id = auth.uid())
  );

drop policy if exists resident_documents_readable_by_owner_or_clerk on public.resident_request_documents;
create policy resident_documents_readable_by_owner_or_clerk
  on public.resident_request_documents for select to authenticated
  using (
    public.is_active_registry_clerk()
    or exists (select 1 from public.resident_account_requests r
                join public.user_accounts ua on ua.id = r.user_account_id
               where r.id = resident_request_documents.request_id
                 and ua.auth_user_id = auth.uid())
  );

revoke all on public.resident_account_requests  from anon, authenticated;
revoke all on public.resident_request_documents from anon, authenticated;
grant select on public.resident_account_requests  to authenticated;
grant select on public.resident_request_documents to authenticated;
grant all on public.resident_account_requests  to service_role;
grant all on public.resident_request_documents to service_role;

-- ---------------------------------------------------------------------
-- 6. Becoming a resident account
--
--    Called once, by the person who has just signed up and confirmed
--    their email. It only ever creates a RESIDENT account: staff
--    accounts are made by the invitation process and nothing here can
--    produce one. If an account already exists it is returned
--    untouched, so signing in again changes nothing.
-- ---------------------------------------------------------------------

create or replace function public.resident_ensure_account()
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_user    auth.users;
  v_account public.user_accounts;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.' using errcode = '42501';
  end if;

  select * into v_account from public.user_accounts where auth_user_id = auth.uid();
  if found then
    -- Already has an account of some kind. Never changed here.
    return jsonb_build_object(
      'account_id', v_account.id, 'account_type', v_account.account_type,
      'account_status', v_account.account_status, 'created', false);
  end if;

  select * into v_user from auth.users where id = auth.uid();
  if not found or coalesce(btrim(v_user.email), '') = '' then
    raise exception 'That sign-in has no email address.' using errcode = 'TA050';
  end if;

  -- A staff member's account is created by the invitation process. If
  -- one is somehow missing, it is not this function's job to invent it.
  if exists (select 1 from public.staff s where lower(s.email) = lower(v_user.email)) then
    raise exception 'That email address belongs to a staff member. Staff accounts are created by the Council Administrator.'
      using errcode = 'TA050';
  end if;

  insert into public.user_accounts (auth_user_id, email, account_type, account_status, resident_id)
  values (auth.uid(), lower(btrim(v_user.email)), 'resident', 'pending', null)
  returning * into v_account;

  return jsonb_build_object(
    'account_id', v_account.id, 'account_type', v_account.account_type,
    'account_status', v_account.account_status, 'created', true);
end;
$$;

-- ---------------------------------------------------------------------
-- 7. What a resident sees of their own account
-- ---------------------------------------------------------------------

create or replace function public.resident_portal()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_account public.user_accounts;
  v_result  jsonb;
begin
  select * into v_account from public.user_accounts
  where auth_user_id = auth.uid() and account_type = 'resident';
  if not found then
    raise exception 'You do not have a resident account.' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'account_id',     v_account.id,
    'email',          v_account.email,
    'account_status', v_account.account_status,
    'resident_id',    v_account.resident_id,
    -- Only ever their own official record, and only once matched.
    'resident', (select jsonb_build_object(
                          'full_name', r.first_name || ' ' || r.last_name,
                          'id_number', r.id_number,
                          'household_code', h.household_code,
                          'street_address', s.street_address)
                 from public.residents r
                 left join public.households h on h.id = r.household_id
                 left join public.land_sites s on s.id = h.residential_site_id
                 where r.id = v_account.resident_id),
    'latest_request', (
      select jsonb_build_object(
               'request_id',     q.id,
               'request_status', q.request_status,
               'submitted_at',   q.submitted_at,
               'reviewed_at',    q.reviewed_at,
               'decline_reason', q.decline_reason,
               'first_name',     q.first_name,
               'last_name',      q.last_name,
               'id_number',      q.id_number)
      from public.resident_account_requests q
      where q.user_account_id = v_account.id
      order by q.submitted_at desc limit 1),
    'attempts', coalesce((
      select jsonb_agg(jsonb_build_object(
               'request_status', q.request_status,
               'submitted_at',   q.submitted_at,
               'reviewed_at',    q.reviewed_at,
               'decline_reason', q.decline_reason)
             order by q.submitted_at desc)
      from public.resident_account_requests q
      where q.user_account_id = v_account.id), '[]'::jsonb),
    'may_submit', (
      v_account.account_status in ('pending', 'declined')
      and not exists (select 1 from public.resident_account_requests q
                       where q.user_account_id = v_account.id and q.request_status = 'pending'))
  ) into v_result;

  return v_result;
end;
$$;

-- ---------------------------------------------------------------------
-- 8. Submitting a verification request
--
--    One call: the claimed details and both documents together, so a
--    request can never exist without the documents that support it.
--    The documents have already been uploaded to the applicant's own
--    folder in the private bucket; what arrives here is where they are.
-- ---------------------------------------------------------------------

create or replace function public.resident_submit_verification_request(
  p_details   jsonb,
  p_documents jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_account  public.user_accounts;
  v_request  public.resident_account_requests;
  v_document jsonb;
  v_types    text[] := '{}';
  v_path     text;
  v_exists   boolean;
  v_real_size bigint;
begin
  select * into v_account from public.user_accounts
  where auth_user_id = auth.uid() and account_type = 'resident' for update;
  if not found then
    raise exception 'You do not have a resident account.' using errcode = '42501';
  end if;

  if v_account.account_status not in ('pending', 'declined') then
    raise exception 'This account is % and cannot submit a verification request.', v_account.account_status
      using errcode = 'TA051';
  end if;

  if exists (select 1 from public.resident_account_requests q
              where q.user_account_id = v_account.id and q.request_status = 'pending') then
    raise exception 'A verification request is already waiting to be reviewed.'
      using errcode = 'TA051';
  end if;

  -- ---- the two documents -------------------------------------------
  if jsonb_typeof(p_documents) <> 'array' or jsonb_array_length(p_documents) <> 2 then
    raise exception 'A certified copy of your ID and a proof of residence are both required.'
      using errcode = 'TA057';
  end if;

  for v_document in select * from jsonb_array_elements(p_documents)
  loop
    if (v_document ->> 'document_type') not in ('certified_id_copy', 'proof_of_residence') then
      raise exception 'Unknown document type %.', coalesce(v_document ->> 'document_type', '(none)')
        using errcode = 'TA057';
    end if;
    v_types := v_types || (v_document ->> 'document_type');

    if (v_document ->> 'mime_type') not in ('application/pdf', 'image/jpeg', 'image/png') then
      raise exception 'A document must be a PDF, a JPG or a PNG. % is not accepted.',
        coalesce(v_document ->> 'mime_type', '(none)')
        using errcode = 'TA058';
    end if;

    v_path := coalesce(btrim(v_document ->> 'storage_path'), '');
    -- The file has to be in the applicant's own folder, so nobody can
    -- attach somebody else's document to their application.
    if v_path = '' or split_part(v_path, '/', 1) <> auth.uid()::text then
      raise exception 'That document does not belong to this account.' using errcode = 'TA059';
    end if;

    v_real_size := nullif(v_document ->> 'file_size_bytes', '')::bigint;

    -- On a real Supabase database the uploaded object is the authority
    -- on its own size, so a declared size cannot be talked down.
    if to_regclass('storage.objects') is not null then
      execute format(
        'select exists (select 1 from storage.objects where bucket_id = %L and name = %L),
                (select (metadata ->> ''size'')::bigint from storage.objects
                  where bucket_id = %L and name = %L)',
        'resident-verification-documents', v_path,
        'resident-verification-documents', v_path)
      into v_exists, v_real_size;

      if not coalesce(v_exists, false) then
        raise exception 'That document was not uploaded.' using errcode = 'TA059';
      end if;
      v_real_size := coalesce(v_real_size, nullif(v_document ->> 'file_size_bytes', '')::bigint);
    end if;

    if v_real_size is null or v_real_size <= 0 then
      raise exception 'That document appears to be empty.' using errcode = 'TA058';
    end if;
    if v_real_size > 2097152 then
      raise exception 'Each document must be 2 MB or smaller. % is %.',
        coalesce(v_document ->> 'file_name', 'that file'),
        pg_size_pretty(v_real_size)
        using errcode = 'TA058';
    end if;
  end loop;

  if not ('certified_id_copy' = any (v_types) and 'proof_of_residence' = any (v_types)) then
    raise exception 'A certified copy of your ID and a proof of residence are both required.'
      using errcode = 'TA057';
  end if;

  -- ---- the claimed details -------------------------------------------
  insert into public.resident_account_requests (
    user_account_id, first_name, middle_names, last_name, previous_surname,
    id_number, date_of_birth, gender, cellphone_number,
    house_number, street_address, household_head_name, relationship_to_household_head,
    request_status)
  values (
    v_account.id,
    btrim(p_details ->> 'first_name'),
    nullif(btrim(coalesce(p_details ->> 'middle_names', '')), ''),
    btrim(p_details ->> 'last_name'),
    nullif(btrim(coalesce(p_details ->> 'previous_surname', '')), ''),
    btrim(p_details ->> 'id_number'),
    (p_details ->> 'date_of_birth')::date,
    btrim(p_details ->> 'gender'),
    btrim(p_details ->> 'cellphone_number'),
    btrim(p_details ->> 'house_number'),
    btrim(p_details ->> 'street_address'),
    btrim(p_details ->> 'household_head_name'),
    btrim(p_details ->> 'relationship_to_household_head'),
    'pending')
  returning * into v_request;

  for v_document in select * from jsonb_array_elements(p_documents)
  loop
    insert into public.resident_request_documents (
      request_id, document_type, storage_path, file_name, mime_type, file_size_bytes)
    values (
      v_request.id,
      v_document ->> 'document_type',
      btrim(v_document ->> 'storage_path'),
      btrim(v_document ->> 'file_name'),
      v_document ->> 'mime_type',
      (v_document ->> 'file_size_bytes')::bigint);
  end loop;

  -- Waiting on the Registry Clerk from here.
  update public.user_accounts set account_status = 'pending' where id = v_account.id;

  return jsonb_build_object(
    'request_id',     v_request.id,
    'request_status', v_request.request_status,
    'submitted_at',   v_request.submitted_at,
    'account_status', 'pending');
end;
$$;

-- ---------------------------------------------------------------------
-- 9. The Registry Clerk's queue
-- ---------------------------------------------------------------------

create or replace function public.registry_pending_resident_requests()
returns table (
  request_id      uuid,
  full_name       text,
  id_number       text,
  date_of_birth   date,
  gender          text,
  email           text,
  cellphone_number text,
  house_number    text,
  street_address  text,
  household_head_name text,
  relationship_to_household_head text,
  submitted_at    timestamptz,
  previous_attempts bigint
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.require_registry_clerk();

  return query
    select q.id,
           q.first_name || coalesce(' ' || q.middle_names, '') || ' ' || q.last_name,
           q.id_number, q.date_of_birth, q.gender, ua.email, q.cellphone_number,
           q.house_number, q.street_address,
           q.household_head_name, q.relationship_to_household_head,
           q.submitted_at,
           (select count(*) from public.resident_account_requests earlier
             where earlier.user_account_id = q.user_account_id
               and earlier.submitted_at < q.submitted_at)
    from public.resident_account_requests q
    join public.user_accounts ua on ua.id = q.user_account_id
    where q.request_status = 'pending'
    order by q.submitted_at;
end;
$$;

-- Everything needed to judge one request: what was claimed, the
-- documents, and what this account has tried before.
create or replace function public.registry_resident_request(p_request_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_result jsonb;
begin
  perform public.require_registry_clerk();

  select jsonb_build_object(
    'request_id',      q.id,
    'request_status',  q.request_status,
    'submitted_at',    q.submitted_at,
    'reviewed_at',     q.reviewed_at,
    'decline_reason',  q.decline_reason,
    'account_email',   ua.email,
    'account_status',  ua.account_status,
    'claimed', jsonb_build_object(
      'first_name',       q.first_name,
      'middle_names',     q.middle_names,
      'last_name',        q.last_name,
      'previous_surname', q.previous_surname,
      'full_name',        q.first_name || coalesce(' ' || q.middle_names, '') || ' ' || q.last_name,
      'id_number',        q.id_number,
      'date_of_birth',    q.date_of_birth,
      'gender',           q.gender,
      'cellphone_number', q.cellphone_number,
      'house_number',     q.house_number,
      'street_address',   q.street_address,
      'household_head_name', q.household_head_name,
      'relationship_to_household_head', q.relationship_to_household_head),
    'documents', coalesce((
      select jsonb_agg(jsonb_build_object(
               'document_type',   d.document_type,
               'storage_path',    d.storage_path,
               'file_name',       d.file_name,
               'mime_type',       d.mime_type,
               'file_size_bytes', d.file_size_bytes)
             order by d.document_type)
      from public.resident_request_documents d where d.request_id = q.id), '[]'::jsonb),
    'earlier_attempts', coalesce((
      select jsonb_agg(jsonb_build_object(
               'request_status', e.request_status,
               'submitted_at',   e.submitted_at,
               'reviewed_at',    e.reviewed_at,
               'decline_reason', e.decline_reason)
             order by e.submitted_at desc)
      from public.resident_account_requests e
      where e.user_account_id = q.user_account_id and e.id <> q.id), '[]'::jsonb),
    'matched_resident_id', q.matched_resident_id
  ) into v_result
  from public.resident_account_requests q
  join public.user_accounts ua on ua.id = q.user_account_id
  where q.id = p_request_id;

  if v_result is null then
    raise exception 'That verification request could not be found.' using errcode = 'TA052';
  end if;
  return v_result;
end;
$$;

-- ---------------------------------------------------------------------
-- 10. Finding the official resident this applicant claims to be
--
--     Suggestions only, in the order a clerk would look: the identity
--     number first, then name and birth date, then where they say they
--     live, then who they say heads the household. Nothing here
--     approves anything — the clerk chooses.
-- ---------------------------------------------------------------------

create or replace function public.registry_resident_candidates(p_request_id uuid)
returns table (
  resident_id     uuid,
  full_name       text,
  id_number       text,
  date_of_birth   date,
  gender          text,
  resident_status text,
  household_code  text,
  household_head  text,
  street_address  text,
  already_linked  boolean,
  match_rank      int,
  match_reason    text
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_request public.resident_account_requests;
begin
  perform public.require_registry_clerk();

  select * into v_request from public.resident_account_requests where id = p_request_id;
  if not found then
    raise exception 'That verification request could not be found.' using errcode = 'TA052';
  end if;

  return query
    with scored as (
      select r.id,
             case
               when lower(btrim(r.id_number)) = lower(btrim(v_request.id_number)) then 1
               when lower(r.first_name) = lower(v_request.first_name)
                    and lower(r.last_name) = lower(v_request.last_name)
                    and r.date_of_birth = v_request.date_of_birth then 2
               when s.street_address ilike public.like_pattern(v_request.street_address) then 3
               when head.first_name || ' ' || head.last_name
                    ilike public.like_pattern(v_request.household_head_name) then 4
               when lower(r.last_name) = lower(v_request.last_name)
                    or lower(r.last_name) = lower(coalesce(v_request.previous_surname, '~none~')) then 5
             end as rank,
             r, h, s, head
      from public.residents r
      left join public.households h on h.id = r.household_id
      left join public.land_sites s on s.id = h.residential_site_id
      left join public.residents head on head.id = h.head_resident_id
    )
    select (scored.r).id,
           (scored.r).first_name || ' ' || (scored.r).last_name,
           (scored.r).id_number, (scored.r).date_of_birth, (scored.r).gender,
           (scored.r).resident_status,
           (scored.h).household_code,
           (scored.head).first_name || ' ' || (scored.head).last_name,
           (scored.s).street_address,
           exists (select 1 from public.user_accounts ua where ua.resident_id = (scored.r).id),
           scored.rank,
           case scored.rank
             when 1 then 'Identity number matches exactly'
             when 2 then 'Name and date of birth match'
             when 3 then 'Lives at the address given'
             when 4 then 'Household head matches the name given'
             else 'Surname matches'
           end
    from scored
    where scored.rank is not null
    order by scored.rank, (scored.r).last_name, (scored.r).first_name;
end;
$$;

-- ---------------------------------------------------------------------
-- 11. Approving
--
--     Links the account to a resident record that was already on the
--     register. The register itself is not touched: nothing the
--     applicant typed is copied into it. If their official details are
--     wrong, that is a separate correction the clerk makes with the
--     resident functions.
-- ---------------------------------------------------------------------

create or replace function public.registry_approve_resident_request(
  p_request_id uuid,
  p_resident_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff_id  uuid := public.acting_registry_clerk_staff_id();
  v_request   public.resident_account_requests;
  v_account   public.user_accounts;
  v_resident  public.residents;
  v_household public.households;
begin
  select * into v_request from public.resident_account_requests where id = p_request_id for update;
  if not found then
    raise exception 'That verification request could not be found.' using errcode = 'TA052';
  end if;
  if v_request.request_status <> 'pending' then
    raise exception 'That request has already been %.', v_request.request_status using errcode = 'TA052';
  end if;

  select * into v_account from public.user_accounts where id = v_request.user_account_id for update;
  if v_account.account_status <> 'pending' then
    raise exception 'That applicant''s account is % and is no longer awaiting verification.',
      v_account.account_status using errcode = 'TA056';
  end if;

  select * into v_resident from public.residents where id = p_resident_id;
  if not found then
    raise exception 'Choose the official resident record this applicant matches.' using errcode = 'TA031';
  end if;
  if v_resident.resident_status <> 'active' then
    raise exception '% is recorded as % on the register and cannot be given an account.',
      v_resident.first_name || ' ' || v_resident.last_name, v_resident.resident_status
      using errcode = 'TA053';
  end if;

  -- An account is an account for someone who lives somewhere. If the
  -- register does not yet say where, that is fixed first.
  if v_resident.household_id is null then
    raise exception '% is not linked to a household yet. Link them to their household first, then approve.',
      v_resident.first_name || ' ' || v_resident.last_name
      using errcode = 'TA054';
  end if;

  select * into v_household from public.households where id = v_resident.household_id;
  if not found or v_household.household_status <> 'active' then
    raise exception 'The household % belongs to is not current. Correct that first, then approve.',
      v_resident.first_name || ' ' || v_resident.last_name
      using errcode = 'TA054';
  end if;

  if exists (select 1 from public.user_accounts ua
              where ua.resident_id = v_resident.id and ua.id <> v_account.id) then
    raise exception '% already has a resident account.',
      v_resident.first_name || ' ' || v_resident.last_name
      using errcode = 'TA055';
  end if;

  update public.user_accounts
     set resident_id = v_resident.id,
         account_status = 'active'
   where id = v_account.id;

  update public.resident_account_requests
     set request_status = 'approved',
         matched_resident_id = v_resident.id,
         reviewed_by_staff_id = v_staff_id,
         reviewed_at = now()
   where id = v_request.id;

  return jsonb_build_object(
    'request_id',     v_request.id,
    'request_status', 'approved',
    'account_status', 'active',
    'resident_id',    v_resident.id,
    'resident_name',  v_resident.first_name || ' ' || v_resident.last_name,
    'household_code', v_household.household_code);
end;
$$;

-- ---------------------------------------------------------------------
-- 12. Declining
--
--     Nothing is deleted. The applicant keeps their sign-in, sees why,
--     and applies again with the same account.
-- ---------------------------------------------------------------------

create or replace function public.registry_decline_resident_request(
  p_request_id uuid,
  p_reason     text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff_id uuid := public.acting_registry_clerk_staff_id();
  v_reason   text := btrim(coalesce(p_reason, ''));
  v_request  public.resident_account_requests;
begin
  if v_reason = '' then
    raise exception 'A reason is required, so the applicant knows what to correct.' using errcode = 'TA018';
  end if;
  if length(v_reason) > 500 then
    raise exception 'The reason is too long (500 characters at most).' using errcode = 'TA018';
  end if;

  select * into v_request from public.resident_account_requests where id = p_request_id for update;
  if not found then
    raise exception 'That verification request could not be found.' using errcode = 'TA052';
  end if;
  if v_request.request_status <> 'pending' then
    raise exception 'That request has already been %.', v_request.request_status using errcode = 'TA052';
  end if;

  update public.resident_account_requests
     set request_status = 'declined',
         decline_reason = v_reason,
         reviewed_by_staff_id = v_staff_id,
         reviewed_at = now()
   where id = v_request.id;

  -- The account stays, unlinked, so they can put it right and reapply.
  update public.user_accounts
     set account_status = 'declined'
   where id = v_request.user_account_id;

  return jsonb_build_object(
    'request_id',     v_request.id,
    'request_status', 'declined',
    'account_status', 'declined',
    'decline_reason', v_reason);
end;
$$;

-- The acting clerk's staff id, for the review record.
create or replace function public.acting_registry_clerk_staff_id()
returns uuid
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff_id uuid;
begin
  select s.id into v_staff_id
  from public.user_accounts ua
  join public.staff s on s.id = ua.staff_id
  join public.roles r on r.id = s.role_id
  where ua.auth_user_id = auth.uid()
    and ua.account_type = 'staff'
    and ua.account_status = 'active'
    and r.role_name = 'Registry Clerk';

  if v_staff_id is null then
    raise exception 'Only an active Registry Clerk may review verification requests.'
      using errcode = '42501';
  end if;
  return v_staff_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 13. Grants
-- ---------------------------------------------------------------------

do $$
declare
  v_signature text;
begin
  foreach v_signature in array array[
    'public.resident_ensure_account()',
    'public.resident_portal()',
    'public.resident_submit_verification_request(jsonb, jsonb)',
    'public.registry_pending_resident_requests()',
    'public.registry_resident_request(uuid)',
    'public.registry_resident_candidates(uuid)',
    'public.registry_approve_resident_request(uuid, uuid)',
    'public.registry_decline_resident_request(uuid, text)'
  ]
  loop
    execute format('revoke all on function %s from public, anon, authenticated', v_signature);
    execute format('grant execute on function %s to authenticated', v_signature);
  end loop;
end;
$$;

revoke all on function public.acting_registry_clerk_staff_id() from public, anon, authenticated;
