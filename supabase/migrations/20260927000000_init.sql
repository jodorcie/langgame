-- ============================================================================
-- BOMA: Pastoralist Language Strategy — Initial Schema (MVP)
-- Target: Supabase / PostgreSQL 15+
-- ============================================================================
-- Conventions:
--   * auth.users is provided by Supabase Auth; we never recreate it.
--   * player_bomas.id is used as "boma_id" throughout the schema.
--   * vocabulary.id is used as "phrase_id" throughout the schema.
--   * All money-like / game-state mutations that cross trust boundaries go
--     through SECURITY DEFINER RPCs callable only by authenticated users.
-- ============================================================================

create extension if not exists pgcrypto;

-- ----------------------------------------------------------------------------
-- Enums
-- ----------------------------------------------------------------------------
create type phrase_status as enum ('pending', 'verified', 'flagged');
create type animal_type   as enum ('cow', 'goat', 'bull', 'calf', 'kid');
create type health_status as enum ('healthy', 'hungry', 'sick', 'quarantined');

-- ----------------------------------------------------------------------------
-- 1. player_bomas  (1:1 profile extension of auth.users)
-- ----------------------------------------------------------------------------
create table if not exists public.player_bomas (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null unique references auth.users (id) on delete cascade,
  clan_name     text not null check (char_length(clan_name) between 3 and 24),
  boma_tier     smallint not null default 1 check (boma_tier between 1 and 5),
  fence_level   smallint not null default 1 check (fence_level between 1 and 10),
  -- Milk/Energy: soft currency produced by healthy cattle, spent on raids.
  milk_energy   integer  not null default 50 check (milk_energy >= 0),
  -- Raid immunity window; prevents compounding consecutive losses.
  shield_until  timestamptz not null default now(),
  trophies      integer  not null default 0 check (trophies >= 0),
  reputation    integer  not null default 0 check (reputation >= 0),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index if not exists idx_player_bomas_shield  on public.player_bomas (shield_until);
create index if not exists idx_player_bomas_trophy  on public.player_bomas (trophies desc);

-- ----------------------------------------------------------------------------
-- 2. vocabulary  (crowdsourced words/phrases — the "seed stock" of the game)
-- ----------------------------------------------------------------------------
create table if not exists public.vocabulary (
  id              uuid primary key default gen_random_uuid(),
  contributor_id  uuid not null references auth.users (id) on delete cascade,
  language_code   text not null,                       -- e.g. 'mas' (Maa), 'sox' (Dholuo), 'sw'
  source_text     text not null check (char_length(source_text) <= 500),
  translated_text text not null check (char_length(translated_text) <= 500),
  audio_url       text,                                -- public URL in Storage bucket 'pronunciation-audio'
  category        text not null default 'livestock'
                  check (category in ('livestock', 'flora', 'fauna', 'tools', 'idioms', 'kinship')),
  status          phrase_status not null default 'pending',
  upvotes         integer not null default 0 check (upvotes   >= 0),
  downvotes       integer not null default 0 check (downvotes >= 0),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index if not exists idx_vocab_status_lang on public.vocabulary (status, language_code);
create index if not exists idx_vocab_contributor on public.vocabulary (contributor_id);
-- Feed query for the Council review queue: pending items, oldest first.
create index if not exists idx_vocab_pending_feed
  on public.vocabulary (created_at) where status = 'pending';

-- ----------------------------------------------------------------------------
-- 3. phrase_validations  (peer-review audit trail / consensus ledger)
-- ----------------------------------------------------------------------------
create table if not exists public.phrase_validations (
  id          bigint generated always as identity primary key,
  phrase_id   uuid not null references public.vocabulary (id) on delete cascade,
  reviewer_id uuid not null references auth.users (id)       on delete cascade,
  is_accurate boolean not null,
  notes       text check (notes is null or char_length(notes) <= 500),
  created_at  timestamptz not null default now(),
  -- One verdict per reviewer per phrase (the edge function UPSERTs on this).
  constraint uq_validation_reviewer unique (phrase_id, reviewer_id)
);

-- Elders cannot judge their own submissions (subquery form: CHECK constraints
-- forbid sub-selects, so enforce with a row trigger instead).
create or replace function public.trg_no_self_review()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if exists (select 1 from public.vocabulary v
             where v.id = new.phrase_id
               and v.contributor_id = new.reviewer_id) then
    raise exception 'elders cannot review their own submissions';
  end if;
  return new;
end $$;

drop trigger if exists no_self_review on public.phrase_validations;
create trigger no_self_review
  before insert or update on public.phrase_validations
  for each row execute function public.trg_no_self_review();

create index if not exists idx_validations_phrase on public.phrase_validations (phrase_id);

-- ----------------------------------------------------------------------------
-- 4. herd_animals  (validated vocabulary bound to living livestock)
-- ----------------------------------------------------------------------------
create table if not exists public.herd_animals (
  id                uuid primary key default gen_random_uuid(),
  boma_id           uuid not null references public.player_bomas (id) on delete cascade,
  phrase_id         uuid not null references public.vocabulary (id)   on delete restrict,
  animal_type       animal_type   not null default 'calf',
  health_status     health_status not null default 'healthy',
  -- ---- SM-2 state (Modified SuperMemo-2) ----
  next_review_at    timestamptz not null default now(),
  interval_days     real        not null default 1.0 check (interval_days > 0),
  ease_factor       real        not null default 2.5 check (ease_factor >= 1.3),
  repetition_count  smallint    not null default 0 check (repetition_count >= 0),
  -- ---- Passive production ("milked" by claim_milk RPC) ----
  last_fed_at       timestamptz not null default now(),
  acquired_at       timestamptz not null default now()
);

-- A word may be owned by at most one herd at a time (prevents raid duplication).
create unique index if not exists uq_herd_phrase on public.herd_animals (phrase_id);
-- Grazing-run feed: "which of my animals are due?"
create index if not exists idx_herd_due
  on public.herd_animals (boma_id, next_review_at) where health_status <> 'quarantined';
create index if not exists idx_herd_boma_summary on public.herd_animals (boma_id, health_status);

-- ----------------------------------------------------------------------------
-- 5. boma_defenses  (the defender's 5 "trap cards")
-- ----------------------------------------------------------------------------
create table if not exists public.boma_defenses (
  boma_id    uuid not null references public.player_bomas (id) on delete cascade,
  slot_index smallint not null check (slot_index between 1 and 5),
  phrase_id  uuid not null references public.vocabulary (id)   on delete cascade,
  updated_at timestamptz not null default now(),
  primary key (boma_id, slot_index)
);

create index if not exists idx_defense_phrase on public.boma_defenses (phrase_id);

-- ----------------------------------------------------------------------------
-- 6. raid_logs  (immutable battle history)
-- ----------------------------------------------------------------------------
create table if not exists public.raid_logs (
  id               uuid primary key default gen_random_uuid(),
  attacker_id      uuid not null references auth.users (id) on delete cascade,
  defender_id      uuid not null references auth.users (id) on delete cascade,
  success          boolean not null,
  livestock_stolen smallint not null default 0 check (livestock_stolen >= 0),
  energy_spent     integer not null default 0,
  duration_secs    integer,                                -- how long the decryption took
  created_at       timestamptz not null default now(),
  check (attacker_id <> defender_id)                        -- you cannot raid your own boma
);

create index if not exists idx_raid_attacker  on public.raid_logs (attacker_id, created_at desc);
create index if not exists idx_raid_defender  on public.raid_logs (defender_id, created_at desc);

-- ----------------------------------------------------------------------------
-- 7. Storage bucket for pronunciation clips (.m4a / .ogg)
-- ----------------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('pronunciation-audio', 'pronunciation-audio', true)
on conflict (id) do nothing;

-- Public read (audio must be playable by anonymous clients during drills/raids).
drop policy if exists "Audio is publicly readable" on storage.objects;
create policy "Audio is publicly readable"
  on storage.objects for select
  using (bucket_id = 'pronunciation-audio');

-- Users may upload their own clip under <user_id>/... paths.
drop policy if exists "Users upload own audio" on storage.objects;
create policy "Users upload own audio"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'pronunciation-audio'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- Users may replace/delete their own clips.
drop policy if exists "Users manage own audio" on storage.objects;
create policy "Users manage own audio"
  on storage.objects for update to authenticated
  using (bucket_id = 'pronunciation-audio' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "Users delete own audio" on storage.objects;
create policy "Users delete own audio"
  on storage.objects for delete to authenticated
  using (bucket_id = 'pronunciation-audio' and (storage.foldername(name))[1] = auth.uid()::text);

-- ============================================================================
-- ROW LEVEL SECURITY
-- ============================================================================
alter table public.player_bomas     enable row level security;
alter table public.vocabulary       enable row level security;
alter table public.phrase_validations enable row level security;
alter table public.herd_animals     enable row level security;
alter table public.boma_defenses    enable row level security;
alter table public.raid_logs        enable row level security;

-- ---- player_bomas -----------------------------------------------------------
-- Everyone can scout any boma (public leaderboard + raid targeting).
drop policy if exists "Bomas are readable by all" on public.player_bomas;
create policy "Bomas are readable by all"
  on public.player_bomas for select using (true);

-- Only the owner creates their own homestead record.
drop policy if exists "Owners insert own boma" on public.player_bomas;
create policy "Owners insert own boma"
  on public.player_bomas for insert to authenticated
  with check (auth.uid() = user_id);

-- Direct updates are restricted to cosmetic/safe fields; economy fields
-- (milk_energy, trophies, reputation, shield_until) are ONLY mutated via
-- SECURITY DEFINER RPCs below, so clients can never mint currency.
drop policy if exists "Owners update safe boma fields" on public.player_bomas;
create policy "Owners update safe boma fields"
  on public.player_bomas for update to authenticated
  using (auth.uid() = user_id)
  with check (
    auth.uid() = user_id
    and milk_energy = (select p.milk_energy from public.player_bomas p where p.user_id = auth.uid())
    and trophies    = (select p.trophies    from public.player_bomas p where p.user_id = auth.uid())
    and reputation  = (select p.reputation  from public.player_bomas p where p.user_id = auth.uid())
  );

-- ---- vocabulary --------------------------------------------------------------
drop policy if exists "Phrases are readable by all" on public.vocabulary;
create policy "Phrases are readable by all"
  on public.vocabulary for select using (true);

-- Contributors create their own submissions, always starting 'pending'.
drop policy if exists "Contributors submit phrases" on public.vocabulary;
create policy "Contributors submit phrases"
  on public.vocabulary for insert to authenticated
  with check (auth.uid() = contributor_id and status = 'pending');

-- Contributors may edit their own text/audio while still pending.
drop policy if exists "Contributors edit own pending phrases" on public.vocabulary;
create policy "Contributors edit own pending phrases"
  on public.vocabulary for update to authenticated
  using (auth.uid() = contributor_id and status = 'pending')
  with check (auth.uid() = contributor_id and status = 'pending');

-- Status/vote transitions happen exclusively inside the edge function
-- (service_role bypasses RLS) and the RPCs below. No client DELETE allowed.

-- ---- phrase_validations -------------------------------------------------------
drop policy if exists "Validations are readable by all" on public.phrase_validations;
create policy "Validations are readable by all"
  on public.phrase_validations for select using (true);

-- Reviews are written ONLY by the review_submission edge function.
-- (Insert policy kept as defense-in-depth: even a direct client insert is
--  limited to one's own reviewer_id, non-self-review, pending phrases.)
drop policy if exists "Elders cast own validation" on public.phrase_validations;
create policy "Elders cast own validation"
  on public.phrase_validations for insert to authenticated
  with check (
    auth.uid() = reviewer_id
    and exists (
      select 1 from public.vocabulary v
      where v.id = phrase_id
        and v.status = 'pending'
        and v.contributor_id <> auth.uid()
    )
  );

-- ---- herd_animals ---------------------------------------------------------------
-- Herds are visible to everyone (opponents estimate your wealth before raiding).
drop policy if exists "Herds are readable by all" on public.herd_animals;
create policy "Herds are readable by all"
  on public.herd_animals for select using (true);

-- Owners conduct grazing drills: they may only advance SRS state & feeding
-- timestamps of their OWN animals. Health transitions themselves are also
-- mirrored server-side by apply_srs_review() for authoritative consistency.
drop policy if exists "Owners tend own herd" on public.herd_animals;
create policy "Owners tend own herd"
  on public.herd_animals for update to authenticated
  using (exists (select 1 from public.player_bomas b
                 where b.id = herd_animals.boma_id and b.user_id = auth.uid()))
  with check (exists (select 1 from public.player_bomas b
                 where b.id = herd_animals.boma_id and b.user_id = auth.uid()));

-- INSERT/DELETE on herds is forbidden to clients: calves are minted by the
-- consensus function, and transfers occur only via resolve_raid().

-- ---- boma_defenses ----------------------------------------------------------------
drop policy if exists "Defenses are readable by all" on public.boma_defenses;
create policy "Defenses are readable by all"
  on public.boma_defenses for select using (true);

-- Users can only mutate their OWN defense slots, and only with VERIFIED phrases.
drop policy if exists "Owners set own verified defenses" on public.boma_defenses;
create policy "Owners set own verified defenses"
  on public.boma_defenses for insert to authenticated
  with check (
    exists (select 1 from public.player_bomas b
            where b.id = boma_defenses.boma_id and b.user_id = auth.uid())
    and exists (select 1 from public.vocabulary v
                where v.id = boma_defenses.phrase_id and v.status = 'verified')
  );

drop policy if exists "Owners update own verified defenses" on public.boma_defenses;
create policy "Owners update own verified defenses"
  on public.boma_defenses for update to authenticated
  using (exists (select 1 from public.player_bomas b
                 where b.id = boma_defenses.boma_id and b.user_id = auth.uid()))
  with check (exists (select 1 from public.player_bomas b
                 where b.id = boma_defenses.boma_id and b.user_id = auth.uid()));

drop policy if exists "Owners clear own defenses" on public.boma_defenses;
create policy "Owners clear own defenses"
  on public.boma_defenses for delete to authenticated
  using (exists (select 1 from public.player_bomas b
                 where b.id = boma_defenses.boma_id and b.user_id = auth.uid()));

-- ---- raid_logs ----------------------------------------------------------------------
-- Attackers and defenders can see their own battles; aggregate stats are public.
drop policy if exists "Participants read own raids" on public.raid_logs;
create policy "Participants read own raids"
  on public.raid_logs for select to authenticated
  using (auth.uid() in (attacker_id, defender_id));

-- raid_logs are written ONLY by resolve_raid() (SECURITY DEFINER).

-- ============================================================================
-- RPCs (SECURITY DEFINER — atomic, server-authoritative game actions)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- register_player_boma(): idempotent creation of the homestead row after signup.
-- ----------------------------------------------------------------------------
create or replace function public.register_player_boma(p_clan_name text)
returns public.player_bomas
language plpgsql security definer set search_path = public
as $$
declare
  v_row public.player_bomas;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  insert into public.player_bomas (user_id, clan_name)
  values (auth.uid(), p_clan_name)
  on conflict (user_id) do update
    set clan_name = excluded.clan_name, updated_at = now()
  returning * into v_row;

  return v_row;
end $$;

-- ----------------------------------------------------------------------------
-- apply_srs_review(): authoritative SM-2 write-back for one animal.
-- Mirrors the pure Dart engine (lib/domain/srs/sm2_engine.dart) so the server
-- stays the source of truth even if a client tampers with its local math.
--   q ∈ [0..5]; q < 3 resets reps and marks the animal sick.
-- ----------------------------------------------------------------------------
create or replace function public.apply_srs_review(
  p_animal_id uuid,
  p_quality   smallint
)
returns table (
  ease_factor      real,
  interval_days    real,
  repetition_count smallint,
  next_review_at   timestamptz,
  health_status    health_status
)
language plpgsql security definer set search_path = public
as $$
declare
  v_animal   public.herd_animals%rowtype;
  v_ef       real;
  v_interval real;
  v_reps     smallint;
  v_health   health_status;
begin
  select * into v_animal from public.herd_animals where id = p_animal_id
    for update;
  if not found then
    raise exception 'animal % not found', p_animal_id;
  end if;
  -- Ownership check: caller must own the boma this animal grazes in.
  if not exists (select 1 from public.player_bomas b
                 where b.id = v_animal.boma_id and b.user_id = auth.uid()) then
    raise exception 'not permitted to review this animal';
  end if;
  if p_quality not between 0 and 5 then
    raise exception 'quality must be 0..5';
  end if;

  v_ef   := v_animal.ease_factor;
  v_reps := v_animal.repetition_count;

  if p_quality < 3 then
    -- Failed recall: reset repetitions, animal falls ill.
    v_reps     := 0;
    v_interval := 1;
    v_health   := 'sick';
  else
    v_health := 'healthy';
    case v_reps
      when 0 then v_interval := 1;
      when 1 then v_interval := 6;
      else        v_interval := v_interval * v_ef;
    end case;
    v_reps := v_reps + 1;
  end if;

  -- Canonical SM-2 ease-factor update (floor clamped at 1.3).
  v_ef := greatest(1.3,
                   v_ef + (0.1 - (5 - p_quality) * (0.08 + (5 - p_quality) * 0.02)));

  update public.herd_animals h
     set ease_factor      = round(v_ef::numeric, 2)::real,
         interval_days    = round(v_interval::numeric, 2)::real,
         repetition_count = v_reps,
         health_status    = v_health,
         -- next_review_at = now + interval_days (fractional days preserved)
         next_review_at   = now() + make_interval(
                              days => floor(v_interval)::int,
                              mins => ((v_interval - floor(v_interval)) * 24 * 60)::int),
         last_fed_at      = now()
   where h.id = p_animal_id
  returning h.ease_factor, h.interval_days, h.repetition_count,
            h.next_review_at, h.health_status
     into ease_factor, interval_days, repetition_count, next_review_at, health_status;

  return next;
end $$;

-- ----------------------------------------------------------------------------
-- claim_milk(): passive production. Each healthy, up-to-date animal yields
-- milk proportional to its interval since its last collection. Sick/hungry
-- animals produce nothing and decay toward quarantine (handled by cron below).
-- ----------------------------------------------------------------------------
create or replace function public.claim_milk()
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  v_boma   public.player_bomas%rowtype;
  v_gain   integer;
begin
  select * into v_boma from public.player_bomas
   where user_id = auth.uid() for update;
  if not found then
    raise exception 'no boma registered';
  end if;

  select coalesce(sum(greatest(1, floor(interval_days)::int)), 0)
    into v_gain
    from public.herd_animals
   where boma_id = v_boma.id
     and health_status = 'healthy'
     and last_fed_at < now() - interval '6 hours';

  update public.herd_animals
     set last_fed_at = now()
   where boma_id = v_boma.id
     and health_status = 'healthy'
     and last_fed_at < now() - interval '6 hours';

  update public.player_bomas
     set milk_energy = milk_energy + v_gain, updated_at = now()
   where id = v_boma.id;

  return v_gain;
end $$;

-- ----------------------------------------------------------------------------
-- begin_raid(): validates eligibility and atomically escrows raid cost.
-- Returns the defense configuration the attacker must decrypt client-side.
-- ----------------------------------------------------------------------------
create or replace function public.begin_raid(p_target_boma_id uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_attacker public.player_bomas%rowtype;
  v_defender public.player_bomas%rowtype;
  v_cost     integer;
  v_window   integer;
  v_defs     jsonb;
begin
  select * into v_attacker from public.player_bomas
   where user_id = auth.uid() for update;
  if not found then raise exception 'no boma registered'; end if;

  select * into v_defender from public.player_bomas
   where id = p_target_boma_id for update;
  if not found then raise exception 'target boma not found'; end if;
  if v_defender.user_id = auth.uid() then
    raise exception 'cannot raid your own boma';
  end if;
  if v_defender.shield_until > now() then
    raise exception 'TARGET_SHIELDED';
  end if;

  -- Cost scales with defender fence_level; must be covered by milk_energy.
  v_cost := 10 * v_defender.fence_level;
  if v_attacker.milk_energy < v_cost then
    raise exception 'INSUFFICIENT_MILK';
  end if;

  select count(*) into v_defs
    from public.herd_animals where boma_id = p_target_boma_id;
  if v_defs = 0 then
    raise exception 'TARGET_HAS_NO_HERD';
  end if;

  -- Escrow the energy now; refunded partially on failure inside resolve_raid.
  update public.player_bomas
     set milk_energy = milk_energy - v_cost, updated_at = now()
   where id = v_attacker.id;

  -- Time limit grows with defender fence strength (harder walls, more clock).
  v_window := 45 + v_defender.fence_level * 15;

  select jsonb_agg(jsonb_build_object(
           'slot_index', d.slot_index,
           'phrase_id',  d.phrase_id,
           'source_text', v.source_text,
           'translated_text', v.translated_text,
           'audio_url', v.audio_url
         ) order by d.slot_index)
    into v_defs
    from public.boma_defenses d
    join public.vocabulary v on v.id = d.phrase_id
   where d.boma_id = p_target_boma_id
     and v.status = 'verified';

  return jsonb_build_object(
    'raid_cost',        v_cost,
    'time_limit_secs',  v_window,
    'defender_boma_id', v_defender.id,
    'defender_clan',    v_defender.clan_name,
    'herd_size',        (select count(*) from public.herd_animals
                          where boma_id = p_target_boma_id
                            and health_status <> 'quarantined'),
    'defense_phrases',  coalesce(v_defs, '[]'::jsonb)
  );
end $$;

-- ----------------------------------------------------------------------------
-- resolve_raid(): finalizes a raid.
--   SUCCESS : transfer ROUND(10%) of defender's non-quarantined animals
--             (oldest-reviewed first), grant defender a 12h shield, log it.
--   FAILURE : energy was already consumed by begin_raid; defender earns
--             defense trophies scaled by fence_level.
-- ----------------------------------------------------------------------------
create or replace function public.resolve_raid(
  p_target_boma_id uuid,
  p_success        boolean,
  p_duration_secs  integer default null
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_attacker public.player_bomas%rowtype;
  v_defender public.player_bomas%rowtype;
  v_stolen   smallint := 0;
  v_trophy   integer;
  v_animal   record;
begin
  select * into v_attacker from public.player_bomas
   where user_id = auth.uid() for update;
  if not found then raise exception 'no boma registered'; end if;

  select * into v_defender from public.player_bomas
   where id = p_target_boma_id for update;
  if not found then raise exception 'target boma not found'; end if;
  if v_defender.user_id = auth.uid() then
    raise exception 'cannot raid your own boma';
  end if;

  if p_success then
    -- 10% of non-quarantined livestock, minimum 0 (small herds may yield none).
    select floor(count(*) * 0.10)::int into v_stolen
      from public.herd_animals
     where boma_id = v_defender.id
       and health_status <> 'quarantined';

    -- Transfer weakest-first: animals most overdue for review change barns.
    for v_animal in
      select id from public.herd_animals
       where boma_id = v_defender.id
         and health_status <> 'quarantined'
       order by next_review_at asc
       limit v_stolen
       for update
    loop
      update public.herd_animals
         set boma_id = v_attacker.id,
             health_status = 'hungry',      -- stolen beasts need re-grazing
             next_review_at = least(next_review_at, now())
       where id = v_animal.id;
    end loop;

    -- 12-hour immunity so the defender cannot be chain-farmed.
    update public.player_bomas
       set shield_until = now() + interval '12 hours',
           updated_at   = now()
     where id = v_defender.id;
  else
    v_trophy := 1 + v_defender.fence_level;
    update public.player_bomas
       set trophies = trophies + v_trophy, updated_at = now()
     where id = v_defender.id;
  end if;

  insert into public.raid_logs
    (attacker_id, defender_id, success, livestock_stolen, energy_spent, duration_secs)
  values
    (auth.uid(), v_defender.user_id, p_success, v_stolen,
     10 * v_defender.fence_level, p_duration_secs);

  return jsonb_build_object('success', p_success, 'livestock_stolen', v_stolen);
end $$;

-- ----------------------------------------------------------------------------
-- graze_decay_tick(): nightly housekeeping (call from pg_cron or an Edge cron).
-- Healthy-but-overdue animals become hungry; hungry ones lapse to sick.
-- ----------------------------------------------------------------------------
create or replace function public.graze_decay_tick()
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  v_n integer;
begin
  with hunger as (
    update public.herd_animals
       set health_status = 'hungry'
     where health_status = 'healthy'
       and next_review_at < now() - interval '2 days'
    returning 1
  ), sickness as (
    update public.herd_animals
       set health_status = 'sick'
     where health_status = 'hungry'
       and next_review_at < now() - interval '5 days'
    returning 1
  )
  select (select count(*) from hunger) + (select count(*) from sickness) into v_n;
  return v_n;
end $$;

-- Lock down direct execution to authenticated players only (not anon).
revoke execute on all functions in schema public from anon;
grant  execute on all functions in schema public to authenticated;
