-- Scout Journal: proper multi-entry investment theses per player
-- (title, freeform body, conviction, price expectation), replacing
-- the single holdings.thesis text field with a real chronological
-- history a user can revisit and edit entry by entry.
--
-- holdings.thesis is left in place untouched (nothing reads or writes
-- it client-side anymore after this ships, but dropping a column on a
-- live table is a one-way door with no upside here) and any existing
-- thesis text is copied forward as that holding's first journal entry,
-- so nobody's existing notes are lost in the move.
--
-- Safe to run against the live project: CREATE TABLE IF NOT EXISTS,
-- policies are dropped/recreated by name, and the thesis backfill only
-- inserts where a journal entry for that user+player doesn't already
-- exist -- re-running this file is harmless.

create table if not exists public.journal_entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  player_id uuid not null references public.players(id) on delete cascade,
  title text,
  body text not null default '',
  conviction text check (conviction in ('low', 'medium', 'high')),
  price_expectation numeric,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now()
);

create index if not exists journal_entries_user_updated_idx
  on public.journal_entries (user_id, updated_at desc);

create index if not exists journal_entries_user_player_idx
  on public.journal_entries (user_id, player_id, created_at desc);

alter table public.journal_entries enable row level security;

-- Freeform scouting notes carry no economic value (unlike holdings/
-- profiles cash_sc), so plain owner-scoped policies are enough -- no
-- lockdown trigger needed here.
drop policy if exists "Users can view their own journal entries" on public.journal_entries;
create policy "Users can view their own journal entries"
  on public.journal_entries for select
  using (auth.uid() = user_id);

drop policy if exists "Users can create their own journal entries" on public.journal_entries;
create policy "Users can create their own journal entries"
  on public.journal_entries for insert
  with check (auth.uid() = user_id);

drop policy if exists "Users can update their own journal entries" on public.journal_entries;
create policy "Users can update their own journal entries"
  on public.journal_entries for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists "Users can delete their own journal entries" on public.journal_entries;
create policy "Users can delete their own journal entries"
  on public.journal_entries for delete
  using (auth.uid() = user_id);

create or replace function public.touch_journal_entry_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists set_journal_entries_updated_at on public.journal_entries;
create trigger set_journal_entries_updated_at
  before update on public.journal_entries
  for each row execute function public.touch_journal_entry_updated_at();

-- One-time backfill: carry forward any existing holdings.thesis text
-- as that holding's first journal entry.
insert into public.journal_entries (user_id, player_id, title, body, created_at, updated_at)
select h.user_id, h.player_id, 'Initial thesis', h.thesis,
       coalesce(h.updated_at, now()), coalesce(h.updated_at, now())
from public.holdings h
where h.thesis is not null
  and length(trim(h.thesis)) > 0
  and not exists (
    select 1 from public.journal_entries je
    where je.user_id = h.user_id and je.player_id = h.player_id
  );
