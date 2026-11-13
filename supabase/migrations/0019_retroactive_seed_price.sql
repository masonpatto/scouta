-- Migration 0018's nuanced seed price (age + quality-for-age, instead
-- of a flat rating*2) only applied to brand-new players going forward
-- -- upsert_sportmonks_player deliberately never touches current_price
-- for a player who already exists, so trading on a price never changes
-- silently underneath someone's holding. That's the right default, but
-- it also means every player already in the table was still priced on
-- the old flat formula.
--
-- This is the one-time, explicit opposite of that default: re-seed
-- EVERY existing active player onto the new curve right now, as a
-- deliberate, logged repricing rather than a silent one. Every player
-- whose price actually changes gets a real price_history row explaining
-- why (same "never move a price silently" rule as everywhere else),
-- which is why this loops one player at a time instead of a single bulk
-- UPDATE -- log_price_change's trigger clears the reason it just used
-- immediately after each row, specifically so a stale reason can never
-- leak onto an unrelated later change (see migration 0002); a single
-- bulk statement touching thousands of rows in one go would only have
-- gotten that reason attached to the first row and logged NULL for
-- every row after it.
--
-- Heads up: this changes the market value of every holding in every
-- account that holds a repriced player -- not from any trade, but from
-- this formula correction. Safe to run more than once: for any player
-- whose current_price already matches what the formula gives their
-- rating/age, there's nothing to update and nothing gets logged.

do $$
declare
  rec record;
  new_price numeric;
begin
  for rec in
    select id, rating, age, current_price
    from public.players
    where active = true and rating is not null
  loop
    new_price := public.compute_seed_price(rec.rating, rec.age);
    if new_price is distinct from rec.current_price then
      perform set_config(
        'scouta.price_change_reason',
        'Re-seeded onto the nuanced wonderkid pricing curve (migration 0019)',
        true
      );
      update public.players set current_price = new_price where id = rec.id;
    end if;
  end loop;
end $$;
