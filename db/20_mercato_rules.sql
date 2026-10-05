-- =====================================================================
-- ULTIMATE SQUAD — Règles de rythme du mercato (bloc B)
-- =====================================================================
-- 1. 6 enchères actives maximum (au total sur la plateforme).
-- 2. 3 achats maximum par jour et par manager.
-- 3. Rappel visuel : chaque manager devrait proposer 2 joueurs/jour
--    (incitatif, non bloquant).
--
-- Réglages stockés dans season_state (modifiables en admin).
-- À passer APRÈS 19_salary.sql (redéfinit qm_open_auction et qm_place_bid).
-- =====================================================================

alter table qm_season_state add column if not exists max_active_auctions integer not null default 6;
alter table qm_season_state add column if not exists max_daily_purchases integer not null default 3;
alter table qm_season_state add column if not exists daily_proposals_target integer not null default 2;

-- ---------- Nombre d'enchères actives -------------------------------
create or replace function qm_active_auctions_count()
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::integer from qm_auctions where status = 'open';
$$;

-- ---------- Achats du jour pour un manager --------------------------
-- Compte les joueurs acquis aujourd'hui (transferts entrants depuis le
-- marché : from_manager null = achat aux enchères).
create or replace function qm_daily_purchases(p_manager_id uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::integer from qm_transfers
  where to_manager = p_manager_id
    and from_manager is null
    and created_at::date = current_date;
$$;

-- ---------- Propositions du jour pour un manager (pour rappel) ------
create or replace function qm_daily_proposals_made()
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::integer from qm_player_proposals pr
  join qm_managers m on m.id = pr.proposer_id
  where m.auth_user_id = auth.uid()
    and pr.created_at::date = current_date;
$$;

-- ---------- Rappel : combien de propositions reste-t-il à faire ? --
create or replace function qm_proposals_reminder()
returns table (made integer, target integer, remaining integer)
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_target integer; v_made integer;
begin
  select daily_proposals_target into v_target from qm_season_state where id = 1;
  v_made := qm_daily_proposals_made();
  made := v_made;
  target := v_target;
  remaining := greatest(v_target - v_made, 0);
  return next;
end;
$$;

-- ---------- qm_open_auction avec limite d'enchères actives ---------
-- On récupère la version existante et on ajoute le contrôle en tête.
create or replace function qm_open_auction(p_player_id uuid)
returns qm_auctions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player  qm_players;
  v_hours   integer;
  v_auction qm_auctions;
  v_active  integer;
  v_max     integer;
begin
  -- Limite d'enchères actives
  select max_active_auctions into v_max from qm_season_state where id = 1;
  v_active := qm_active_auctions_count();
  if v_active >= v_max then
    raise exception 'Limite d''enchères actives atteinte (% / %). Attendez qu''une enchère se termine.',
      v_active, v_max;
  end if;

  select * into v_player from qm_players where id = p_player_id for update;
  if not found then raise exception 'Joueur introuvable'; end if;
  if v_player.status <> 'free' then raise exception 'Ce joueur n''est pas disponible.'; end if;

  select auction_hours into v_hours from qm_season_state where id = 1;

  insert into qm_auctions (player_id, current_price, ends_at)
  values (v_player.id, v_player.current_value, now() + (v_hours || ' hours')::interval)
  returning * into v_auction;

  update qm_players set status = 'locked' where id = v_player.id;
  return v_auction;
end;
$$;

-- ---------- qm_place_bid avec limite d'achats quotidiens -----------
-- Version complète intégrant : marché ouvert, PASS, effectif, salaire,
-- budget, commission, ET la limite de 3 achats/jour.
create or replace function qm_place_bid(p_auction_id uuid, p_amount bigint)
returns qm_auctions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_auction   qm_auctions;
  v_manager   qm_managers;
  v_min_next  bigint;
  v_available bigint;
  v_commission bigint;
  v_limit     integer;
  v_used      integer;
  v_daily     integer;
  v_daily_max integer;
begin
  if not qm_market_is_open() then
    raise exception 'Le marché des transferts n''est pas encore ouvert.';
  end if;

  select * into v_manager from qm_managers where auth_user_id = auth.uid() for update;
  if not found then raise exception 'Vous ne participez pas à cette saison'; end if;

  select * into v_auction from qm_auctions where id = p_auction_id for update;
  if not found then raise exception 'Enchère introuvable'; end if;
  if v_auction.status <> 'open' then raise exception 'Enchère fermée'; end if;
  if now() >= v_auction.ends_at then raise exception 'Enchère expirée'; end if;
  if v_auction.top_bidder_id = v_manager.id then
    raise exception 'Vous êtes déjà le meilleur enchérisseur';
  end if;

  -- Limite de 3 achats par jour (on empêche d'enchérir si déjà atteint,
  -- car remporter une nouvelle enchère dépasserait la limite)
  select max_daily_purchases into v_daily_max from qm_season_state where id = 1;
  v_daily := qm_daily_purchases(v_manager.id);
  if v_daily >= v_daily_max then
    raise exception 'Limite de % achats par jour atteinte. Reviens demain pour enchérir.', v_daily_max;
  end if;

  -- PASS
  select bid_pass_limit into v_limit from qm_season_state where id = 1;
  v_used := qm_bids_used(p_auction_id, v_manager.id);
  if v_used >= v_limit then
    raise exception 'Plus de PASS disponible : déjà % offres sur ce joueur (limite %).', v_used, v_limit;
  end if;

  -- Effectif
  perform qm_check_squad_rules(v_manager.id, v_auction.player_id);
  -- Masse salariale
  perform qm_check_salary_cap(v_manager.id, v_auction.player_id);

  v_min_next := v_auction.current_price + qm_min_increment(v_auction.current_price);
  if p_amount < v_min_next then
    raise exception 'Offre trop basse. Minimum: % €', v_min_next;
  end if;

  v_commission := qm_purchase_commission(v_manager.id, v_auction.player_id);
  v_available := v_manager.budget - v_manager.budget_locked;
  if (p_amount + v_commission) > v_available then
    raise exception 'Budget transfert insuffisant. Offre + commission (% €) > disponible (% €).',
      p_amount + v_commission, v_available;
  end if;

  if v_auction.top_bidder_id is not null then
    update qm_managers
      set budget_locked = budget_locked - v_auction.current_price
                         - qm_purchase_commission(v_auction.top_bidder_id, v_auction.player_id)
      where id = v_auction.top_bidder_id;
  end if;

  update qm_managers
    set budget_locked = budget_locked + p_amount + v_commission
    where id = v_manager.id;

  if v_auction.ends_at - now() < interval '10 minutes' then
    v_auction.ends_at := now() + interval '10 minutes';
  end if;

  update qm_auctions
    set current_price = p_amount, top_bidder_id = v_manager.id, ends_at = v_auction.ends_at
    where id = p_auction_id returning * into v_auction;

  insert into qm_bids (auction_id, manager_id, amount) values (p_auction_id, v_manager.id, p_amount);
  update qm_players set demand_score = demand_score + 1 where id = v_auction.player_id;

  return v_auction;
end;
$$;

-- ---------- Réglages admin des règles de rythme --------------------
create or replace function qm_admin_set_mercato_rules(
  p_max_auctions integer, p_max_daily integer, p_proposals_target integer
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
    max_active_auctions = greatest(p_max_auctions, 1),
    max_daily_purchases = greatest(p_max_daily, 1),
    daily_proposals_target = greatest(p_proposals_target, 0),
    updated_at = now()
  where id = 1 returning * into v_state;
  return v_state;
end;
$$;
