-- G Club availability: database schema and the public functions the page calls.
--
-- Tables live in a private schema (gclub) that the public API never exposes.
-- The page only calls the gc_* functions at the bottom. Each one checks its
-- input, and anything that changes the gathering itself needs the organiser key.
-- Only a SHA-256 hash of that key is stored.

create schema if not exists gclub;

create table if not exists gclub.events (
  id          text primary key check (id ~ '^[a-z0-9-]{1,40}$'),
  admin_hash  text not null,
  title       text not null default 'G Club gathering',
  blurb       text not null default '',
  "when"      text not null default '',
  "where"     text not null default '',
  roster      jsonb not null default '[]'::jsonb,
  dates       jsonb not null default '[]'::jsonb,
  confirmed   text,
  updated_at  timestamptz not null default now()
);

create table if not exists gclub.responses (
  event_id    text not null references gclub.events (id) on delete cascade,
  slug        text not null check (slug ~ '^[A-Za-z0-9_.~:@+-]{1,190}$'),
  name        text not null check (char_length(name) between 1 and 40),
  answers     jsonb not null default '{}'::jsonb,
  note        text not null default '' check (char_length(note) <= 280),
  updated_at  timestamptz not null default now(),
  primary key (event_id, slug)
);

-- No policies on purpose: with row level security on, the API roles see nothing.
alter table gclub.events enable row level security;
alter table gclub.responses enable row level security;
revoke all on schema gclub from public, anon, authenticated;
revoke all on all tables in schema gclub from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Helpers (private schema, not callable from the API)
-- ---------------------------------------------------------------------------

create or replace function gclub.is_admin(p_event text, p_admin text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce(p_admin, '') <> '' and exists (
    select 1 from gclub.events e
    where e.id = p_event
      and e.admin_hash = encode(sha256(convert_to(p_admin, 'UTF8')), 'hex')
  );
$$;
revoke all on function gclub.is_admin(text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Public functions (what the page calls)
-- ---------------------------------------------------------------------------

-- Everything the page needs in one call. Returns null if the event is unknown.
create or replace function public.gc_get(p_event text, p_admin text default null)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  ev gclub.events%rowtype;
begin
  select * into ev from gclub.events where id = p_event;
  if not found then
    return null;
  end if;
  return jsonb_build_object(
    'admin', gclub.is_admin(p_event, p_admin),
    'config', jsonb_build_object(
      'title', ev.title, 'blurb', ev.blurb, 'when', ev."when", 'where', ev."where",
      'roster', ev.roster, 'dates', ev.dates, 'confirmed', ev.confirmed
    ),
    'people', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', r.slug, 'name', r.name, 'answers', r.answers, 'note', r.note,
               'updatedAt', (extract(epoch from r.updated_at) * 1000)::bigint
             ) order by lower(r.name), r.slug)
      from gclub.responses r where r.event_id = p_event
    ), '[]'::jsonb)
  );
end;
$$;

-- Anyone with the link can add or update a reply. Only known dates and the
-- values y / m / n are kept.
create or replace function public.gc_submit(
  p_event text, p_slug text, p_name text, p_answers jsonb, p_note text default ''
)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  ev        gclub.events%rowtype;
  v_name    text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
  v_note    text := left(btrim(coalesce(p_note, '')), 280);
  v_answers jsonb := '{}'::jsonb;
  r         record;
  v_count   int;
begin
  select * into ev from gclub.events where id = p_event;
  if not found then raise exception 'no_such_event'; end if;
  if char_length(v_name) not between 1 and 40 then raise exception 'bad_name'; end if;
  if p_slug is null or p_slug !~ '^[A-Za-z0-9_.~:@+-]{1,190}$' then raise exception 'bad_slug'; end if;
  if jsonb_typeof(p_answers) is distinct from 'object' then raise exception 'bad_answers'; end if;

  for r in select key, value from jsonb_each_text(p_answers) loop
    if jsonb_exists(ev.dates, r.key) and r.value in ('y', 'm', 'n') then
      v_answers := v_answers || jsonb_build_object(r.key, r.value);
    end if;
  end loop;
  if v_answers = '{}'::jsonb then raise exception 'no_answers'; end if;

  if not exists (select 1 from gclub.responses where event_id = p_event and slug = p_slug) then
    select count(*) into v_count from gclub.responses where event_id = p_event;
    if v_count >= 300 then raise exception 'event_full'; end if;
  end if;

  insert into gclub.responses (event_id, slug, name, answers, note, updated_at)
  values (p_event, p_slug, v_name, v_answers, v_note, now())
  on conflict (event_id, slug) do update
    set name = excluded.name, answers = excluded.answers, note = excluded.note, updated_at = now();

  return jsonb_build_object('ok', true);
end;
$$;

-- Organiser only: title, text, member list and candidate dates.
create or replace function public.gc_save_event(p_event text, p_admin text, p_config jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  ev       gclub.events%rowtype;
  v_title  text;
  v_dates  jsonb;
  v_roster jsonb;
  v_conf   text;
begin
  if not gclub.is_admin(p_event, p_admin) then raise exception 'not_admin'; end if;
  if jsonb_typeof(p_config) is distinct from 'object' then raise exception 'bad_config'; end if;
  select * into ev from gclub.events where id = p_event;

  v_title := left(btrim(coalesce(p_config ->> 'title', '')), 80);
  if v_title = '' then v_title := 'G Club gathering'; end if;

  select coalesce(jsonb_agg(d order by d), '[]'::jsonb) into v_dates
  from (
    select distinct x as d
    from jsonb_array_elements_text(
           case when jsonb_typeof(p_config -> 'dates') = 'array' then p_config -> 'dates' else '[]'::jsonb end
         ) as x
    where x ~ '^\d{4}-\d{2}-\d{2}$'
    limit 60
  ) s;

  select coalesce(jsonb_agg(n order by i), '[]'::jsonb) into v_roster
  from (
    select btrim(x) as n, i
    from jsonb_array_elements_text(
           case when jsonb_typeof(p_config -> 'roster') = 'array' then p_config -> 'roster' else '[]'::jsonb end
         ) with ordinality as t(x, i)
    where char_length(btrim(x)) between 1 and 40
    order by i
    limit 150
  ) s;

  v_conf := case when ev.confirmed is not null and jsonb_exists(v_dates, ev.confirmed)
                 then ev.confirmed end;

  update gclub.events
     set title = v_title,
         blurb = left(btrim(coalesce(p_config ->> 'blurb', '')), 400),
         "when" = left(btrim(coalesce(p_config ->> 'when', '')), 80),
         "where" = left(btrim(coalesce(p_config ->> 'where', '')), 80),
         roster = v_roster, dates = v_dates, confirmed = v_conf, updated_at = now()
   where id = p_event;

  return jsonb_build_object('ok', true);
end;
$$;

-- Organiser only: lock in a date, or pass null to unlock.
create or replace function public.gc_lock(p_event text, p_admin text, p_date text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
begin
  if not gclub.is_admin(p_event, p_admin) then raise exception 'not_admin'; end if;
  if p_date is not null and not exists (
       select 1 from gclub.events where id = p_event and jsonb_exists(dates, p_date)
     ) then
    raise exception 'bad_date';
  end if;
  update gclub.events set confirmed = p_date, updated_at = now() where id = p_event;
  return jsonb_build_object('ok', true);
end;
$$;

-- Organiser only: remove someone's reply.
create or replace function public.gc_remove(p_event text, p_admin text, p_slug text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
begin
  if not gclub.is_admin(p_event, p_admin) then raise exception 'not_admin'; end if;
  delete from gclub.responses where event_id = p_event and slug = p_slug;
  return jsonb_build_object('ok', true);
end;
$$;

grant usage on schema public to anon, authenticated;
revoke all on function public.gc_get(text, text) from public;
revoke all on function public.gc_submit(text, text, text, jsonb, text) from public;
revoke all on function public.gc_save_event(text, text, jsonb) from public;
revoke all on function public.gc_lock(text, text, text) from public;
revoke all on function public.gc_remove(text, text, text) from public;
grant execute on function public.gc_get(text, text) to anon, authenticated;
grant execute on function public.gc_submit(text, text, text, jsonb, text) to anon, authenticated;
grant execute on function public.gc_save_event(text, text, jsonb) to anon, authenticated;
grant execute on function public.gc_lock(text, text, text) to anon, authenticated;
grant execute on function public.gc_remove(text, text, text) to anon, authenticated;
