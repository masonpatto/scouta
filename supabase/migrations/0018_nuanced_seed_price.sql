-- Starting prices were a flat `rating * 2` (migration 0010's seed logic,
-- computed in sync-sportmonks-players/index.ts) -- a 19-year-old on a
-- development curve priced identically to a 32-year-old who's already
-- peaked, as long as their current rating happened to match. That
-- misses the entire "find the gem before anyone else has" premise the
-- app is built around.
--
-- This replaces it with a seed price that rewards youth ONLY when it's
-- paired with a rating that's already good for that age -- age alone no
-- longer inflates every teenager in the database, and quality alone
-- (an older player) earns no bonus, since a veteran's value is already
-- fully reflected in their rating. The two terms multiply rather than
-- add, so:
--   - A young-but-average academy player (the common case: age factor
--     high, quality factor ~0) gets no premium -- being young isn't
--     itself a signal, being young AND good is.
--   - An old-but-great veteran (age factor 0) gets no premium either --
--     already fully priced by rating alone, same as before.
--   - A genuine wonderkid (young AND already performing well above
--     their age cohort) gets the real premium, up to +60% at the
--     extreme (17 years old, rating 90+).
-- Both terms are continuous curves, not cliff-edge age/rating cutoffs,
-- so there's no sudden jump moving from age 23 to 24. The premium is
-- capped (v_max_premium) so no combination can run away unbounded.
--
-- Like the seed price it replaces, this only ever fires once -- the
-- moment a player is first inserted. It never touches current_price for
-- a player who already exists (see upsert_sportmonks_player below,
-- unchanged on that point from migration 0017): an existing holding's
-- price only moves through the rating-delta engine, on real evidence.
--
-- Worked examples (rating * 2 * multiplier):
--   17yo, rating 90 (true wonderkid)   -> 180 * 1.60 = 288 SC
--   17yo, rating 60 (fringe academy)   -> 120 * 1.09 = 130 SC
--   23yo, rating 85 (breaking through) -> 170 * 1.21 = 205 SC
--   32yo, rating 85 (established star) -> 170 * 1.00 = 170 SC
--   32yo, rating 60 (journeyman)       ->  120 * 1.00 = 120 SC

create or replace function public.compute_seed_price(p_rating integer, p_age integer)
returns numeric
language plpgsql
immutable
as $$
declare
  v_age_peak constant numeric := 27;       -- age at/above which no potential premium applies
  v_age_span constant numeric := 10;       -- years over which the age term ramps in (so it maxes out at 17)
  v_quality_floor constant numeric := 55;  -- rating at/below which youth alone still earns nothing
  v_quality_ceiling constant numeric := 90; -- rating at/above which the quality term is fully maxed
  v_max_premium constant numeric := 0.6;   -- the single largest possible bonus: +60%
  v_age_factor numeric;
  v_quality_factor numeric;
  v_multiplier numeric;
begin
  if p_rating is null then
    return 10;
  end if;

  v_age_factor := case
    when p_age is null then 0
    else greatest(0, least(1, (v_age_peak - p_age) / v_age_span))
  end;

  v_quality_factor := greatest(0, least(1, (p_rating - v_quality_floor) / (v_quality_ceiling - v_quality_floor)));

  v_multiplier := 1 + (v_age_factor * v_quality_factor * v_max_premium);

  return greatest(10, round(p_rating * 2 * v_multiplier));
end;
$$;

-- Recreated with the only change being current_price's seed expression
-- (coalesce(p_seed_price, 10) -> compute_seed_price(p_rating, p_age)) --
-- everything else, including the rating-delta price engine on conflict,
-- is identical to migration 0017. p_seed_price is still accepted (kept
-- for signature stability with the currently-deployed Edge Function,
-- which still computes and sends its own flat rating*2 value) but is no
-- longer used -- the real computation now lives here, so it applies to
-- every newly-synced player even without ever redeploying that function.
create or replace function public.upsert_sportmonks_player(
  p_api_player_id integer,
  p_name text,
  p_full_name text,
  p_age integer,
  p_date_of_birth date,
  p_nationality text,
  p_photo_url text,
  p_position text,
  p_club text,
  p_league text,
  p_rating integer,
  p_seed_price numeric
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_basis numeric;
  v_price numeric;
  v_delta numeric;
  v_move_pct numeric;
  v_new_price numeric;
  v_move_pct_per_point constant numeric := 3.0;
  v_hard_cap_pct constant numeric := 15.0;
begin
  select price_basis_rating, current_price into v_basis, v_price
    from public.players where api_player_id = p_api_player_id;

  if v_basis is null then
    v_new_price := null;
  else
    v_delta := p_rating - v_basis;
    if v_delta is not null and v_delta <> 0 then
      v_move_pct := greatest(-v_hard_cap_pct, least(v_hard_cap_pct, v_delta * v_move_pct_per_point));
      v_new_price := greatest(10, round(coalesce(v_price, p_seed_price, 10) * (1 + v_move_pct / 100), 2));
      perform set_config(
        'scouta.price_change_reason',
        format('Rating moved %s%s points (%s -> %s)', case when v_delta > 0 then '+' else '' end, v_delta, v_basis, p_rating),
        true
      );
    end if;
  end if;

  insert into public.players (
    api_player_id, name, full_name, age, date_of_birth, nationality,
    photo_url, position, club, league, rating, current_price,
    price_basis_rating, active, last_synced_at
  )
  values (
    p_api_player_id, p_name, p_full_name, p_age, p_date_of_birth, p_nationality,
    p_photo_url, p_position, p_club, p_league, p_rating,
    public.compute_seed_price(p_rating, p_age), p_rating, true, now()
  )
  on conflict (api_player_id) do update set
    name = excluded.name,
    full_name = excluded.full_name,
    age = excluded.age,
    date_of_birth = excluded.date_of_birth,
    nationality = excluded.nationality,
    photo_url = excluded.photo_url,
    position = excluded.position,
    club = excluded.club,
    league = excluded.league,
    rating = excluded.rating,
    current_price = coalesce(v_new_price, public.players.current_price),
    price_basis_rating = case
      when v_new_price is not null then p_rating
      when v_basis is null then p_rating
      else public.players.price_basis_rating
    end,
    active = true,
    last_synced_at = now();
end;
$$;

revoke all on function public.upsert_sportmonks_player(
  integer, text, text, integer, date, text, text, text, text, text, integer, numeric
) from public, anon, authenticated;

grant execute on function public.upsert_sportmonks_player(
  integer, text, text, integer, date, text, text, text, text, text, integer, numeric
) to service_role;
