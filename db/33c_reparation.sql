-- =====================================================================
-- ULTIMATE SQUAD — Réparation ciblée du paquet A (33c)
-- =====================================================================
-- Le script de reprise s'était arrêté sur l'index en tête. Ici, on met
-- l'index EN DERNIER pour qu'il ne bloque plus rien, et on crée d'abord
-- les colonnes puis les fonctions manquantes.
-- À passer d'un seul bloc.
-- =====================================================================

-- 1. Colonnes manquantes (idempotent)
alter table qm_managers alter column budget set default 1000000000;
alter table qm_season_state add column if not exists same_pos_bonus bigint not null default 15000000;
alter table qm_season_state add column if not exists poker_bonus bigint not null default 10000000;
alter table qm_season_state add column if not exists budget_to_points_rate bigint not null default 10000000;

-- 2. Fonction : conversion budget -> points
create or replace function qm_convert_budget_to_points(p_amount bigint)
returns qm_managers
language plpgsql
security definer
set search_path = public
as $$
declare
  v_manager qm_managers;
  v_rate bigint;
  v_points integer;
begin
  select * into v_manager from qm_managers where auth_user_id = auth.uid() for update;
  if not found then raise exception 'Vous ne participez pas à cette saison'; end if;
  if p_amount <= 0 then raise exception 'Montant invalide'; end if;
  if p_amount > (v_manager.budget - v_manager.budget_locked) then
    raise exception 'Montant supérieur à ton budget disponible (hors enchères en cours).';
  end if;
  select budget_to_points_rate into v_rate from qm_season_state where id = 1;
  v_points := floor(p_amount / v_rate)::integer;
  if v_points < 1 then
    raise exception 'Il faut au moins % € pour convertir 1 point.', v_rate;
  end if;
  update qm_managers
    set budget = budget - (v_points::bigint * v_rate),
        season_points = season_points + v_points
    where id = v_manager.id returning * into v_manager;
  insert into qm_bonuses (manager_id, bonus_type, amount, detail)
  values (v_manager.id, 'convert', v_points::bigint * v_rate,
          'Conversion budget -> ' || v_points || ' point(s) de classement');
  return v_manager;
end;
$$;

revoke execute on function qm_convert_budget_to_points(bigint) from anon;

-- 3. Fonction : réglage admin des nouveaux bonus
create or replace function qm_admin_set_extra_bonuses(
  p_same_pos bigint, p_poker bigint, p_convert_rate bigint
)
returns qm_season_state
language plpgsql
security definer
set search_path = public
as $$
declare v_state qm_season_state;
begin
  if not qm_is_admin() then raise exception 'Réservé aux administrateurs'; end if;
  update qm_season_state set
    same_pos_bonus = greatest(p_same_pos, 0),
    poker_bonus = greatest(p_poker, 0),
    budget_to_points_rate = greatest(p_convert_rate, 1000000),
    updated_at = now()
  where id = 1 returning * into v_state;
  return v_state;
end;
$$;

revoke execute on function qm_admin_set_extra_bonuses(bigint, bigint, bigint) from anon;

-- 4. Index (EN DERNIER : s'il échoue, le reste est déjà en place)
create unique index if not exists uq_qm_bonus_samepos
  on qm_bonuses(manager_id, ref_day) where bonus_type = 'same_pos';
