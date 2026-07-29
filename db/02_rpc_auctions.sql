-- =====================================================================
-- QUIZ MERCATO — Logique d'enchères (RPC atomiques)
-- =====================================================================
-- Tout passe par des fonctions SECURITY DEFINER qui verrouillent les
-- lignes concernées. C'est ce qui rend les enchères fiables sous forte
-- concurrence — impossible en no-code, natif ici.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Ouvrir une enchère sur un joueur (admin uniquement, en principe)
-- ---------------------------------------------------------------------
create or replace function qm_open_auction(p_player_id uuid)
returns qm_auctions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player   qm_players;
  v_hours    integer;
  v_auction  qm_auctions;
begin
  -- Verrou sur le joueur : personne d'autre ne peut le modifier pendant ce temps
  select * into v_player from qm_players where id = p_player_id for update;
  if not found then
    raise exception 'Joueur introuvable';
  end if;
  if v_player.status <> 'free' then
    raise exception 'Joueur non disponible (statut: %)', v_player.status;
  end if;

  select auction_hours into v_hours from qm_season_state where id = 1;

  insert into qm_auctions (player_id, current_price, ends_at)
  values (p_player_id, v_player.current_value, now() + (v_hours || ' hours')::interval)
  returning * into v_auction;

  update qm_players set status = 'locked' where id = p_player_id;

  return v_auction;
end;
$$;

-- ---------------------------------------------------------------------
-- Placer une offre — LA fonction critique
-- ---------------------------------------------------------------------
-- Garanties :
--   * verrou pessimiste sur l'enchère (FOR UPDATE) → sérialise les offres
--   * vérifie le montant minimal selon le barème
--   * vérifie le budget DISPONIBLE du nouvel enchérisseur
--   * libère les fonds de l'ancien meilleur enchérisseur, bloque ceux du nouveau
--   * anti-snipe : prolonge de 10 min si offre dans les 10 dernières minutes
-- ---------------------------------------------------------------------
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
begin
  -- Résout le manager courant depuis l'auth
  select * into v_manager from qm_managers where auth_user_id = auth.uid() for update;
  if not found then
    raise exception 'Vous ne participez pas à cette saison';
  end if;

  -- VERROU sur l'enchère : sérialise les surenchères concurrentes
  select * into v_auction from qm_auctions where id = p_auction_id for update;
  if not found then
    raise exception 'Enchère introuvable';
  end if;
  if v_auction.status <> 'open' then
    raise exception 'Enchère fermée';
  end if;
  if now() >= v_auction.ends_at then
    raise exception 'Enchère expirée';
  end if;
  if v_auction.top_bidder_id = v_manager.id then
    raise exception 'Vous êtes déjà le meilleur enchérisseur';
  end if;

  -- Contraintes de composition d'effectif (24 max, 3 GK, 3/club, 2 cracks/poste)
  -- Lève une exception explicite si l'ajout de ce joueur violerait une règle.
  perform qm_check_squad_rules(v_manager.id, v_auction.player_id);

  -- Montant minimal = prix actuel + incrément barème
  v_min_next := v_auction.current_price + qm_min_increment(v_auction.current_price);
  if p_amount < v_min_next then
    raise exception 'Offre trop basse. Minimum: % €', v_min_next;
  end if;

  -- Budget disponible = budget - déjà bloqué ailleurs
  v_available := v_manager.budget - v_manager.budget_locked;
  if p_amount > v_available then
    raise exception 'Budget insuffisant. Disponible: % €', v_available;
  end if;

  -- Libère les fonds de l'ancien meilleur enchérisseur (s'il existe)
  if v_auction.top_bidder_id is not null then
    update qm_managers
      set budget_locked = budget_locked - v_auction.current_price
      where id = v_auction.top_bidder_id;
  end if;

  -- Bloque les fonds du nouveau
  update qm_managers
    set budget_locked = budget_locked + p_amount
    where id = v_manager.id;

  -- Anti-snipe : offre dans les 10 dernières minutes → +10 min
  if v_auction.ends_at - now() < interval '10 minutes' then
    v_auction.ends_at := now() + interval '10 minutes';
  end if;

  update qm_auctions
    set current_price = p_amount,
        top_bidder_id = v_manager.id,
        ends_at       = v_auction.ends_at
    where id = p_auction_id
    returning * into v_auction;

  -- Historique
  insert into qm_bids (auction_id, manager_id, amount)
  values (p_auction_id, v_manager.id, p_amount);

  -- Popularité → alimente l'évolution de valeur (effet "bourse" interne)
  update qm_players set demand_score = demand_score + 1 where id = v_auction.player_id;

  return v_auction;
end;
$$;

-- ---------------------------------------------------------------------
-- Clôturer une enchère (appelée par le cron quand ends_at est dépassé)
-- ---------------------------------------------------------------------
create or replace function qm_close_auction(p_auction_id uuid)
returns qm_auctions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_auction  qm_auctions;
  v_player   qm_players;
begin
  select * into v_auction from qm_auctions where id = p_auction_id for update;
  if not found or v_auction.status <> 'open' then
    raise exception 'Enchère déjà traitée ou introuvable';
  end if;

  select * into v_player from qm_players where id = v_auction.player_id for update;

  if v_auction.top_bidder_id is null then
    -- Aucune offre : le joueur redevient libre
    update qm_players set status = 'free' where id = v_player.id;
    update qm_auctions set status = 'closed' where id = p_auction_id
      returning * into v_auction;
    return v_auction;
  end if;

  -- Transfert de propriété : le gagnant paie réellement
  update qm_managers
    set budget        = budget - v_auction.current_price,
        budget_locked = budget_locked - v_auction.current_price
    where id = v_auction.top_bidder_id;

  update qm_players
    set owner_id      = v_auction.top_bidder_id,
        status        = 'owned',
        current_value = v_auction.current_price   -- la dernière transaction devient la valeur de marché
    where id = v_player.id;

  insert into qm_transfers (player_id, from_manager, to_manager, price)
  values (v_player.id, v_player.owner_id, v_auction.top_bidder_id, v_auction.current_price);

  update qm_auctions set status = 'closed' where id = p_auction_id
    returning * into v_auction;

  return v_auction;
end;
$$;
