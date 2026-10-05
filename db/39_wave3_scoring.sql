-- =====================================================================
-- ULTIMATE SQUAD — Vague 3, Étape 3 : SAISIE DES NOTES
-- =====================================================================
-- Objectif : rendre la saisie hebdomadaire tenable à ~30 managers.
-- Principe : on ne note QUE les joueurs réellement alignés cette journée,
-- et CHAQUE joueur une seule fois (même s'il est aligné par 15 équipes).
--
-- 1. qm_scoring_players : liste les joueurs à noter pour une journée
--    (distincts, avec le nombre d'équipes qui les alignent + note déjà saisie).
-- 2. qm_admin_set_scores : enregistre un lot de notes (note + statut).
--
-- À passer après 38_wave3_lineups.sql.
-- =====================================================================

-- ---------- 1. Joueurs à noter pour une journée --------------------
-- Renvoie chaque joueur DISTINCT aligné par au moins une équipe à cette
-- journée, avec : poste, club, nb d'équipes qui l'alignent, note et
-- statut déjà saisis (NULL si pas encore noté).
create or replace function qm_scoring_players(p_matchday_id uuid)
returns table (
  player_id uuid,
  name text,
  pos qm_player_position,
  club text,
  lineups_count integer,
  rating numeric,
  play_status qm_play_status
)
language sql stable security definer set search_path = public
as $$
  with aligned as (
    select distinct unnest(l.player_ids) as pid
    from qm_lineups l
    where l.matchday_id = p_matchday_id
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
    coalesce(c.cnt, 0),
    s.rating, coalesce(s.play_status, 'dnp')
  from aligned a
  join qm_players p on p.id = a.pid
  left join counts c on c.pid = a.pid
  left join qm_player_scores s on s.player_id = a.pid and s.matchday_id = p_matchday_id
  order by p.position, p.name;
$$;

grant execute on function qm_scoring_players(uuid) to authenticated;
revoke execute on function qm_scoring_players(uuid) from anon;

-- ---------- 2. Enregistrer un lot de notes -------------------------
-- Reçoit un JSON : [{"player_id":"...","rating":7.5,"play_status":"starter"}, ...]
-- Upsert dans qm_player_scores. Réservé admin. Renvoie le nb de lignes.
create or replace function qm_admin_set_scores(p_matchday_id uuid, p_data jsonb)
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  v_item jsonb;
  v_me uuid;
  v_count integer := 0;
  v_rating numeric;
  v_status qm_play_status;
begin
  if not qm_is_admin() then raise exception 'Réservé aux administrateurs'; end if;
  if not exists (select 1 from qm_matchdays where id = p_matchday_id) then
    raise exception 'Journée introuvable';
  end if;
  select id into v_me from qm_managers where auth_user_id = auth.uid();

  for v_item in select * from jsonb_array_elements(p_data)
  loop
    -- note optionnelle (peut être null si on saisit juste le statut)
    v_rating := case when v_item->>'rating' is null or v_item->>'rating'='' then null
                     else (v_item->>'rating')::numeric end;
    v_status := coalesce((v_item->>'play_status')::qm_play_status, 'dnp');

    -- borne de sécurité sur la note (0 à 10, format Sofascore)
    if v_rating is not null and (v_rating < 0 or v_rating > 10) then
      raise exception 'Note invalide (%): doit être entre 0 et 10.', v_rating;
    end if;

    insert into qm_player_scores (player_id, matchday_id, rating, play_status, scored_by, updated_at)
    values ((v_item->>'player_id')::uuid, p_matchday_id, v_rating, v_status, v_me, now())
    on conflict (player_id, matchday_id)
    do update set rating = excluded.rating, play_status = excluded.play_status,
                  scored_by = excluded.scored_by, updated_at = now();
    v_count := v_count + 1;
  end loop;

  return v_count;
end; $$;

revoke execute on function qm_admin_set_scores(uuid, jsonb) from anon;

-- ---------- 3. Progression de saisie (pour l'admin) ----------------
-- Combien de joueurs alignés sont déjà notés vs total, pour une journée.
create or replace function qm_scoring_progress(p_matchday_id uuid)
returns table (total integer, scored integer)
language sql stable security definer set search_path = public
as $$
  with aligned as (
    select distinct unnest(player_ids) as pid
    from qm_lineups where matchday_id = p_matchday_id
  )
  select
    (select count(*)::integer from aligned),
    (select count(*)::integer from aligned a
       join qm_player_scores s on s.player_id = a.pid and s.matchday_id = p_matchday_id
       where s.rating is not null);
$$;

grant execute on function qm_scoring_progress(uuid) to authenticated;
