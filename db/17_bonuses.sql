-- =====================================================================
-- ULTIMATE SQUAD — Système de bonus
-- =====================================================================
-- Les bonus créditent du BUDGET (pouvoir d'achat), pas des points de
-- classement. Deux sources :
--   1. Bonus "journée complète" : acheter au moins 1 ATT + 1 MIL + 1 DEF
--      le même jour calendaire -> +5 M€ (une fois par jour).
--   2. Bonus quiz : l'admin saisit les points quiz d'un manager, convertis
--      en M€ selon un taux réglable (1 point = X M€).
--
-- Un onglet côté manager affiche ses bonus ; l'admin en a la trace.
-- À passer APRÈS 15_scouting.sql.
-- =====================================================================

-- Réglages (SuperAdmin)
alter table qm_season_state add column if not exists full_day_bonus bigint not null default 5000000;
alter table qm_season_state add column if not exists quiz_point_value bigint not null default 500000; -- 1 pt = 0,5 M€

-- ---------- Journal des bonus ----------------------------------------
create type qm_bonus_type as enum ('full_day', 'quiz', 'other');

create table if not exists qm_bonuses (
  id          uuid primary key default gen_random_uuid(),
  manager_id  uuid not null references qm_managers(id) on delete cascade,
  bonus_type  qm_bonus_type not null,
  amount      bigint not null,          -- montant en euros crédité au budget
  detail      text,                     -- description lisible
  ref_day     date,                     -- pour le bonus journée (unicité par jour)
  created_at  timestamptz not null default now()
);

create index if not exists idx_qm_bonuses_manager on qm_bonuses(manager_id);
-- Un seul bonus "journée complète" par manager et par jour
create unique index if not exists uq_qm_bonus_fullday
  on qm_bonuses(manager_id, ref_day) where bonus_type = 'full_day';

alter table qm_bonuses enable row level security;
create policy "qm read own bonuses" on qm_bonuses for select using (
  manager_id in (select id from qm_managers where auth_user_id = auth.uid())
  or qm_is_admin()
);

-- ---------- Détection du bonus "journée complète" -------------------
-- Appelée à chaque acquisition (dans close_auction). Vérifie si le manager
-- a acheté au moins 1 ATT + 1 MIL + 1 DEF aujourd'hui ; si oui et pas
-- encore crédité ce jour, verse le bonus.
create or replace function qm_check_full_day_bonus(p_manager_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_today date := current_date;
  v_positions text[];
  v_bonus bigint;
begin
  -- Postes des joueurs acquis aujourd'hui (via transferts entrants du jour)
  select array_agg(distinct p.position::text) into v_positions
  from qm_transfers tr
  join qm_players p on p.id = tr.player_id
  where tr.to_manager = p_manager_id
    and tr.created_at::date = v_today;

  -- A-t-il au moins un ATT, un MIL et un DEF ?
  if v_positions @> array['FWD','MID','DEF'] then
    select full_day_bonus into v_bonus from qm_season_state where id = 1;
    -- Insert idempotent : l'index unique empêche le double versement
    begin
      insert into qm_bonuses (manager_id, bonus_type, amount, detail, ref_day)
      values (p_manager_id, 'full_day', v_bonus,
              'Journée complète : attaquant + milieu + défenseur achetés le même jour', v_today);
      update qm_managers set budget = budget + v_bonus where id = p_manager_id;
    exception when unique_violation then
      -- déjà crédité aujourd'hui, on ne fait rien
      null;
    end;
  end if;
end;
$$;

-- ---------- Intégrer la détection dans close_auction ----------------
create or replace function qm_close_auction(p_auction_id uuid)
returns qm_auctions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_auction    qm_auctions;
  v_player     qm_players;
  v_commission bigint;
  v_bonus      bigint;
begin
  select * into v_auction from qm_auctions where id = p_auction_id for update;
  if not found or v_auction.status <> 'open' then
    raise exception 'Enchère déjà traitée ou introuvable';
  end if;

  select * into v_player from qm_players where id = v_auction.player_id for update;

  if v_auction.top_bidder_id is null then
    update qm_players set status = 'free' where id = v_player.id;
    update qm_auctions set status = 'closed' where id = p_auction_id returning * into v_auction;
    return v_auction;
  end if;

  v_commission := qm_purchase_commission(v_auction.top_bidder_id, v_auction.player_id);

  update qm_managers
    set budget        = budget - v_auction.current_price - v_commission,
        budget_locked = budget_locked - v_auction.current_price - v_commission
    where id = v_auction.top_bidder_id;

  update qm_players
    set owner_id = v_auction.top_bidder_id, status = 'owned',
        current_value = v_auction.current_price
    where id = v_player.id;

  insert into qm_transfers (player_id, from_manager, to_manager, price)
  values (v_player.id, v_player.owner_id, v_auction.top_bidder_id, v_auction.current_price);

  -- Bonus dénicheur
  if v_auction.scouted_by is not null
     and v_auction.scouted_by <> v_auction.top_bidder_id then
    select scout_bonus into v_bonus from qm_season_state where id = 1;
    update qm_managers set budget = budget + v_bonus where id = v_auction.scouted_by;
    insert into qm_bonuses (manager_id, bonus_type, amount, detail)
    values (v_auction.scouted_by, 'other', v_bonus,
            'Bonus dénicheur : ' || v_player.name || ' remporté par un autre manager');
  end if;

  -- Bonus journée complète (vérifié après l'ajout du transfert du jour)
  perform qm_check_full_day_bonus(v_auction.top_bidder_id);

  update qm_auctions set status = 'closed' where id = p_auction_id returning * into v_auction;
  return v_auction;
end;
$$;

-- ---------- Bonus quiz : l'admin crédite un manager -----------------
create or replace function qm_admin_award_quiz(p_manager_id uuid, p_points integer)
returns qm_bonuses
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rate bigint;
  v_amount bigint;
  v_bonus qm_bonuses;
begin
  if not qm_is_admin() then raise exception 'Réservé aux administrateurs'; end if;
  if p_points <= 0 then raise exception 'Le nombre de points doit être positif'; end if;

  select quiz_point_value into v_rate from qm_season_state where id = 1;
  v_amount := p_points * v_rate;

  insert into qm_bonuses (manager_id, bonus_type, amount, detail)
  values (p_manager_id, 'quiz', v_amount,
          p_points || ' points de quiz convertis en budget')
  returning * into v_bonus;

  update qm_managers set budget = budget + v_amount where id = p_manager_id;
  return v_bonus;
end;
$$;

-- ---------- Réglages SuperAdmin -------------------------------------
create or replace function qm_admin_set_bonus_settings(
  p_full_day bigint, p_quiz_rate bigint
)
returns qm_season_state
language plpgsql
security definer
set search_path = public
as $$
declare v_state qm_season_state;
begin
  if not qm_is_admin() then raise exception 'Réservé aux administrateurs'; end if;
  update qm_season_state
    set full_day_bonus = greatest(p_full_day,0),
        quiz_point_value = greatest(p_quiz_rate,0),
        updated_at = now()
    where id = 1 returning * into v_state;
  return v_state;
end;
$$;

-- ---------- Lecture : mes bonus (manager) ---------------------------
create or replace function qm_my_bonuses()
returns table (bonus_type qm_bonus_type, amount bigint, detail text, created_at timestamptz)
language sql
security definer
set search_path = public
as $$
  select b.bonus_type, b.amount, b.detail, b.created_at
  from qm_bonuses b
  join qm_managers m on m.id = b.manager_id
  where m.auth_user_id = auth.uid()
  order by b.created_at desc;
$$;

-- ---------- Lecture : tous les bonus (admin, traçabilité) -----------
create or replace function qm_admin_all_bonuses()
returns table (manager text, bonus_type qm_bonus_type, amount bigint, detail text, created_at timestamptz)
language sql
security definer
set search_path = public
as $$
  select m.display_name, b.bonus_type, b.amount, b.detail, b.created_at
  from qm_bonuses b
  join qm_managers m on m.id = b.manager_id
  order by b.created_at desc
  limit 200;
$$;
