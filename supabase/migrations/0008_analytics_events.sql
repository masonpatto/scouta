-- Basic analytics: a flat event log, no third-party SDK/account needed.
-- Deliberately minimal (name + freeform jsonb props) rather than a
-- fixed schema per event type, since the event set will evolve.
-- Write-only from the client (insert your own events); reading is done
-- directly via SQL as the project owner, not exposed to the app.

create table if not exists public.analytics_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete set null,
  event text not null,
  props jsonb not null default '{}'::jsonb,
  created_at timestamp with time zone not null default now()
);

create index if not exists analytics_events_event_created_idx
  on public.analytics_events (event, created_at desc);

alter table public.analytics_events enable row level security;

drop policy if exists "Users can log their own events" on public.analytics_events;
create policy "Users can log their own events"
  on public.analytics_events for insert
  with check (auth.uid() = user_id);
