-- ============================================================================
-- Boma MVP addendum: player inventory (consumable shield tokens granted by
-- the review_submission consensus function; consumed to extend shield_until).
-- ============================================================================
create table if not exists public.player_inventory (
  boma_id    uuid not null references public.player_bomas (id) on delete cascade,
  item_id    text not null,                       -- e.g. 'shield_thorn_branch'
  quantity   integer not null default 0 check (quantity >= 0),
  updated_at timestamptz not null default now(),
  primary key (boma_id, item_id)
);

alter table public.player_inventory enable row level security;

-- Your satchel is private...
drop policy if exists "Owners read own inventory" on public.player_inventory;
create policy "Owners read own inventory"
  on public.player_inventory for select to authenticated
  using (exists (select 1 from public.player_bomas b
                 where b.id = player_inventory.boma_id and b.user_id = auth.uid()));

-- ...and mutations happen only through consume_shield() below (or the
-- service-role edge function granting items).
drop policy if exists "Owners consume own shields" on public.player_inventory;
create policy "Owners consume own shields"
  on public.player_inventory for update to authenticated
  using (exists (select 1 from public.player_bomas b
                 where b.id = player_inventory.boma_id and b.user_id = auth.uid()))
  with check (exists (select 1 from public.player_bomas b
                 where b.id = player_inventory.boma_id and b.user_id = auth.uid()));

-- ----------------------------------------------------------------------------
-- consume_shield(): spend one 'shield_thorn_branch' to raise immunity 6 hours.
-- ----------------------------------------------------------------------------
create or replace function public.consume_shield()
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  v_boma    public.player_bomas%rowtype;
  v_item    public.player_inventory%rowtype;
  v_left    integer;
begin
  select * into v_boma from public.player_bomas
   where user_id = auth.uid() for update;
  if not found then raise exception 'no boma registered'; end if;

  select * into v_item from public.player_inventory
   where boma_id = v_boma.id and item_id = 'shield_thorn_branch'
   for update;
  if not found or v_item.quantity < 1 then
    raise exception 'no shield tokens in the satchel';
  end if;

  update public.player_inventory
     set quantity = quantity - 1, updated_at = now()
   where boma_id = v_boma.id and item_id = 'shield_thorn_branch';

  -- Extend (never shorten) the existing immunity window by 6 hours.
  update public.player_bomas
     set shield_until = greatest(shield_until, now()) + interval '6 hours',
         updated_at   = now()
   where id = v_boma.id;

  select quantity into v_left from public.player_inventory
   where boma_id = v_boma.id and item_id = 'shield_thorn_branch';
  return v_left;
end $$;

revoke execute on all functions in schema public from anon;
grant  execute on all functions in schema public to authenticated;
