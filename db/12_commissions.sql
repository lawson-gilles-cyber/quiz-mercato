-- =====================================================================
-- QUIZ MERCATO — Commissions sur les achats + fenêtre de marché
-- =====================================================================
-- 1. Commission de base sur tout achat (palier de valeur du joueur)
-- 2. Surcommission "même club" : croît avec le nb de joueurs déjà
--    détenus du même club réel (taxe la concentration Real/Barça…)
-- 3. Date d'ouverture du marché réglable en admin
--
-- La commission SORT du système (taxe de ligue) : anti-inflation.
-- Réservée dès l'enchère pour ne pas bloquer un achat à la clôture.
-- =====================================================================

-- ---------- Date d'ouverture du marché (réglage admin) ---------------
alter table qm_season_state add column if not exists market_opens_at timestamptz;
-- Par défaut : ouvert (null = pas de restriction). L'admin fixe la date.

-- ---------- Commission de base par palier de valeur ------------------
create or replace function qm_base_commission(p_value bigint)
returns bigint
language sql
immutable
as $$
  select case
    when p_value >= 100000000 then 10000000  -- 100M+  -> 10M
    when p_value >=  60000000 then  6000000   -- 60-100 -> 6M
    when p_value >=  30000000 then  3000000   -- 30-60  -> 3M
    else                            1000000   -- <30    -> 1M
  end;
$$;

-- ---------- Commission totale d'un achat (base + surcommission club) --
-- Surcommission : +50% de la base par joueur DÉJÀ détenu du même club.
--   1er joueur d'un club  -> ×1.0 (base seule)
--   2e du même club       -> ×1.5
--   3e du même club       -> ×2.0
create or replace function qm_purchase_commission(
  p_manager_id uuid,
  p_player_id  uuid
)
returns bigint
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_player     qm_players;
  v_base       bigint;
  v_same_club  integer := 0;
  v_multiplier numeric;
begin
  select * into v_player from qm_players where id = p_player_id;
  if not found then return 0; end if;

  v_base := qm_base_commission(v_player.current_value);

  -- Combien de joueurs du même club le manager possède-t-il déjà ?
  if v_player.club is not null then
    select count(*) into v_same_club
      from qm_players
      where owner_id = p_manager_id and club = v_player.club;
  end if;

  -- Multiplicateur : 1 + 0.5 par joueur déjà présent du même club
  v_multiplier := 1 + (v_same_club * 0.5);

  return round(v_base * v_multiplier)::bigint;
end;
$$;

-- ---------- Vérifie que le marché est ouvert -------------------------
create or replace function qm_market_is_open()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select market_opens_at is null or now() >= market_opens_at from qm_season_state where id = 1),
    true
  );
$$;

-- ---------- RPC admin : régler la date d'ouverture du marché ---------
create or replace function qm_admin_set_market_open(p_opens_at timestamptz)
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
  update qm_season_state set market_opens_at = p_opens_at, updated_at = now()
    where id = 1 returning * into v_state;
  return v_state;
end;
$$;

-- =====================================================================
-- Intégration dans les enchères
-- =====================================================================
-- On remplace qm_place_bid et qm_close_auction pour tenir compte de la
-- commission. La commission est vérifiée au budget lors de l'enchère
-- (offre + commission estimée) et prélevée à la clôture.
-- =====================================================================

-- ---------- place_bid (avec vérif marché ouvert + budget commission) --
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
begin
  -- Marché ouvert ?
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

  -- Règles d'effectif
  perform qm_check_squad_rules(v_manager.id, v_auction.player_id);

  -- Montant minimal
  v_min_next := v_auction.current_price + qm_min_increment(v_auction.current_price);
  if p_amount < v_min_next then
    raise exception 'Offre trop basse. Minimum: % €', v_min_next;
  end if;

  -- Budget doit couvrir offre + commission estimée
  v_commission := qm_purchase_commission(v_manager.id, v_auction.player_id);
  v_available := v_manager.budget - v_manager.budget_locked;
  if (p_amount + v_commission) > v_available then
    raise exception 'Budget insuffisant. Offre + commission (% €) dépasse le disponible (% €).',
      p_amount + v_commission, v_available;
  end if;

  -- Libère les fonds de l'ancien enchérisseur (offre + sa commission estimée)
  if v_auction.top_bidder_id is not null then
    update qm_managers
      set budget_locked = budget_locked - v_auction.current_price
                         - qm_purchase_commission(v_auction.top_bidder_id, v_auction.player_id)
      where id = v_auction.top_bidder_id;
  end if;

  -- Bloque les fonds du nouveau (offre + commission)
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

  insert into qm_bids (auction_id, manager_id, amount) values (p_auction_id, v_manager.id, p_amount);
  update qm_players set demand_score = demand_score + 1 where id = v_auction.player_id;

  return v_auction;
end;
$$;

-- ---------- close_auction (prélève prix + commission) ----------------
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

  -- Commission finale (calculée sur l'état au moment de la clôture)
  v_commission := qm_purchase_commission(v_auction.top_bidder_id, v_auction.player_id);

  -- Le gagnant paie prix + commission ; on débloque prix + commission réservés
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

  update qm_auctions set status = 'closed' where id = p_auction_id returning * into v_auction;
  return v_auction;
end;
$$;

-- ---------- Lecture publique : commission estimée d'un achat ---------
-- Permet au front d'afficher la commission avant d'enchérir.
create or replace function qm_estimate_commission(p_manager_id uuid, p_player_id uuid)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select qm_purchase_commission(p_manager_id, p_player_id);
$$;
