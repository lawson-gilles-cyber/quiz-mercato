-- =====================================================================
-- QUIZ MERCATO — Administration
-- =====================================================================
-- Ajoute un rôle admin et les RPC de gestion. Comme tout le reste,
-- l'écriture passe par des fonctions SECURITY DEFINER : un manager
-- normal ne peut jamais créer de joueur ni forcer un budget.
-- =====================================================================

-- ---------- Rôle admin -----------------------------------------------
alter table qm_managers add column if not exists is_admin boolean not null default false;

-- Helper : le manager courant est-il admin ?
create or replace function qm_is_admin()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select coalesce(
    (select is_admin from qm_managers where auth_user_id = auth.uid()),
    false
  );
$$;

-- ---------- Créer / mettre à jour un joueur (admin only) -------------
create or replace function qm_admin_upsert_player(
  p_id            uuid,           -- null = création, sinon mise à jour
  p_name          text,
  p_position      qm_player_position,
  p_club          text,
  p_nationality   text,
  p_age           integer,
  p_photo_url     text,
  p_value         bigint
)
returns qm_players
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player qm_players;
begin
  if not qm_is_admin() then
    raise exception 'Réservé aux administrateurs';
  end if;
  if p_value < 0 then
    raise exception 'La valeur ne peut pas être négative';
  end if;

  if p_id is null then
    -- Création : base_value et current_value démarrent identiques
    insert into qm_players (name, position, club, nationality, age, photo_url, base_value, current_value)
    values (p_name, p_position, p_club, p_nationality, p_age, p_photo_url, p_value, p_value)
    returning * into v_player;
  else
    -- Mise à jour : on ne touche pas à current_value si le joueur est déjà en jeu
    update qm_players set
      name = p_name, position = p_position, club = p_club,
      nationality = p_nationality, age = p_age, photo_url = p_photo_url,
      base_value = p_value,
      current_value = case when status = 'free' then p_value else current_value end
    where id = p_id
    returning * into v_player;
    if not found then
      raise exception 'Joueur introuvable';
    end if;
  end if;

  return v_player;
end;
$$;

-- ---------- Supprimer un joueur (admin only) ------------------------
create or replace function qm_admin_delete_player(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not qm_is_admin() then
    raise exception 'Réservé aux administrateurs';
  end if;
  -- Interdit si le joueur est possédé ou en enchère (préserve l'intégrité)
  if exists (select 1 from qm_players where id = p_id and status <> 'free') then
    raise exception 'Impossible : joueur possédé ou en enchère';
  end if;
  delete from qm_players where id = p_id;
end;
$$;

-- ---------- Ouvrir une enchère (admin only) -------------------------
-- Surcharge de qm_open_auction avec contrôle admin.
create or replace function qm_admin_open_auction(p_player_id uuid)
returns qm_auctions
language plpgsql
security definer
set search_path = public
as $$
begin
  if not qm_is_admin() then
    raise exception 'Réservé aux administrateurs';
  end if;
  return qm_open_auction(p_player_id);   -- réutilise la logique existante
end;
$$;

-- ---------- Piloter la phase du mercato (admin only) ----------------
create or replace function qm_admin_set_phase(p_phase qm_mercato_phase)
returns qm_season_state
language plpgsql
security definer
set search_path = public
as $$
declare
  v_state qm_season_state;
begin
  if not qm_is_admin() then
    raise exception 'Réservé aux administrateurs';
  end if;
  update qm_season_state set phase = p_phase, updated_at = now()
  where id = 1
  returning * into v_state;
  return v_state;
end;
$$;

-- ---------- Corriger un budget (admin only) -------------------------
create or replace function qm_admin_set_budget(p_manager_id uuid, p_budget bigint)
returns qm_managers
language plpgsql
security definer
set search_path = public
as $$
declare
  v_manager qm_managers;
begin
  if not qm_is_admin() then
    raise exception 'Réservé aux administrateurs';
  end if;
  if p_budget < 0 then
    raise exception 'Budget négatif interdit';
  end if;
  update qm_managers set budget = p_budget
  where id = p_manager_id
  returning * into v_manager;
  return v_manager;
end;
$$;

-- =====================================================================
-- IMPORTANT — te désigner comme admin
-- =====================================================================
-- Après t'être inscrit sur le site (ce qui crée ta ligne qm_managers),
-- exécute ceci UNE FOIS en remplaçant par ton email :
--
--   update qm_managers set is_admin = true
--   where auth_user_id = (select id from auth.users where email = 'ton-email@exemple.com');
-- =====================================================================
