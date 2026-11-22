-- Run once in the Supabase SQL editor to turn on per-game rankings on the leaderboard page.
alter table public.profiles add column if not exists points_codm integer not null default 0;
alter table public.profiles add column if not exists points_eafc integer not null default 0;
alter table public.profiles add column if not exists points_efootball integer not null default 0;
create index if not exists profiles_points_codm_idx on public.profiles (points_codm desc);
create index if not exists profiles_points_eafc_idx on public.profiles (points_eafc desc);
create index if not exists profiles_points_efootball_idx on public.profiles (points_efootball desc);
-- give points (you, as admin; players cannot edit these):
-- update public.profiles set points_codm = points_codm + 100, points = points + 100 where username = 'SomeName';
