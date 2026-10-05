-- =====================================================================
-- ULTIMATE SQUAD — Vague 3, temps 1 : MERCATOS & RECRUTEMENT DIRECT
-- =====================================================================
-- 1. Fenêtres de mercato (été / hiver) avec dates d'ouverture/fermeture.
--    Hors fenêtre : ni enchère ni recrutement direct.
-- 2. Recrutement direct : acheter un joueur LIBRE à sa valeur, sans
--    enchère (respecte budget, quotas, masse salariale).
--
-- À passer après 40_wave3_points.sql.
-- =====================================================================

-- ---------- 0. Enum type de fenêtre --------------------------------
do $$ begin
  if not exists (select 1 from pg_type where typname='qm_window_kind') then
    create type qm_window_kind as enum ('summer','winter');
  end if;
end $$;

-- ---------- 1. Table des fenêtres de mercato -----------------------
create table if not exists qm_market_windows (
  id          uuid primary key default gen_random_uuid(),
  kind        qm_window_kind not null,
  label       text,
  opens_at    timestamptz,
  closes_at   timestamptz,
  is_active   boolean not null default false,  -- ouverte manuellement par l'admin
  created_at  timestamptz not null default now()
);

alter table qm_market_windows enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename='qm_market_windows' and policyname='qm_windows_read') then
    create policy qm_windows_read on qm_market_windows for select using (true);
  end if;
end $$;

-- ---------- 2. Une fenêtre est-elle ouverte maintenant ? -----------
-- Ouverte si : is_active = true ET (dates absentes OU now dans l'intervalle).
create or replace function qm_window_is_open()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from qm_market_windows
    where is_active = true
      and (opens_at is null or now() >= opens_at)
      and (closes_at is null or now() <= closes_at)
  );
$$;

grant execute on function qm_window_is_open() to anon, authenticated;

-- La fenêtre active courante (pour affichage)
create or replace function qm_current_window()
returns qm_market_windows
language sql stable security definer set search_path = public
as $$
  select * from qm_market_windows
  where is_active = true
    and (opens_at is null or now() >= opens_at)
    and (closes_at is null or now() <= closes_at)
  order by created_at desc limit 1;
$$;

grant execute on function qm_current_window() to anon, authenticated;

-- ---------- 3. Admin : gérer les fenêtres --------------------------
create or replace function qm_admin_create_window(p_kind qm_window_kind, p_label text, p_opens timestamptz, p_closes timestamptz)
returns qm_market_windows
language plpgsql security definer set search_path = public
as $$
declare v_w qm_market_windows;
begin
  if not qm_is_admin() then raise exception 'Réservé aux administrateurs'; end if;
  insert into qm_market_windows (kind, label, opens_at, closes_at)
  values (p_kind, coalesce(p_label, case p_kind when 'summer' then 'Mercato d''été' else 'Mercato d''hiver' end), p_opens, p_closes)
  returning * into v_w;
  return v_w;
end; $$;

create or replace function qm_admin_set_window_active(p_window_id uuid, p_active boolean)
returns qm_market_windows
language plpgsql security definer set search_path = public
as $$
declare v_w qm_market_windows;
begin
  if not qm_is_admin() then raise exception 'Réservé aux administrateurs'; end if;
  -- Une seule fenêtre active à la fois : on désactive les autres si on active celle-ci
  if p_active then
    update qm_market_windows set is_active = false where id <> p_window_id;
  end if;
  update qm_market_windows set is_active = p_active where id = p_window_id returning * into v_w;
  if not found then raise exception 'Fenêtre introuvable'; end if;
  return v_w;
end; $$;

revoke execute on function qm_admin_create_window(qm_window_kind, text, timestamptz, timestamptz) from anon;
revoke execute on function qm_admin_set_window_active(uuid, boolean) from anon;

-- ---------- 4. Recrutement direct (sans enchère) -------------------
-- Le manager achète un joueur LIBRE à sa valeur actuelle. Vérifie :
-- fenêtre ouverte, joueur libre, budget suffisant, quotas, masse salariale.
create or replace function qm_direct_recruit(p_player_id uuid)
returns qm_players
language plpgsql security definer set search_path = public
as $$
declare
  v_manager qm_managers;
  v_player  qm_players;
  v_price   bigint;
  v_available bigint;
begin
  -- Manager courant (le recrutement est une action de Manager, pas de Coach)
  select * into v_manager from qm_managers where auth_user_id = auth.uid() for update;
  if not found then raise exception 'Vous ne participez pas à cette saison'; end if;
  if v_manager.is_coach then
    raise exception 'Le recrutement est réservé au Manager (pas au Coach).';
  end if;

  -- Fenêtre de mercato ouverte ?
  if not qm_window_is_open() then
    raise exception 'Aucun mercato n''est ouvert actuellement.';
  end if;

  -- Joueur libre ?
  select * into v_player from qm_players where id = p_player_id for update;
  if not found then raise exception 'Joueur introuvable'; end if;
  if v_player.status <> 'free' or v_player.owner_id is not null then
    raise exception 'Ce joueur n''est pas disponible (déjà pris ou en enchère).';
  end if;

  v_price := v_player.current_value;

  -- Budget disponible (hors fonds engagés)
  v_available := v_manager.budget - v_manager.budget_locked;
  if v_price > v_available then
    raise exception 'Budget insuffisant : % requis, % disponible.', v_price, v_available;
  end if;

  -- Règles d'effectif (quotas, club, championnat) et masse salariale
  perform qm_check_squad_rules(v_manager.id, p_player_id);
  perform qm_check_salary_cap(v_manager.id, p_player_id);

  -- Transaction : débit + attribution + trace
  update qm_managers set budget = budget - v_price where id = v_manager.id;
  update qm_players set owner_id = v_manager.id, status = 'owned' where id = p_player_id
    returning * into v_player;
  insert into qm_transfers (player_id, from_manager, to_manager, price)
  values (p_player_id, null, v_manager.id, v_price);

  -- Bonus "journée complète / même poste" éventuel (comme une acquisition)
  perform qm_check_full_day_bonus(v_manager.id);

  return v_player;
end; $$;

grant execute on function qm_direct_recruit(uuid) to authenticated;
revoke execute on function qm_direct_recruit(uuid) from anon;
