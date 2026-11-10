-- The player roster just grew from ~650 (Premier League only) to ~3,000
-- (every player across the 5 Sportmonks-subscribed leagues). The app's
-- fetchPlayers() called price_change_pct() once per player via
-- Promise.all -- fine at ~650 concurrent requests, a real scalability
-- problem at ~3,000. This adds a set-based bulk equivalent so the app
-- can fetch every player's 24h change in one round trip instead of
-- thousands.

create or replace function public.price_change_pct_bulk(p_hours integer)
returns table (player_id uuid, pct numeric)
language sql
stable
as $$
  select
    p.id as player_id,
    case
      when earliest.price is null or earliest.price = 0 then null
      else round(((p.current_price - earliest.price) / earliest.price) * 100, 2)
    end as pct
  from public.players p
  left join lateral (
    select price from public.price_history
    where player_id = p.id
      and recorded_at <= now() - (p_hours || ' hours')::interval
    order by recorded_at desc
    limit 1
  ) as earliest on true
  where p.active = true;
$$;
