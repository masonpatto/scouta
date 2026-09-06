-- Add a human-readable reason to every price change, so "why did this
-- price move" is always answerable from price_history alone (not just
-- the numeric delta). The market-engine Edge Function sets
-- scouta.price_change_reason (a transaction-local setting, same pattern
-- as scouta.trusted_holdings_update / scouta.trusted_profile_update)
-- immediately before updating players.current_price; log_price_change
-- picks it up and clears it after use so it never leaks into an
-- unrelated later update in the same session.

alter table public.price_history add column if not exists reason text;

create or replace function public.log_price_change()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  if new.current_price is distinct from old.current_price then
    insert into public.price_history (player_id, price, recorded_at, reason)
    values (new.id, new.current_price, now(), current_setting('scouta.price_change_reason', true));
    perform set_config('scouta.price_change_reason', null, true);
  end if;
  return new;
end;
$function$;
