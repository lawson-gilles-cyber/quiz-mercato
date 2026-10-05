-- =====================================================================
-- QUIZ MERCATO — Système de points (performances réelles)
-- =====================================================================
-- Un manager gagne des points quand SES joueurs performent en vrai.
-- Barème d'Audrey, appliqué selon le poste. Saisie manuelle par l'admin,
-- uniquement pour les joueurs détenus (charge proportionnelle au jeu réel).
--
-- Flux :
--   1. L'admin saisit les perfs d'un joueur pour une journée (qm_match_performances)
--   2. Un trigger calcule les points selon le barème (qm_perf_points)
--   3. Les points sont attribués au manager propriétaire (season_points)
-- =====================================================================

-- ---------- Table des performances par joueur et par journée ---------
create table if not exists qm_match_performances (
  id            uuid primary key default gen_random_uuid(),
  player_id     uuid not null references qm_players(id) on delete cascade,
  matchday      integer not null,              -- numéro de journée (1, 2, 3…)
  minutes       integer not null default 0,    -- minutes jouées
  goals         integer not null default 0,
  assists       integer not null default 0,
  clean_sheet   boolean not null default false,-- pertinent DEF/GK
  penalty_saved integer not null default 0,    -- GK
  yellow_cards  integer not null default 0,
  red_card      boolean not null default false,
  own_goals     integer not null default 0,
  penalty_missed integer not null default 0,
  motm          boolean not null default false,-- homme du match
  team_result   text not null default 'none',  -- 'win' / 'draw' / 'loss' / 'none'
  points        integer not null default 0,    -- calculé par le trigger
  owner_at_time uuid references qm_managers(id),-- manager propriétaire au moment de la saisie
  created_at    timestamptz not null default now(),
  unique (player_id, matchday)                 -- une perf par joueur et par journée
);

create index if not exists idx_qm_perf_player   on qm_match_performances(player_id);
create index if not exists idx_qm_perf_matchday on qm_match_performances(matchday);
create index if not exists idx_qm_perf_owner    on qm_match_performances(owner_at_time);

-- ---------- Barème d'Audrey : calcul des points d'une performance ----
-- Selon le poste du joueur. Retourne le total de points de la perf.
create or replace function qm_perf_points(p_perf qm_match_performances)
returns integer
language plpgsql
immutable
as $$
declare
  v_pos   qm_player_position;
  v_pts   integer := 0;
begin
  select position into v_pos from qm_players where id = p_perf.player_id;

  -- ----- Buts (valeur selon le poste : plus un but est rare au poste, plus il rapporte) -----
  v_pts := v_pts + case v_pos
    when 'FWD' then p_perf.goals * 8
    when 'MID' then p_perf.goals * 10
    when 'DEF' then p_perf.goals * 12
    when 'GK'  then p_perf.goals * 20
  end;

  -- ----- Passes décisives -----
  v_pts := v_pts + case v_pos
    when 'FWD' then p_perf.assists * 5
    when 'MID' then p_perf.assists * 6
    when 'DEF' then p_perf.assists * 6
    when 'GK'  then p_perf.assists * 8
  end;

  -- ----- Clean sheet (défenseurs et gardiens, min 60 min) -----
  if p_perf.clean_sheet and p_perf.minutes >= 60 then
    v_pts := v_pts + case v_pos
      when 'DEF' then 5
      when 'GK'  then 6
      else 0
    end;
  end if;

  -- ----- Arrêts de penalty (gardiens) -----
  v_pts := v_pts + p_perf.penalty_saved * 8;

  -- ----- Homme du match -----
  if p_perf.motm then v_pts := v_pts + 3; end if;

  -- ----- Malus -----
  v_pts := v_pts - p_perf.yellow_cards * 2;
  if p_perf.red_card then v_pts := v_pts - 5; end if;
  v_pts := v_pts - p_perf.own_goals * 4;
  v_pts := v_pts - p_perf.penalty_missed * 4;

  -- ----- Bonus d'équipe (min 60 min jouées) -----
  if p_perf.minutes >= 60 then
    v_pts := v_pts + case p_perf.team_result
      when 'win'  then 2
      when 'draw' then 1
      else 0
    end;
  end if;

  return v_pts;
end;
$$;

-- ---------- Trigger : calcule points + attribue au propriétaire ------
-- À chaque insertion/mise à jour d'une perf :
--   * recalcule les points selon le barème
--   * enregistre le propriétaire actuel du joueur
--   * ajuste season_points du manager (delta si mise à jour)
create or replace function qm_perf_apply()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner   uuid;
  v_newpts  integer;
  v_oldpts  integer := 0;
begin
  -- Propriétaire actuel du joueur
  select owner_id into v_owner from qm_players where id = new.player_id;
  new.owner_at_time := v_owner;

  -- Points selon le barème
  new.points := qm_perf_points(new);
  v_newpts := new.points;

  -- Si mise à jour, on retire d'abord les anciens points du même manager
  if (TG_OP = 'UPDATE') then
    v_oldpts := coalesce(old.points, 0);
    if old.owner_at_time is not null then
      update qm_managers set season_points = season_points - v_oldpts
        where id = old.owner_at_time;
    end if;
  end if;

  -- Attribue les nouveaux points au propriétaire actuel
  if v_owner is not null then
    update qm_managers set season_points = season_points + v_newpts
      where id = v_owner;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_qm_perf_apply on qm_match_performances;
create trigger trg_qm_perf_apply
  before insert or update on qm_match_performances
  for each row execute function qm_perf_apply();

-- ---------- RLS : lecture publique, écriture via RPC admin -----------
alter table qm_match_performances enable row level security;
create policy "qm read performances" on qm_match_performances for select using (true);

-- ---------- RPC admin : saisir une performance ----------------------
create or replace function qm_admin_record_performance(
  p_player_id uuid, p_matchday integer, p_minutes integer,
  p_goals integer, p_assists integer, p_clean_sheet boolean,
  p_penalty_saved integer, p_yellow integer, p_red boolean,
  p_own_goals integer, p_penalty_missed integer, p_motm boolean,
  p_team_result text
)
returns qm_match_performances
language plpgsql
security definer
set search_path = public
as $$
declare v_perf qm_match_performances;
begin
  if not qm_is_admin() then
    raise exception 'Réservé aux administrateurs';
  end if;
  -- Upsert : si la perf existe déjà pour ce joueur/journée, on la met à jour
  insert into qm_match_performances (
    player_id, matchday, minutes, goals, assists, clean_sheet,
    penalty_saved, yellow_cards, red_card, own_goals, penalty_missed,
    motm, team_result
  ) values (
    p_player_id, p_matchday, p_minutes, p_goals, p_assists, p_clean_sheet,
    p_penalty_saved, p_yellow, p_red, p_own_goals, p_penalty_missed,
    p_motm, p_team_result
  )
  on conflict (player_id, matchday) do update set
    minutes = excluded.minutes, goals = excluded.goals, assists = excluded.assists,
    clean_sheet = excluded.clean_sheet, penalty_saved = excluded.penalty_saved,
    yellow_cards = excluded.yellow_cards, red_card = excluded.red_card,
    own_goals = excluded.own_goals, penalty_missed = excluded.penalty_missed,
    motm = excluded.motm, team_result = excluded.team_result
  returning * into v_perf;
  return v_perf;
end;
$$;

-- ---------- Liste des joueurs détenus (pour la saisie ciblée) -------
-- L'admin ne saisit que pour les joueurs réellement possédés.
create or replace function qm_owned_players()
returns table (id uuid, name text, pos qm_player_position, club text, owner text)
language sql
security definer
set search_path = public
as $$
  select p.id, p.name, p.position, p.club, m.display_name
  from qm_players p
  join qm_managers m on m.id = p.owner_id
  where p.owner_id is not null
  order by m.display_name, p.position;
$$;
