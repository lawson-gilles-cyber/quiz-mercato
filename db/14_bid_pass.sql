-- =====================================================================
-- QUIZ MERCATO — Système de PASS (limite d'offres par enchère)
-- =====================================================================
-- Pour éviter les enchères qui flambent (un joueur à 80M vendu 400M),
-- chaque manager ne peut faire qu'un nombre limité d'offres par joueur.
-- Cela force à réfléchir avant de miser et casse la spirale de surenchère.
--
-- Réglage : nombre de PASS de base, stocké dans season_state (modifiable).
-- Par défaut : 3 offres maximum par manager et par enchère.
--
-- Redéfinit qm_place_bid. À passer APRÈS 12_commissions.sql.
-- =====================================================================

-- Nombre de PASS de base (réglable en admin)
alter table qm_season_state add column if not exists bid_pass_limit integer not null default 3;

-- ---------- Combien d'offres ce manager a-t-il déjà faites ? ----------
create or replace function qm_bids_used(p_auction_id uuid, p_manager_id uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::integer from qm_bids
  where auction_id = p_auction_id and manager_id = p_manager_id;
$$;

-- ---------- PASS restants pour le manager courant (pour le front) -----
create or replace function qm_my_passes(p_auction_id uuid)
returns integer
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_manager_id uuid;
  v_limit integer;
  v_used integer;
begin
  select id into v_manager_id from qm_managers where auth_user_id = auth.uid();
  if v_manager_id is null then return 0; end if;
  select bid_pass_limit into v_limit from qm_season_state where id = 1;
  v_used := qm_bids_used(p_auction_id, v_manager_id);
  return greatest(v_limit - v_used, 0);
end;
$$;

-- ---------- place_bid AVEC contrôle de PASS --------------------------
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

  -- ----- Contrôle des PASS : nombre d'offres déjà faites sur ce joueur -----
  select bid_pass_limit into v_limit from qm_season_state where id = 1;
  v_used := qm_bids_used(p_auction_id, v_manager.id);
  if v_used >= v_limit then
    raise exception 'Plus de PASS disponible : vous avez déjà fait % offres sur ce joueur (limite %).',
      v_used, v_limit;
  end if;

  -- Règles d'effectif
  perform qm_check_squad_rules(v_manager.id, v_auction.player_id);

  -- Montant minimal
  v_min_next := v_auction.current_price + qm_min_increment(v_auction.current_price);
  if p_amount < v_min_next then
    raise exception 'Offre trop basse. Minimum: % €', v_min_next;
  end if;

  -- Budget doit couvrir offre + commission
  v_commission := qm_purchase_commission(v_manager.id, v_auction.player_id);
  v_available := v_manager.budget - v_manager.budget_locked;
  if (p_amount + v_commission) > v_available then
    raise exception 'Budget insuffisant. Offre + commission (% €) dépasse le disponible (% €).',
      p_amount + v_commission, v_available;
  end if;

  -- Libère les fonds de l'ancien enchérisseur
  if v_auction.top_bidder_id is not null then
    update qm_managers
      set budget_locked = budget_locked - v_auction.current_price
                         - qm_purchase_commission(v_auction.top_bidder_id, v_auction.player_id)
      where id = v_auction.top_bidder_id;
  end if;

  -- Bloque les fonds du nouveau
  update qm_managers
    set budget_locked = budget_locked + p_amount + v_commission
    where id = v_manager.id;

  -- Anti-snipe
  if v_auction.ends_at - now() < interval '10 minutes' then
    v_auction.ends_at := now() + interval '10 minutes';
  end if;

  update qm_auctions
    set current_price = p_amount, top_bidder_id = v_manager.id, ends_at = v_auction.ends_at
    where id = p_auction_id returning * into v_auction;

  -- Enregistre l'offre (compte comme un PASS consommé)
  insert into qm_bids (auction_id, manager_id, amount) values (p_auction_id, v_manager.id, p_amount);
  update qm_players set demand_score = demand_score + 1 where id = v_auction.player_id;

  return v_auction;
end;
$$;

-- ---------- RPC admin : régler la limite de PASS --------------------
create or replace function qm_admin_set_pass_limit(p_limit integer)
returns qm_season_state
language plpgsql
security definer
set search_path = public
as $$
declare v_state qm_season_state;
begin
  if not qm_is_admin() then
    raise exception 'Réservé aux administrateurs';
  end if;
  if p_limit < 1 then raise exception 'La limite doit être au moins 1'; end if;
  update qm_season_state set bid_pass_limit = p_limit, updated_at = now()
    where id = 1 returning * into v_state;
  return v_state;
end;
$$;
