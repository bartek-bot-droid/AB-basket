-- Princeton Offense Trener: baza wyników graczy (Supabase / Postgres).
-- Uruchom raz: Supabase -> SQL Editor -> New query -> wklej całość -> Run.
--
-- Przeglądarka nie ma dostępu do tabeli players. Czyta tylko widok leaderboard
-- (bez PIN-ów i tokenów), a zapisuje wyłącznie przez funkcje poniżej, które
-- pilnują limitów punktów.

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.players (
  id           uuid primary key default gen_random_uuid(),
  nick         text not null,
  pin_hash     text not null,
  token        uuid not null default gen_random_uuid(),
  best         jsonb not null default '{}'::jsonb,   -- najlepszy wynik w każdej sytuacji
  stars        jsonb not null default '{}'::jsonb,   -- najlepsze gwiazdki w każdej sytuacji
  trig         int not null default 0,               -- rekord w triggerach
  total        int not null default 0,               -- suma best + trig
  games        int not null default 0,
  watched      int not null default 0,
  answers      int not null default 0,
  correct      int not null default 0,
  play_ms      bigint not null default 0,
  days         date[] not null default '{}',
  failed       int not null default 0,
  locked_until timestamptz,
  created_at   timestamptz not null default now(),
  last_at      timestamptz
);
create unique index if not exists players_nick_key on public.players (lower(nick));
create unique index if not exists players_token_key on public.players (token);

alter table public.players enable row level security;
revoke all on table public.players from anon, authenticated;

-- Ranking widoczny dla wszystkich. Widok działa z prawami właściciela,
-- więc omija RLS, ale pokazuje tylko bezpieczne kolumny.
create or replace view public.leaderboard as
  select p.id, p.nick, p.total, p.games, p.watched, p.answers, p.correct, p.play_ms,
         cardinality(p.days) as days_count,
         (select coalesce(sum(value::int), 0) from jsonb_each_text(p.stars)) as stars_sum,
         p.last_at
  from public.players p;
grant select on public.leaderboard to anon, authenticated;

create or replace function public.player_json(r public.players)
returns jsonb language sql stable set search_path = public as $$
  select jsonb_build_object(
    'id', r.id, 'nick', r.nick, 'total', r.total, 'games', r.games, 'watched', r.watched,
    'answers', r.answers, 'correct', r.correct, 'play_ms', r.play_ms,
    'days_count', cardinality(r.days),
    'stars_sum', (select coalesce(sum(value::int), 0) from jsonb_each_text(r.stars)),
    'best', r.best, 'stars', r.stars, 'trig', r.trig)
$$;
revoke execute on function public.player_json(public.players) from public, anon, authenticated;

-- Nowe konto: ksywka 2-24 znaki, PIN dokładnie 4 cyfry.
create or replace function public.register_player(p_nick text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_nick text := btrim(coalesce(p_nick, ''));
  r public.players;
begin
  if char_length(v_nick) < 2 or char_length(v_nick) > 24 then
    return jsonb_build_object('error', 'NICK_LEN');
  end if;
  if coalesce(p_pin, '') !~ '^[0-9]{4}$' then
    return jsonb_build_object('error', 'PIN_FORMAT');
  end if;
  if exists (select 1 from public.players p where lower(p.nick) = lower(v_nick)) then
    return jsonb_build_object('error', 'NICK_TAKEN');
  end if;
  insert into public.players (nick, pin_hash)
    values (v_nick, extensions.crypt(p_pin, extensions.gen_salt('bf')))
    returning * into r;
  return public.player_json(r) || jsonb_build_object('token', r.token);
exception when unique_violation then
  return jsonb_build_object('error', 'NICK_TAKEN');
end $$;

-- Logowanie. Po 8 złych PIN-ach konto blokuje się na 15 minut.
create or replace function public.login_player(p_nick text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r public.players;
begin
  select * into r from public.players p
    where lower(p.nick) = lower(btrim(coalesce(p_nick, '')))
    for update;
  if not found then
    return jsonb_build_object('error', 'BAD_LOGIN');
  end if;
  if r.locked_until is not null and r.locked_until > now() then
    return jsonb_build_object('error', 'LOCKED');
  end if;
  if r.pin_hash <> extensions.crypt(coalesce(p_pin, ''), r.pin_hash) then
    update public.players
      set failed = case when r.failed + 1 >= 8 then 0 else r.failed + 1 end,
          locked_until = case when r.failed + 1 >= 8 then now() + interval '15 minutes' else null end
      where id = r.id;
    return jsonb_build_object('error', 'BAD_LOGIN');
  end if;
  update public.players set failed = 0, locked_until = null where id = r.id;
  return public.player_json(r) || jsonb_build_object('token', r.token);
end $$;

create or replace function public.get_me(p_token uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r public.players;
begin
  select * into r from public.players where token = p_token;
  if not found then
    return jsonb_build_object('error', 'BAD_TOKEN');
  end if;
  return public.player_json(r);
end $$;

-- Jedna rozegrana gra. Limity tną wpisy, których nie da się zdobyć w grze.
create or replace function public.record_play(p_token uuid, p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_drills constant text[] := array[
    'ustawienie', 'lp-wejscie', 'lp-backdoor', 'lp-pop', 'lp-backcut', 'lp-dho',
    'pt-start', 'pt-away-a', 'pt-away-b', 'pt-over-a', 'pt-over-b',
    'ch-start', 'ch-flare-pop', 'ch-flare-kryty', 'ch-curl'];
  v_drill   text   := p ->> 'drill';
  v_score   int    := least(greatest(coalesce((p ->> 'score')::numeric, 0), 0), 1500)::int;
  v_stars   int    := least(greatest(coalesce((p ->> 'stars')::numeric, 0), 0), 3)::int;
  v_trig    int    := least(greatest(coalesce((p ->> 'trig')::numeric, 0), 0), 1600)::int;
  v_game    int    := least(greatest(coalesce((p ->> 'game')::numeric, 0), 0), 1)::int;
  v_watched int    := least(greatest(coalesce((p ->> 'watched')::numeric, 0), 0), 1)::int;
  v_answers int    := least(greatest(coalesce((p ->> 'answers')::numeric, 0), 0), 30)::int;
  v_correct int    := least(greatest(coalesce((p ->> 'correct')::numeric, 0), 0), v_answers)::int;
  v_ms      bigint := least(greatest(coalesce((p ->> 'ms')::numeric, 0), 0), 2700000)::bigint;
  r public.players;
begin
  select * into r from public.players where token = p_token for update;
  if not found then
    return jsonb_build_object('error', 'BAD_TOKEN');
  end if;
  if v_drill = any(v_drills) then
    r.best  := jsonb_set(r.best,  array[v_drill], to_jsonb(greatest(coalesce((r.best  ->> v_drill)::int, 0), v_score)));
    r.stars := jsonb_set(r.stars, array[v_drill], to_jsonb(greatest(coalesce((r.stars ->> v_drill)::int, 0), v_stars)));
  end if;
  r.trig  := greatest(r.trig, v_trig);
  r.total := r.trig + (select coalesce(sum(value::int), 0) from jsonb_each_text(r.best));
  update public.players set
      best = r.best, stars = r.stars, trig = r.trig, total = r.total,
      games = games + v_game, watched = watched + v_watched,
      answers = answers + v_answers, correct = correct + v_correct,
      play_ms = play_ms + v_ms,
      days = case when current_date = any(days) then days else days || current_date end,
      last_at = now()
    where id = r.id
    returning * into r;
  return public.player_json(r);
end $$;

grant execute on function public.register_player(text, text) to anon, authenticated;
grant execute on function public.login_player(text, text)    to anon, authenticated;
grant execute on function public.get_me(uuid)                 to anon, authenticated;
grant execute on function public.record_play(uuid, jsonb)     to anon, authenticated;

notify pgrst, 'reload schema';
