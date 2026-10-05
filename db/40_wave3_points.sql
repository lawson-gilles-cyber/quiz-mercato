-- =====================================================================
-- ULTIMATE SQUAD — Vague 3, Étape 4 : CLÔTURE & POINTS
-- =====================================================================
-- La clôture d'une journée calcule, pour chaque équipe :
--   points = somme des notes de ses 11 titulaires, pondérées par statut
--            (titulaire 100 %, entré en jeu 50 %, pas joué 0 %).
-- Puis met à jour le classement (season_points = somme des journées).
--
-- Les notes sont décimales (Sofascore, ex 7.85) ; les points de journée
-- sont stockés en numeric. Le classement season_points (integer) est
-- recalculé comme l'arrondi de la somme des points de journée.
--
-- À passer après 39_wave3_scoring.sql.
-- =====================================================================

-- ---------- 1. Poids d'un statut de jeu ----------------------------
create or replace function qm_play_weight(p_status qm_play_status)
returns numeric
language sql immutable
as $$
  select case p_status
    when 'starter' then 1.0
    when 'sub'     then 0.5
    when 'dnp'     then 0.0
    else 0.0 end;
$$;

-- ---------- 2. Calcul des points d'une équipe pour une journée -----
-- Somme, sur les 11 alignés, de (note * poids du statut).
-- Un joueur sans note saisie compte 0. Renvoie le total (numeric).
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
    coalesce(s.rating, 0) * qm_play_weight(coalesce(s.play_status,'dnp'))
  ), 0)
  from lineup l
  left join qm_player_scores s
    on s.player_id = l.pid and s.matchday_id = p_matchday_id;
$$;

-- ---------- 3. Clôture d'une journée (admin) -----------------------
-- Calcule et enregistre les points de chaque équipe ayant une compo,
-- passe la journée en 'closed', puis recalcule le classement.
create or replace function qm_admin_close_matchday(p_matchday_id uuid)
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  v_md qm_matchdays;
  r record;
  v_pts numeric;
  v_count integer := 0;
begin
  if not qm_is_admin() then raise exception 'Réservé aux administrateurs'; end if;
  select * into v_md from qm_matchdays where id = p_matchday_id;
  if not found then raise exception 'Journée introuvable'; end if;
  if v_md.status = 'closed' then raise exception 'Cette journée est déjà clôturée'; end if;

  -- Pour chaque équipe ayant aligné une compo cette journée
  for r in select manager_id from qm_lineups where matchday_id = p_matchday_id
  loop
    v_pts := qm_lineup_points(r.manager_id, p_matchday_id);
    insert into qm_matchday_points (manager_id, matchday_id, points)
    values (r.manager_id, p_matchday_id, v_pts)
    on conflict (manager_id, matchday_id)
    do update set points = excluded.points, created_at = now();
    v_count := v_count + 1;
  end loop;

  update qm_matchdays set status = 'closed' where id = p_matchday_id;

  -- Recalcule le classement global
  perform qm_recompute_standings();

  return v_count;
end; $$;

revoke execute on function qm_admin_close_matchday(uuid) from anon;

-- ---------- 4. Recalcul du classement ------------------------------
-- season_points = points de performance (somme des journées)
--               + points issus des conversions budget->points (vague 1).
-- La conversion (qm_convert_budget_to_points) trace chaque opération
-- dans qm_bonuses (type 'convert', amount = budget dépensé). On en
-- redérive les points au taux courant. Recalcul complet => idempotent.
--
-- IMPORTANT : pour éviter tout double comptage, la fonction de
-- conversion NE DOIT PLUS incrémenter season_points directement ;
-- elle appelle qm_recompute_standings à la place (voir section 4b).
create or replace function qm_recompute_standings()
returns void
language plpgsql security definer set search_path = public
as $$
declare v_rate bigint;
begin
  select budget_to_points_rate into v_rate from qm_season_state where id = 1;
  if v_rate is null or v_rate < 1 then v_rate := 10000000; end if;

  update qm_managers m set season_points =
    coalesce((select round(sum(points))::integer from qm_matchday_points where manager_id = m.id), 0)
    + coalesce((select sum(floor(amount / v_rate))::integer from qm_bonuses
                where manager_id = m.id and bonus_type = 'convert'), 0);
end; $$;

-- ---------- 4b. La conversion ne double plus les points ------------
-- On redéfinit qm_convert_budget_to_points pour qu'elle NE fasse PLUS
-- season_points = season_points + v_points, mais qu'elle recalcule via
-- qm_recompute_standings (source unique de vérité).
create or replace function qm_convert_budget_to_points(p_amount bigint)
returns qm_managers
language plpgsql security definer set search_path = public
as $$
declare
  v_manager qm_managers;
  v_rate bigint;
  v_cap bigint;
  v_points integer;
  v_spend bigint;
begin
  select * into v_manager from qm_managers where auth_user_id = auth.uid() for update;
  if not found then raise exception 'Vous ne participez pas à cette saison'; end if;
  if p_amount <= 0 then raise exception 'Montant invalide'; end if;
  if p_amount > (v_manager.budget - v_manager.budget_locked) then
    raise exception 'Montant supérieur à ton budget disponible (hors enchères en cours).';
  end if;

  select budget_to_points_rate, coalesce(convert_cap, 200000000)
    into v_rate, v_cap from qm_season_state where id = 1;

  if coalesce(v_manager.converted_total,0) + p_amount > v_cap then
    raise exception 'Plafond de conversion atteint : maximum % M€ convertibles au total (déjà converti : % M€).',
      (v_cap/1000000), (coalesce(v_manager.converted_total,0)/1000000);
  end if;

  v_points := floor(p_amount / v_rate)::integer;
  if v_points < 1 then
    raise exception 'Il faut au moins % € pour convertir 1 point.', v_rate;
  end if;
  v_spend := v_points::bigint * v_rate;

  -- On débite le budget et on trace, mais on NE touche PAS season_points ici
  update qm_managers
    set budget = budget - v_spend,
        converted_total = coalesce(converted_total,0) + v_spend
    where id = v_manager.id returning * into v_manager;

  insert into qm_bonuses (manager_id, bonus_type, amount, detail)
  values (v_manager.id, 'convert', v_spend,
          'Conversion budget -> ' || v_points || ' point(s) de classement');

  -- Source unique de vérité : recalcul complet
  perform qm_recompute_standings();

  -- Renvoie le manager à jour (avec ses nouveaux points)
  select * into v_manager from qm_managers where id = v_manager.id;
  return v_manager;
end; $$;

revoke execute on function qm_convert_budget_to_points(bigint) from anon;

-- ---------- 5. Détail des points d'une équipe (lecture) ------------
-- Pour afficher à un manager le détail de sa journée : chaque titulaire,
-- sa note, son statut, sa contribution.
create or replace function qm_lineup_breakdown(p_manager uuid, p_matchday_id uuid)
returns table (
  name text, pos qm_player_position, rating numeric,
  play_status qm_play_status, contribution numeric
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
    s.rating, coalesce(s.play_status,'dnp'),
    coalesce(s.rating,0) * qm_play_weight(coalesce(s.play_status,'dnp'))
  from lineup l
  join qm_players p on p.id = l.pid
  left join qm_player_scores s on s.player_id = l.pid and s.matchday_id = p_matchday_id
  order by p.position, p.name;
$$;

grant execute on function qm_lineup_breakdown(uuid, uuid) to authenticated;

-- ---------- 6. Classement par journée (lecture) --------------------
create or replace function qm_matchday_standings(p_matchday_id uuid)
returns table (manager_id uuid, display_name text, points numeric)
language sql stable security definer set search_path = public
as $$
  select mp.manager_id, m.display_name, mp.points
  from qm_matchday_points mp
  join qm_managers m on m.id = mp.manager_id
  where mp.matchday_id = p_matchday_id
  order by mp.points desc;
$$;

grant execute on function qm_matchday_standings(uuid) to authenticated;
