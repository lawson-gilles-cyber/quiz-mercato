-- =====================================================================
-- ULTIMATE SQUAD — Vague 3, Étape 2 : JOURNÉES, COACH, ALIGNEMENT
-- =====================================================================
-- 1. Admin : créer / ouvrir / gérer une journée.
-- 2. Admin : associer un compte Coach à une équipe.
-- 3. Coach (ou Manager) : aligner les 11 titulaires d'une journée.
-- 4. Reconduction auto de la compo précédente si non alignée.
--
-- À passer après 37_wave3_foundations.sql.
-- =====================================================================

-- ---------- 1. ADMIN : gérer les journées --------------------------
create or replace function qm_admin_create_matchday(p_number integer, p_label text, p_deadline timestamptz)
returns qm_matchdays
language plpgsql security definer set search_path = public
as $$
declare v_md qm_matchdays;
begin
  if not qm_is_admin() then raise exception 'Réservé aux administrateurs'; end if;
  insert into qm_matchdays (number, label, lineup_deadline, status)
  values (p_number, coalesce(p_label, 'Journée '||p_number), p_deadline, 'upcoming')
  returning * into v_md;
  return v_md;
end; $$;

create or replace function qm_admin_set_matchday_status(p_matchday_id uuid, p_status qm_matchday_status)
returns qm_matchdays
language plpgsql security definer set search_path = public
as $$
declare v_md qm_matchdays;
begin
  if not qm_is_admin() then raise exception 'Réservé aux administrateurs'; end if;
  update qm_matchdays set status = p_status where id = p_matchday_id returning * into v_md;
  if not found then raise exception 'Journée introuvable'; end if;

  -- À l'ouverture d'une journée : reconduire les compos de la précédente
  if p_status = 'open' then
    perform qm_reconduct_lineups(p_matchday_id);
  end if;
  return v_md;
end; $$;

revoke execute on function qm_admin_create_matchday(integer, text, timestamptz) from anon;
revoke execute on function qm_admin_set_matchday_status(uuid, qm_matchday_status) from anon;

-- ---------- 2. ADMIN : associer un Coach à une équipe --------------
-- p_coach_id = le compte qui devient coach ; p_team_id = l'équipe (Manager) coachée.
create or replace function qm_admin_assign_coach(p_coach_id uuid, p_team_id uuid)
returns qm_managers
language plpgsql security definer set search_path = public
as $$
declare v_coach qm_managers;
begin
  if not qm_is_admin() then raise exception 'Réservé aux administrateurs'; end if;
  if p_coach_id = p_team_id then raise exception 'Un compte ne peut pas se coacher lui-même'; end if;
  -- Vérifs d'existence
  if not exists (select 1 from qm_managers where id = p_team_id) then raise exception 'Équipe introuvable'; end if;
  update qm_managers
    set coach_of = p_team_id, is_coach = true
    where id = p_coach_id returning * into v_coach;
  if not found then raise exception 'Compte coach introuvable'; end if;
  return v_coach;
end; $$;

create or replace function qm_admin_unassign_coach(p_coach_id uuid)
returns qm_managers
language plpgsql security definer set search_path = public
as $$
declare v_coach qm_managers;
begin
  if not qm_is_admin() then raise exception 'Réservé aux administrateurs'; end if;
  update qm_managers set coach_of = null, is_coach = false
    where id = p_coach_id returning * into v_coach;
  return v_coach;
end; $$;

revoke execute on function qm_admin_assign_coach(uuid, uuid) from anon;
revoke execute on function qm_admin_unassign_coach(uuid) from anon;

-- ---------- 3. Résoudre "quelle équipe ce compte gère-t-il ?" ------
-- Un compte peut être : un Manager (gère sa propre équipe) OU un Coach
-- (gère l'équipe pointée par coach_of). Renvoie l'id de l'équipe.
create or replace function qm_my_team_id()
returns uuid
language sql stable security definer set search_path = public
as $$
  select case when m.is_coach and m.coach_of is not null then m.coach_of else m.id end
  from qm_managers m where m.auth_user_id = auth.uid();
$$;

grant execute on function qm_my_team_id() to authenticated;

-- ---------- 4. Aligner les 11 titulaires ---------------------------
-- Le Coach (ou le Manager si pas de coach) fournit exactement 11 joueurs
-- qui lui appartiennent. Vérifie la propriété et la date limite.
create or replace function qm_set_lineup(p_matchday_id uuid, p_player_ids uuid[])
returns qm_lineups
language plpgsql security definer set search_path = public
as $$
declare
  v_team uuid;
  v_me   uuid;
  v_md   qm_matchdays;
  v_count integer;
  v_owned integer;
  v_line qm_lineups;
begin
  v_team := qm_my_team_id();
  if v_team is null then raise exception 'Vous ne participez pas à cette saison'; end if;
  select id into v_me from qm_managers where auth_user_id = auth.uid();

  select * into v_md from qm_matchdays where id = p_matchday_id;
  if not found then raise exception 'Journée introuvable'; end if;
  if v_md.status <> 'open' then raise exception 'Cette journée n''est pas ouverte à l''alignement'; end if;
  if v_md.lineup_deadline is not null and now() > v_md.lineup_deadline then
    raise exception 'La date limite d''alignement est dépassée';
  end if;

  -- Exactement 11 joueurs, distincts
  v_count := array_length(p_player_ids, 1);
  if v_count is null or v_count <> 11 then
    raise exception 'Il faut exactement 11 joueurs (reçu %).', coalesce(v_count,0);
  end if;
  if (select count(distinct x) from unnest(p_player_ids) x) <> 11 then
    raise exception 'Les 11 joueurs doivent être distincts';
  end if;

  -- Tous doivent appartenir à l'équipe
  select count(*) into v_owned from qm_players
    where id = any(p_player_ids) and owner_id = v_team;
  if v_owned <> 11 then
    raise exception 'Les 11 joueurs doivent tous appartenir à ton effectif';
  end if;

  insert into qm_lineups (manager_id, matchday_id, player_ids, set_by, reconducted, updated_at)
  values (v_team, p_matchday_id, p_player_ids, v_me, false, now())
  on conflict (manager_id, matchday_id)
  do update set player_ids = excluded.player_ids, set_by = excluded.set_by,
                reconducted = false, updated_at = now()
  returning * into v_line;
  return v_line;
end; $$;

grant execute on function qm_set_lineup(uuid, uuid[]) to authenticated;
revoke execute on function qm_set_lineup(uuid, uuid[]) from anon;

-- ---------- 5. Reconduction automatique ----------------------------
-- Pour une journée qui s'ouvre : chaque équipe qui avait une compo à la
-- journée précédente (par numéro) la récupère automatiquement, marquée
-- "reconducted". Les équipes sans historique n'ont rien (à aligner).
create or replace function qm_reconduct_lineups(p_matchday_id uuid)
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  v_num integer;
  v_prev_id uuid;
  v_count integer := 0;
begin
  select number into v_num from qm_matchdays where id = p_matchday_id;
  if v_num is null then return 0; end if;
  -- Journée précédente (numéro juste inférieur)
  select id into v_prev_id from qm_matchdays where number < v_num order by number desc limit 1;
  if v_prev_id is null then return 0; end if;

  insert into qm_lineups (manager_id, matchday_id, player_ids, set_by, reconducted, updated_at)
  select l.manager_id, p_matchday_id, l.player_ids, l.set_by, true, now()
  from qm_lineups l where l.matchday_id = v_prev_id
  on conflict (manager_id, matchday_id) do nothing;  -- ne pas écraser une compo déjà posée
  get diagnostics v_count = row_count;
  return v_count;
end; $$;

-- ---------- 6. Lecture : ma compo pour une journée -----------------
create or replace function qm_my_lineup(p_matchday_id uuid)
returns qm_lineups
language sql stable security definer set search_path = public
as $$
  select * from qm_lineups
  where matchday_id = p_matchday_id and manager_id = qm_my_team_id();
$$;

grant execute on function qm_my_lineup(uuid) to authenticated;
