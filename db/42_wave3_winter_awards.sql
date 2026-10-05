-- =====================================================================
-- ULTIMATE SQUAD — Vague 3, temps 2 : POINTS→BUDGET & RÉCOMPENSES
-- =====================================================================
-- 1. Conversion points -> budget, réservée au mercato d'HIVER, plafonnée
--    à 200 points au total par manager.
-- 2. Récompenses de fin de saison (Champion, etc.).
--
-- Note de conception : le classement (season_points) est recalculé par
-- qm_recompute_standings comme (points de journée + conversions budget->points).
-- Pour que retirer des points via points->budget soit durable et ne soit
-- pas "ré-ajouté" au prochain recalcul, on stocke le total de points
-- dépensés (points_spent) et on le SOUSTRAIT dans le recalcul.
--
-- À passer après 41_wave3_mercatos.sql.
-- =====================================================================

-- ---------- 1. Compteurs dédiés ------------------------------------
alter table qm_managers add column if not exists points_spent integer not null default 0;   -- points convertis en budget (cumul)
-- Plafond de conversion points->budget (défaut 200 points)
alter table qm_season_state add column if not exists points_convert_cap integer not null default 200;

-- ---------- 2. Recalcul du classement : tenir compte de points_spent
-- On redéfinit qm_recompute_standings (version 40) en soustrayant les
-- points dépensés en budget.
create or replace function qm_recompute_standings()
returns void
language plpgsql security definer set search_path = public
as $$
declare v_rate bigint;
begin
  select budget_to_points_rate into v_rate from qm_season_state where id = 1;
  if v_rate is null or v_rate < 1 then v_rate := 10000000; end if;

  update qm_managers m set season_points = greatest(0,
      coalesce((select round(sum(points))::integer from qm_matchday_points where manager_id = m.id), 0)
    + coalesce((select sum(floor(amount / v_rate))::integer from qm_bonuses
                where manager_id = m.id and bonus_type = 'convert'), 0)
    - coalesce(m.points_spent, 0)
  );
end; $$;

-- ---------- 3. Conversion points -> budget (hiver seulement) -------
-- Convertit p_points points en budget, au taux courant (10 M€ = 1 point
-- par défaut => 1 point = budget_to_points_rate €). Conditions :
--   - un mercato d'HIVER doit être ouvert,
--   - le manager doit avoir assez de points disponibles au classement,
--   - le total converti (points_spent) ne dépasse pas points_convert_cap.
create or replace function qm_convert_points_to_budget(p_points integer)
returns qm_managers
language plpgsql security definer set search_path = public
as $$
declare
  v_manager qm_managers;
  v_rate bigint;
  v_cap integer;
  v_gain bigint;
  v_winter_open boolean;
begin
  select * into v_manager from qm_managers where auth_user_id = auth.uid() for update;
  if not found then raise exception 'Vous ne participez pas à cette saison'; end if;
  if p_points <= 0 then raise exception 'Nombre de points invalide'; end if;

  -- Un mercato d'hiver doit être ouvert
  select exists (
    select 1 from qm_market_windows
    where kind = 'winter' and is_active = true
      and (opens_at is null or now() >= opens_at)
      and (closes_at is null or now() <= closes_at)
  ) into v_winter_open;
  if not v_winter_open then
    raise exception 'La conversion points -> budget n''est possible que pendant le mercato d''hiver.';
  end if;

  -- Assez de points au classement ?
  if p_points > v_manager.season_points then
    raise exception 'Points insuffisants : tu as % point(s) au classement.', v_manager.season_points;
  end if;

  -- Plafond cumulé
  select points_convert_cap, budget_to_points_rate into v_cap, v_rate from qm_season_state where id = 1;
  if coalesce(v_manager.points_spent,0) + p_points > v_cap then
    raise exception 'Plafond atteint : maximum % points convertibles au total (déjà converti : %).',
      v_cap, coalesce(v_manager.points_spent,0);
  end if;

  v_gain := p_points::bigint * v_rate;

  update qm_managers
    set budget = budget + v_gain,
        points_spent = coalesce(points_spent,0) + p_points
    where id = v_manager.id returning * into v_manager;

  insert into qm_bonuses (manager_id, bonus_type, amount, detail)
  values (v_manager.id, 'convert', -v_gain,
          'Conversion ' || p_points || ' point(s) -> budget (mercato hiver)');

  -- Recalcule le classement (retranche les points dépensés)
  perform qm_recompute_standings();
  select * into v_manager from qm_managers where id = v_manager.id;
  return v_manager;
end; $$;

revoke execute on function qm_convert_points_to_budget(integer) from anon;

-- ---------- 4. Récompenses de fin de saison ------------------------
-- Table simple des titres décernés par l'admin en fin de saison.
create table if not exists qm_awards (
  id          uuid primary key default gen_random_uuid(),
  manager_id  uuid references qm_managers(id) on delete set null,
  title       text not null,           -- ex : 'Champion Ultimate Squad'
  detail      text,
  awarded_at  timestamptz not null default now()
);

alter table qm_awards enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename='qm_awards' and policyname='qm_awards_read') then
    create policy qm_awards_read on qm_awards for select using (true);
  end if;
end $$;

-- Admin : décerner un titre
create or replace function qm_admin_grant_award(p_manager_id uuid, p_title text, p_detail text)
returns qm_awards
language plpgsql security definer set search_path = public
as $$
declare v_a qm_awards;
begin
  if not qm_is_admin() then raise exception 'Réservé aux administrateurs'; end if;
  insert into qm_awards (manager_id, title, detail)
  values (p_manager_id, p_title, p_detail) returning * into v_a;
  return v_a;
end; $$;

revoke execute on function qm_admin_grant_award(uuid, text, text) from anon;

-- Admin : décerner automatiquement le titre de Champion (meilleur classement)
create or replace function qm_admin_crown_champion()
returns qm_awards
language plpgsql security definer set search_path = public
as $$
declare v_top uuid; v_name text; v_a qm_awards;
begin
  if not qm_is_admin() then raise exception 'Réservé aux administrateurs'; end if;
  select id, display_name into v_top, v_name from qm_managers
    where is_coach = false or is_coach is null
    order by season_points desc limit 1;
  if v_top is null then raise exception 'Aucun manager au classement'; end if;
  insert into qm_awards (manager_id, title, detail)
  values (v_top, '🥇 Champion Ultimate Squad', 'Meilleur classement général de la saison')
  returning * into v_a;
  return v_a;
end; $$;

revoke execute on function qm_admin_grant_award(uuid, text, text) from anon;
revoke execute on function qm_admin_crown_champion() from anon;
