-- =====================================================================
-- ULTIMATE SQUAD — Pondération par minutes (4 paliers)
-- =====================================================================
-- Remplace la pondération à 3 statuts par la pondération par MINUTES
-- (règle finale d'Audrey, progression logique) :
--   0-19 min  -> 0 %
--   20-39 min -> 50 %
--   40-59 min -> 75 %
--   60+ min   -> 100 %
--
-- On ajoute une colonne "minutes" à qm_player_scores ; le calcul des
-- points se base désormais sur les minutes. La colonne play_status est
-- conservée (compat) mais n'est plus utilisée pour le calcul.
--
-- À passer après 42_wave3_winter_awards.sql.
-- =====================================================================

-- ---------- 1. Colonne minutes -------------------------------------
alter table qm_player_scores add column if not exists minutes integer;  -- minutes jouées (0-120), NULL = pas saisi

-- ---------- 2. Poids d'un nombre de minutes ------------------------
create or replace function qm_minutes_weight(p_minutes integer)
returns numeric
language sql immutable
as $$
  select case
    when p_minutes is null then 0.0
    when p_minutes < 20 then 0.0
    when p_minutes < 40 then 0.50
    when p_minutes < 60 then 0.75
    else 1.0
  end;
$$;

-- ---------- 3. Recalcul des points d'une équipe (par minutes) ------
create or replace function qm_lineup_points(p_manager uuid, p_matchday_id uuid)
returns numeric
language sql stable security definer set search_path = public
as $$
  with lineup as (
    select unnest(player_ids) as pid
    from qm_lineups
    where manager_id = p_manager and matchday_id = p_matchday_id
  )
  select coalesce(sum(
    coalesce(s.rating, 0) * qm_minutes_weight(s.minutes)
  ), 0)
  from lineup l
  left join qm_player_scores s
    on s.player_id = l.pid and s.matchday_id = p_matchday_id;
$$;

-- ---------- 4. Détail des points (par minutes) ---------------------
create or replace function qm_lineup_breakdown(p_manager uuid, p_matchday_id uuid)
returns table (
  name text, pos qm_player_position, rating numeric,
  minutes integer, weight_pct integer, contribution numeric
)
language sql stable security definer set search_path = public
as $$
  with lineup as (
    select unnest(player_ids) as pid
    from qm_lineups
    where manager_id = p_manager and matchday_id = p_matchday_id
  )
  select
    p.name, p.position as pos,
    s.rating, s.minutes,
    (qm_minutes_weight(s.minutes) * 100)::integer,
    coalesce(s.rating,0) * qm_minutes_weight(s.minutes)
  from lineup l
  join qm_players p on p.id = l.pid
  left join qm_player_scores s on s.player_id = l.pid and s.matchday_id = p_matchday_id
  order by p.position, p.name;
$$;

grant execute on function qm_lineup_breakdown(uuid, uuid) to authenticated;

-- ---------- 5. Mettre à jour la saisie des notes (minutes) ---------
-- Redéfinit qm_scoring_players pour renvoyer les minutes déjà saisies,
-- et qm_admin_set_scores pour enregistrer les minutes.
create or replace function qm_scoring_players(p_matchday_id uuid)
returns table (
  player_id uuid, name text, pos qm_player_position, club text,
  lineups_count integer, rating numeric, minutes integer
)
language sql stable security definer set search_path = public
as $$
  with aligned as (
    select distinct unnest(l.player_ids) as pid
    from qm_lineups l where l.matchday_id = p_matchday_id
  ),
  counts as (
    select x.pid, count(*)::integer as cnt
    from qm_lineups l2
    cross join lateral unnest(l2.player_ids) as x(pid)
    where l2.matchday_id = p_matchday_id
    group by x.pid
  )
  select
    p.id, p.name, p.position as pos, p.club,
    coalesce(c.cnt, 0), s.rating, s.minutes
  from aligned a
  join qm_players p on p.id = a.pid
  left join counts c on c.pid = a.pid
  left join qm_player_scores s on s.player_id = a.pid and s.matchday_id = p_matchday_id
  order by p.position, p.name;
$$;

grant execute on function qm_scoring_players(uuid) to authenticated;
revoke execute on function qm_scoring_players(uuid) from anon;

-- Enregistrement : reçoit rating + minutes. On dérive play_status pour
-- la compat (starter/sub/dnp) à partir des minutes.
create or replace function qm_admin_set_scores(p_matchday_id uuid, p_data jsonb)
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  v_item jsonb;
  v_me uuid;
  v_count integer := 0;
  v_rating numeric;
  v_minutes integer;
  v_status qm_play_status;
begin
  if not qm_is_admin() then raise exception 'Réservé aux administrateurs'; end if;
  if not exists (select 1 from qm_matchdays where id = p_matchday_id) then
    raise exception 'Journée introuvable';
  end if;
  select id into v_me from qm_managers where auth_user_id = auth.uid();

  for v_item in select * from jsonb_array_elements(p_data)
  loop
    v_rating := case when v_item->>'rating' is null or v_item->>'rating'='' then null
                     else (v_item->>'rating')::numeric end;
    v_minutes := case when v_item->>'minutes' is null or v_item->>'minutes'='' then null
                      else (v_item->>'minutes')::integer end;

    if v_rating is not null and (v_rating < 0 or v_rating > 10) then
      raise exception 'Note invalide (%): doit être entre 0 et 10.', v_rating;
    end if;
    if v_minutes is not null and (v_minutes < 0 or v_minutes > 120) then
      raise exception 'Minutes invalides (%): doit être entre 0 et 120.', v_minutes;
    end if;

    -- play_status dérivé (compat) : 60+ titulaire, 1-59 entré, 0/null dnp
    v_status := case
      when v_minutes is null or v_minutes = 0 then 'dnp'
      when v_minutes >= 60 then 'starter'
      else 'sub' end;

    insert into qm_player_scores (player_id, matchday_id, rating, minutes, play_status, scored_by, updated_at)
    values ((v_item->>'player_id')::uuid, p_matchday_id, v_rating, v_minutes, v_status, v_me, now())
    on conflict (player_id, matchday_id)
    do update set rating = excluded.rating, minutes = excluded.minutes,
                  play_status = excluded.play_status, scored_by = excluded.scored_by, updated_at = now();
    v_count := v_count + 1;
  end loop;

  return v_count;
end; $$;

revoke execute on function qm_admin_set_scores(uuid, jsonb) from anon;
