-- =====================================================================
-- COUNTREX ADMIN BACKEND  (run in Supabase > SQL Editor)
-- Safe to run more than once. It only adds things, it never drops tables.
-- BEFORE running: run the "what already exists" query from the chat first.
-- =====================================================================

-- HOW TO READ THIS FILE (plain-English glossary)
--  * "create table if not exists" / "add column if not exists" = only add what is missing; never deletes or overwrites your data.
--  * RLS (row level security) = the database itself decides who may read or change each row. Even if someone copies
--    your site's public key, they can only do what the policies below allow. This is the real protection, not hidden pages.
--  * "security definer" function = runs with the owner's powers, so a normal player can trigger ONE safe action
--    (like "update my last seen") without being given power over the whole table.
--  * pg_cron = the database's built-in alarm clock; it runs a function on a schedule even when nobody is online.
--  * "uuid" = a long random id. "timestamptz" = a date and time with time zone.
--  * Sections: 1 players, 2 settings, 3 admin check, 4 invitations, 5 active/inactive, 6 chats,
--    7 tournaments/events/fixtures, 8 news/messages, 9 security rules, 10 live updates, 11 scheduled jobs, 12 make yourself admin.

-- 0. Extensions (pg_cron must also be switched on in Dashboard > Database > Extensions)
create extension if not exists pgcrypto;
create extension if not exists pg_cron;

-- 1. PLAYERS (profiles) -------------------------------------------------
-- One row per player, linked to their login account (auth.users). 'on delete cascade' = if the account is deleted, this row goes too.
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade
);
-- Extra player info. Each column below is added only if it is missing.
--   username        = public name chosen at signup
--   phone           = number used for the invitation check
--   role            = 'player' or 'admin' (only admins can open the admin panel's data)
--   status          = active / inactive / suspended (inactive is set automatically by the hourly job; suspended is set by you)
--   main_game, doing = what the Players page shows
--   joined_at       = when they joined (the automatic-code rule counts hours from here)
--   last_seen       = last visit (updated by touch_last_seen)
--   invites_granted_at = when their automatic codes were sent; empty = not yet. This is what stops a second batch.
alter table public.profiles
  add column if not exists username text,
  add column if not exists phone text,
  add column if not exists role text not null default 'player' check (role in ('player','admin')),
  add column if not exists status text not null default 'active' check (status in ('active','inactive','suspended')),
  add column if not exists main_game text,
  add column if not exists doing text,
  add column if not exists joined_at timestamptz not null default now(),
  add column if not exists last_seen timestamptz,
  add column if not exists invites_granted_at timestamptz;   -- set once the automatic codes were sent
-- Two players cannot share a username; lower() makes 'Kwame' and 'kwame' count as the same name.
create unique index if not exists profiles_username_key on public.profiles (lower(username));

-- 2. PANEL SETTINGS (one row) -------------------------------------------
-- Panel/rule settings in ONE row. 'check (id = 1)' makes it impossible to create a second row.
create table if not exists public.app_settings (
  id int primary key default 1 check (id = 1),
  auto_invites_on boolean not null default true,
  auto_invite_count int not null default 4,            -- codes per player
  auto_invite_after_hours int not null default 24,     -- time on the site before codes
  auto_invite_days int not null default 14,            -- days until the codes expire
  inactive_after_days int not null default 7           -- no visit for this long = inactive
);
-- Create the single settings row with the default values (do nothing if it already exists).
insert into public.app_settings (id) values (1) on conflict do nothing;

-- 3. ADMIN CHECK --------------------------------------------------------
-- is_admin() = true when the person making the request has role 'admin'. Every admin-only security rule below calls this.
-- 'security definer' lets it read profiles without being blocked by the profiles rules (avoids an endless loop).
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

-- 4. INVITATION CODES ---------------------------------------------------
-- Invitation codes. Columns added next:
--   code      = the text players type, e.g. K7M2-QX9P (unique)
--   note      = your own label, e.g. 'Campus group'
--   phone     = if filled, only this number can use the code; empty = any number can (automatic codes are like this)
--   owner_id  = the player who owns the code (automatic codes); empty = made by you
--   auto      = true when the system created it
--   status    = unused / used / revoked
--   expires_at, used_by, used_at, created_at = expiry and usage history
create table if not exists public.invites (
  id uuid primary key default gen_random_uuid()
);
alter table public.invites
  add column if not exists code text,
  add column if not exists note text,
  add column if not exists phone text,                  -- empty = any phone number can use the code
  add column if not exists owner_id uuid references public.profiles(id) on delete set null,
  add column if not exists auto boolean not null default false,
  add column if not exists status text not null default 'unused' check (status in ('unused','used','revoked')),
  add column if not exists expires_at timestamptz,
  add column if not exists used_by uuid references public.profiles(id) on delete set null,
  add column if not exists used_at timestamptz,
  add column if not exists created_at timestamptz not null default now();
-- No two invitations may have the same code.
create unique index if not exists invites_code_key on public.invites (code);

-- generate_invite_code() = makes one random code like K7M2-QX9P.
--  alphabet has 32 characters (no I, O, 0, 1 so codes are easy to read out loud).
--  gen_random_bytes(8) = 8 secure random bytes; each byte picks one character (% 32 keeps it in range, no bias because 256 divides by 32).
--  A dash is added after the 4th character.
create or replace function public.generate_invite_code() returns text
language plpgsql as $$
declare
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  b bytea := gen_random_bytes(8);
  s text := '';
  i int;
begin
  for i in 0..7 loop
    s := s || substr(alphabet, (get_byte(b, i) % 32) + 1, 1);
    if i = 3 then s := s || '-'; end if;
  end loop;
  return s;
end $$;

-- admin_generate_invites() = what the panel's 'Generate codes' button will call.
--  Refuses anyone who is not an admin. Makes between 1 and 100 codes (least/greatest keep the number in that range)
--  and sets each to expire after p_days days (minimum 1). Returns how many were made.
-- Admin button: make N codes now (qty, note, days until expiry)
create or replace function public.admin_generate_invites(p_qty int, p_note text, p_days int)
returns int language plpgsql security definer set search_path = public as $$
declare i int;
begin
  if not public.is_admin() then raise exception 'admins only'; end if;
  for i in 1..least(greatest(p_qty,1),100) loop
    insert into public.invites (code, note, expires_at)
    values (public.generate_invite_code(), p_note, now() + make_interval(days => greatest(p_days,1)));
  end loop;
  return least(greatest(p_qty,1),100);
end $$;

-- auto_grant_invites() = THE AUTOMATIC RULE, run by the 5-minute job in section 11.
--  1. Read the rule from app_settings (stops at once if you switched it off).
--  2. Find players who have NOT been given codes yet, are not suspended, and joined at least 'auto_invite_after_hours' ago.
--     'for update skip locked' = if two runs overlap, each player is handled by only one of them (no double codes).
--  3. Give each such player 'auto_invite_count' new codes that belong to them and expire after 'auto_invite_days'.
--  4. Stamp the player's invites_granted_at so they can never receive a second batch.
--  Returns how many codes were created.
-- AUTOMATIC RULE: everyone on the site for more than a day gets 4 codes, once.
create or replace function public.auto_grant_invites() returns int
language plpgsql security definer set search_path = public as $$
declare cfg public.app_settings; r record; made int := 0; i int;
begin
  select * into cfg from public.app_settings where id = 1;
  if not cfg.auto_invites_on then return 0; end if;
  for r in
    select id from public.profiles
    where invites_granted_at is null
      and status <> 'suspended'
      and joined_at <= now() - make_interval(hours => cfg.auto_invite_after_hours)
    for update skip locked
  loop
    for i in 1..cfg.auto_invite_count loop
      insert into public.invites (code, note, owner_id, auto, expires_at)
      values (public.generate_invite_code(), 'Automatic reward', r.id, true,
              now() + make_interval(days => cfg.auto_invite_days));
    end loop;
    update public.profiles set invites_granted_at = now() where id = r.id;
    made := made + cfg.auto_invite_count;
  end loop;
  return made;
end $$;

-- 5. ACTIVE / INACTIVE ----------------------------------------------------
-- touch_last_seen() = the site calls this when a signed-in player is on it. Saves 'seen now' and brings an inactive player back to active.
--  A player can only update THEIR OWN row through this (auth.uid() = the logged-in user), nothing else.
create or replace function public.touch_last_seen() returns void
language sql security definer set search_path = public as $$
  update public.profiles
  set last_seen = now(), status = case when status = 'inactive' then 'active' else status end
  where id = auth.uid();
$$;

-- refresh_player_activity() = hourly job. Anyone not seen for 'inactive_after_days' days (or, if never seen, since they joined)
--  becomes inactive; everyone else active. Suspended players are left alone.
create or replace function public.refresh_player_activity() returns void
language sql security definer set search_path = public as $$
  update public.profiles p
  set status = case
    when coalesce(p.last_seen, p.joined_at) < now() - make_interval(days => (select inactive_after_days from public.app_settings where id = 1))
    then 'inactive' else 'active' end
  where p.status <> 'suspended';
$$;

-- 6. CHATS ----------------------------------------------------------------
-- Chat rooms you create. status: open = normal, muted = nobody can post (the rule in section 9 blocks it), flagged = needs your attention.
create table if not exists public.chat_rooms (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  topic text,
  status text not null default 'open' check (status in ('open','muted','flagged')),
  created_at timestamptz not null default now()
);
-- Every chat message: which room, who wrote it, the text (1 to 1000 characters).
create table if not exists public.chat_messages (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.chat_rooms(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  body text not null check (length(body) between 1 and 1000),
  created_at timestamptz not null default now()
);
-- Makes 'latest messages in this room' fast when there are many messages.
create index if not exists chat_messages_room_idx on public.chat_messages (room_id, created_at desc);

-- 7. TOURNAMENTS, EVENTS, FIXTURES ---------------------------------------
-- Tournaments. player_limit = max players; progress = 0 to 100 for the progress bar; join_closes_at = the join countdown deadline;
--  betting = allowed or not; created_by = the player (or admin) who made it.
create table if not exists public.tournaments (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  game text not null,
  player_limit int not null default 16 check (player_limit >= 2),
  progress int not null default 0 check (progress between 0 and 100),
  join_closes_at timestamptz not null,
  rules text,
  betting boolean not null default false,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
-- Who joined which tournament. The pair (tournament, player) is the primary key, so nobody can join twice.
--  The panel counts these rows to show 'joined x / limit'.
create table if not exists public.tournament_players (
  tournament_id uuid references public.tournaments(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (tournament_id, user_id)
);
-- Events with a category, a join limit and a start time (the countdown target). event_attendees below works like tournament_players.
create table if not exists public.events (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  category text,
  join_limit int not null default 50,
  starts_at timestamptz not null,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create table if not exists public.event_attendees (
  event_id uuid references public.events(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete cascade,
  primary key (event_id, user_id)
);
-- Fixtures = a match between two players in a tournament. 'check (player_a <> player_b)' blocks a player facing themselves.
create table if not exists public.fixtures (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  player_a uuid not null references public.profiles(id) on delete cascade,
  player_b uuid not null references public.profiles(id) on delete cascade,
  starts_at timestamptz not null,
  result text,
  check (player_a <> player_b)
);

-- 8. NEWS, ANNOUNCEMENTS, MESSAGES ----------------------------------------
-- News and announcements shown to players.
create table if not exists public.posts (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('News','Announcement')),
  title text not null,
  body text not null,
  created_at timestamptz not null default now()
);
-- Messages you send to players. to_type: all / active / inactive / one. to_user is only used when to_type = 'one'.
create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  to_type text not null check (to_type in ('all','active','inactive','one')),
  to_user uuid references public.profiles(id) on delete cascade,
  subject text not null,
  body text not null,
  created_at timestamptz not null default now()
);

-- 9. SECURITY RULES (RLS) -------------------------------------------------
-- Switch RLS ON for every table. With RLS on and no matching policy, nobody can read or write, so the policies below are what open the doors.
do $$ declare t text; begin
  foreach t in array array['profiles','app_settings','invites','chat_rooms','chat_messages','tournaments',
    'tournament_players','events','event_attendees','fixtures','posts','messages'] loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

-- PROFILES: a player can read only their own row; admins read all. Only admins can change profiles, so a player cannot make themselves admin.
--  (Your signup edge function must create profile rows with the server-side service key, which skips these rules. Not checked yet: I have not seen that function.)
-- players: see only yourself, admins see everyone. Players cannot edit profiles (no way to make themselves admin).
drop policy if exists "profiles read" on public.profiles;
create policy "profiles read" on public.profiles for select using (id = auth.uid() or public.is_admin());
drop policy if exists "profiles admin write" on public.profiles;
create policy "profiles admin write" on public.profiles for all using (public.is_admin()) with check (public.is_admin());

-- SETTINGS: admins only.
drop policy if exists "settings admin" on public.app_settings;
create policy "settings admin" on public.app_settings for all using (public.is_admin()) with check (public.is_admin());

-- INVITES: admins manage everything; a player can only SEE the codes they own. Marking a code used must be done by your signup edge function (service key); I still need to see that function to confirm it does.
-- invites: admins manage all, players can see the codes they own. Signup uses the service role.
drop policy if exists "invites read" on public.invites;
create policy "invites read" on public.invites for select using (public.is_admin() or owner_id = auth.uid());
drop policy if exists "invites admin write" on public.invites;
create policy "invites admin write" on public.invites for all using (public.is_admin()) with check (public.is_admin());

-- CHATS: any signed-in player can read rooms and messages and can post as themselves (user_id must be their own id) in a room that is not muted.
--  Only admins create/edit rooms and delete messages.
-- chats
drop policy if exists "rooms read" on public.chat_rooms;
create policy "rooms read" on public.chat_rooms for select to authenticated using (true);
drop policy if exists "rooms admin write" on public.chat_rooms;
create policy "rooms admin write" on public.chat_rooms for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists "chat read" on public.chat_messages;
create policy "chat read" on public.chat_messages for select to authenticated using (true);
drop policy if exists "chat send" on public.chat_messages;
create policy "chat send" on public.chat_messages for insert to authenticated
  with check (user_id = auth.uid() and exists (select 1 from public.chat_rooms r where r.id = room_id and r.status <> 'muted'));
drop policy if exists "chat admin delete" on public.chat_messages;
create policy "chat admin delete" on public.chat_messages for delete using (public.is_admin());

-- TOURNAMENTS: any signed-in player can read them and create their own (created_by must be themselves); only the creator or an admin can edit/delete.
--  Joining/leaving: a player can only add or remove THEIR OWN entry.
-- tournaments: any player can create one, edit/delete only their own, admins everything
drop policy if exists "tours read" on public.tournaments;
create policy "tours read" on public.tournaments for select to authenticated using (true);
drop policy if exists "tours create" on public.tournaments;
create policy "tours create" on public.tournaments for insert to authenticated with check (created_by = auth.uid() or public.is_admin());
drop policy if exists "tours edit" on public.tournaments;
create policy "tours edit" on public.tournaments for update using (created_by = auth.uid() or public.is_admin());
drop policy if exists "tours delete" on public.tournaments;
create policy "tours delete" on public.tournaments for delete using (created_by = auth.uid() or public.is_admin());

drop policy if exists "tp read" on public.tournament_players;
create policy "tp read" on public.tournament_players for select to authenticated using (true);
drop policy if exists "tp join" on public.tournament_players;
create policy "tp join" on public.tournament_players for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "tp leave" on public.tournament_players;
create policy "tp leave" on public.tournament_players for delete using (user_id = auth.uid() or public.is_admin());

-- EVENTS, FIXTURES, POSTS: signed-in players read; only admins write.
--  This loop just writes the same two rules for each of the three tables.
-- events, fixtures, posts: everyone reads, admins write
do $$ declare t text; begin
  foreach t in array array['events','fixtures','posts'] loop
    execute format('drop policy if exists "%1$s read" on public.%1$I', t);
    execute format('create policy "%1$s read" on public.%1$I for select to authenticated using (true)', t);
    execute format('drop policy if exists "%1$s admin write" on public.%1$I', t);
    execute format('create policy "%1$s admin write" on public.%1$I for all using (public.is_admin()) with check (public.is_admin())', t);
  end loop;
end $$;

-- EVENT ATTENDEES: players join/leave events themselves (own row only); everyone signed in can read; admins can remove anyone.
drop policy if exists "ea read" on public.event_attendees;
create policy "ea read" on public.event_attendees for select to authenticated using (true);
drop policy if exists "ea join" on public.event_attendees;
create policy "ea join" on public.event_attendees for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "ea leave" on public.event_attendees;
create policy "ea leave" on public.event_attendees for delete using (user_id = auth.uid() or public.is_admin());

-- MESSAGES: admins send. A player reads only messages meant for them: sent to all, sent to them personally,
--  or sent to 'active'/'inactive' players when their own status matches.
-- messages: admins write; each player reads only what was sent to them
drop policy if exists "messages admin write" on public.messages;
create policy "messages admin write" on public.messages for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists "messages read mine" on public.messages;
create policy "messages read mine" on public.messages for select to authenticated using (
  to_type = 'all'
  or (to_type = 'one' and to_user = auth.uid())
  or (to_type in ('active','inactive') and exists (select 1 from public.profiles p where p.id = auth.uid() and p.status = messages.to_type))
);

-- FUNCTION PERMISSIONS: the two scheduled functions are locked so nobody can call them from the site; only the database scheduler runs them.
--  admin_generate_invites can be called by signed-in users but it refuses non-admins inside. touch_last_seen is open to signed-in players.
-- Only signed-in users may call these helpers; the rest are for the scheduler / admins
revoke all on function public.auto_grant_invites() from public, anon, authenticated;
revoke all on function public.refresh_player_activity() from public, anon, authenticated;
revoke all on function public.admin_generate_invites(int, text, int) from public, anon;
grant execute on function public.admin_generate_invites(int, text, int) to authenticated;
grant execute on function public.touch_last_seen() to authenticated;

-- (Section 10) 'supabase_realtime' is Supabase's live-update feed. Adding a table lets the admin panel hear about new/changed rows instantly
--  instead of refreshing. The 'exception' part ignores tables that were already added, so re-running is safe.
-- 10. LIVE UPDATES (the admin panel listens to these tables) ----------------
do $$ declare t text; begin
  foreach t in array array['profiles','invites','chat_rooms','chat_messages','tournaments','tournament_players',
    'events','fixtures','posts','messages'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;

-- 11. AUTOMATIC JOBS ---------------------------------------------------------
-- cron expressions read: minute hour day month weekday.
--  '*/5 * * * *' = every 5 minutes -> sends the automatic invitation codes. '0 * * * *' = at minute 0 of every hour -> refreshes active/inactive.
--  Using the same job name again replaces the old job, so re-running does not create duplicates.
select cron.schedule('auto-invites', '*/5 * * * *', $$select public.auto_grant_invites()$$);
select cron.schedule('refresh-activity', '0 * * * *', $$select public.refresh_player_activity()$$);

-- (Section 12) Your account is created through the normal signup first; this line then upgrades it. Keep it commented until you have signed up.
-- 12. MAKE YOURSELF ADMIN (run AFTER you have signed up on the site) ---------
-- Replace YOUR_USERNAME, remove the two dashes at the start, then run only this line:
-- update public.profiles set role = 'admin' where lower(username) = lower('YOUR_USERNAME');
