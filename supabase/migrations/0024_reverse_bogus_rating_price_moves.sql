-- Reverses the real price distortion caused by the stale Edge
-- Function's single bad sync burst today (2026-11-13T05:20:29 to
-- 05:24:53 UTC -- confirmed: that window contains EVERY "Rating
-- moved" price_history entry that has ever existed, zero predate it).
-- That one ~5-minute burst (the manual dashboard "Test" tap used to
-- diagnose the cron issue, run before migration 0023's guard existed)
-- gave 1,873 distinct players a bogus, hard-capped +/-15% price move
-- off a fake rating swing -- not evidence, an artifact of the old
-- undeployed formula.
--
-- Scoped ONLY to players who actually have a "Rating moved" entry in
-- their history -- not the whole roster -- so anyone's legitimate
-- buy/sell trade-impact price action (migration 0020) or any other
-- real activity on an untouched player is left completely alone. Uses
-- the same compute_seed_price(rating, age) formula already verified
-- for migration 0019's retroactive reseed, recomputed from each
-- player's CURRENT rating -- curated-protected per migration 0023
-- where that applies, so this correction is itself accurate for the
-- 2,044 curated names. Also resets price_basis_rating to match the
-- current rating for every affected player, closing the gap that
-- would otherwise arm another bogus delta the next time a sync
-- happens to touch them.
--
-- Safe to run more than once: idempotent, logged like any other price
-- move, never silent.

do $$
declare
  rec record;
  new_price numeric;
begin
  for rec in
    select p.id, p.rating, p.age, p.current_price, p.price_basis_rating
    from public.players p
    where p.active = true
      and p.rating is not null
      and exists (
        select 1 from public.price_history ph
        where ph.player_id = p.id and ph.reason ilike 'Rating moved%'
      )
  loop
    new_price := public.compute_seed_price(rec.rating, rec.age);
    if new_price is distinct from rec.current_price then
      perform set_config(
        'scouta.price_change_reason',
        'Corrected: reversed a bogus rating-driven price move from a stale sync pass (migration 0024)',
        true
      );
      update public.players
        set current_price = new_price, price_basis_rating = rec.rating
        where id = rec.id;
    elsif rec.price_basis_rating is distinct from rec.rating then
      update public.players set price_basis_rating = rec.rating where id = rec.id;
    end if;
  end loop;
end $$;
