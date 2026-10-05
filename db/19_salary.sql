-- =====================================================================
-- ULTIMATE SQUAD — Masse salariale (double budget)
-- =====================================================================
-- Chaque manager gère DEUX ressources :
--   1. Budget transfert (700 M€)  : sert à acheter (existant, inchangé).
--   2. Masse salariale (max 120 M€) : somme des salaires des joueurs
--      détenus. Chaque joueur a un salaire déduit de sa note QM.
--
-- À chaque achat, on vérifie que le salaire du joueur rentre dans le
-- plafond salarial. Sinon l'achat est refusé (« vends un joueur »).
-- Quand un joueur part (vente/échange), son salaire est libéré.
--
-- À passer APRÈS 17_bonuses.sql (redéfinit close_auction, place_bid,
-- trade_accept pour intégrer la masse salariale).
-- =====================================================================

-- Plafond salarial (réglable en admin)
alter table qm_season_state add column if not exists salary_cap bigint not null default 120000000;

-- ---------- Grille salaire selon la note QM -------------------------
-- Bronze <70 : 0,5M · Argent 70-75 : 1,5M · Or 75-82 : 4M
-- Élite 82-88 : 8M · Légende 88+ : 15M
create or replace function qm_player_salary(p_player qm_players)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select case
    when qm_rating(p_player) >= 88 then 15000000
    when qm_rating(p_player) >= 82 then  8000000
    when qm_rating(p_player) >= 75 then  4000000
    when qm_rating(p_player) >= 70 then  1500000
    else                                  500000
  end;
$$;

-- Version par id (pratique pour le front)
create or replace function qm_salary_of(p_player_id uuid)
returns bigint
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_p qm_players;
begin
  select * into v_p from qm_players where id = p_player_id;
  if not found then return 0; end if;
  return qm_player_salary(v_p);
end;
$$;

-- ---------- Masse salariale actuelle d'un manager -------------------
create or replace function qm_manager_salary_used(p_manager_id uuid)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(qm_player_salary(p.*)), 0)
  from qm_players p where p.owner_id = p_manager_id;
$$;

-- ---------- Contrôle : le joueur rentre-t-il dans le plafond ? ------
create or replace function qm_check_salary_cap(p_manager_id uuid, p_player_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_used bigint;
  v_cap  bigint;
  v_new  bigint;
begin
  v_used := qm_manager_salary_used(p_manager_id);
  select salary_cap into v_cap from qm_season_state where id = 1;
  v_new := qm_salary_of(p_player_id);
  if (v_used + v_new) > v_cap then
    raise exception 'Masse salariale dépassée : % + % > plafond % M€. Vends un joueur avant d''acheter.',
      round(v_used/1000000.0), round(v_new/1000000.0), round(v_cap/1000000.0);
  end if;
end;
$$;

-- ---------- Intégrer le contrôle salarial dans place_bid -----------
-- On vérifie la masse salariale AVANT d'accepter une offre (sinon un
-- manager gagne puis ne peut pas payer le salaire).
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

  -- PASS
  select bid_pass_limit into v_limit from qm_season_state where id = 1;
  v_used := qm_bids_used(p_auction_id, v_manager.id);
  if v_used >= v_limit then
    raise exception 'Plus de PASS disponible : déjà % offres sur ce joueur (limite %).', v_used, v_limit;
  end if;

  -- Règles d'effectif
  perform qm_check_squad_rules(v_manager.id, v_auction.player_id);

  -- NOUVEAU : contrôle de la masse salariale
  perform qm_check_salary_cap(v_manager.id, v_auction.player_id);

  -- Montant minimal
  v_min_next := v_auction.current_price + qm_min_increment(v_auction.current_price);
  if p_amount < v_min_next then
    raise exception 'Offre trop basse. Minimum: % €', v_min_next;
  end if;

  -- Budget transfert (offre + commission)
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

-- ---------- Tableau de bord manager (double budget) ----------------
create or replace function qm_my_dashboard()
returns table (
  budget_total bigint, budget_locked bigint, budget_available bigint,
  salary_used bigint, salary_cap bigint,
  squad_count integer, squad_max integer
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_m qm_managers; v_cap bigint;
begin
  select * into v_m from qm_managers where auth_user_id = auth.uid();
  if not found then return; end if;
  select salary_cap into v_cap from qm_season_state where id = 1;

  budget_total := v_m.budget;
  budget_locked := v_m.budget_locked;
  budget_available := v_m.budget - v_m.budget_locked;
  salary_used := qm_manager_salary_used(v_m.id);
  salary_cap := v_cap;
  squad_count := (select count(*) from qm_players where owner_id = v_m.id);
  squad_max := 24;
  return next;
end;
$$;

-- ---------- Réglage admin du plafond salarial ----------------------
create or replace function qm_admin_set_salary_cap(p_cap bigint)
returns qm_season_state
language plpgsql
security definer
set search_path = public
as $$
declare v_state qm_season_state;
begin
  if not qm_is_admin() then raise exception 'Réservé aux administrateurs'; end if;
  if p_cap < 0 then raise exception 'Le plafond ne peut pas être négatif'; end if;
  update qm_season_state set salary_cap = p_cap, updated_at = now()
    where id = 1 returning * into v_state;
  return v_state;
end;
$$;

-- ---------- Contrôle salarial aussi pour les échanges --------------
-- On étend qm_check_squad_after_trade pour vérifier la masse salariale
-- résultante du manager qui reçoit des joueurs.
create or replace function qm_check_salary_after_trade(
  p_manager uuid, p_incoming uuid[], p_outgoing uuid[]
)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_used bigint;
  v_cap bigint;
  v_in bigint := 0;
  v_out bigint := 0;
begin
  v_used := qm_manager_salary_used(p_manager);
  select salary_cap into v_cap from qm_season_state where id = 1;

  if array_length(p_incoming,1) is not null then
    select coalesce(sum(qm_salary_of(x)),0) into v_in from unnest(p_incoming) x;
  end if;
  if array_length(p_outgoing,1) is not null then
    select coalesce(sum(qm_salary_of(x)),0) into v_out from unnest(p_outgoing) x;
  end if;

  if (v_used - v_out + v_in) > v_cap then
    raise exception 'Échange refusé : masse salariale dépasserait le plafond (% M€).',
      round(v_cap/1000000.0);
  end if;
end;
$$;

-- =====================================================================
-- close_auction : intègre le contrôle salarial + bonus scout en 10%
-- =====================================================================
-- Nouveauté bonus scout : 10% du prix final (plafonné à 15M) au lieu
-- du 5M fixe, versé si un AUTRE manager remporte le joueur déniché.
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

  -- Bonus dénicheur : 10% du prix final, plafonné à 15 M€
  if v_auction.scouted_by is not null
     and v_auction.scouted_by <> v_auction.top_bidder_id then
    v_bonus := least(round(v_auction.current_price * 0.10)::bigint, 15000000);
    update qm_managers set budget = budget + v_bonus where id = v_auction.scouted_by;
    insert into qm_bonuses (manager_id, bonus_type, amount, detail)
    values (v_auction.scouted_by, 'other', v_bonus,
            'Bonus dénicheur (10%) : ' || v_player.name || ' remporté par un autre manager');
  end if;

  perform qm_check_full_day_bonus(v_auction.top_bidder_id);

  update qm_auctions set status = 'closed' where id = p_auction_id returning * into v_auction;
  return v_auction;
end;
$$;

-- =====================================================================
-- trade_accept : ajoute le contrôle de masse salariale des deux côtés
-- =====================================================================
create or replace function qm_trade_accept(p_trade_id uuid)
returns qm_trades
language plpgsql
security definer
set search_path = public
as $$
declare
  v_trade qm_trades; v_me qm_managers; v_from qm_managers;
  v_pid uuid; v_comm bigint;
  v_from_pays bigint := 0; v_to_pays bigint := 0;
  v_from_gets bigint := 0; v_to_gets bigint := 0;
begin
  select * into v_trade from qm_trades where id = p_trade_id for update;
  if not found then raise exception 'Proposition introuvable'; end if;
  if v_trade.status <> 'pending' then raise exception 'Proposition déjà traitée'; end if;

  select * into v_me from qm_managers where auth_user_id = auth.uid() for update;
  if v_me.id <> v_trade.to_manager then
    raise exception 'Seul le destinataire peut accepter cette proposition';
  end if;
  select * into v_from from qm_managers where id = v_trade.from_manager for update;

  perform qm_validate_trade_players(v_trade.from_manager, v_trade.offer_players);
  perform qm_validate_trade_players(v_trade.to_manager,   v_trade.ask_players);

  -- Règles d'effectif
  perform qm_check_squad_after_trade(v_trade.from_manager, v_trade.ask_players, v_trade.offer_players);
  perform qm_check_squad_after_trade(v_trade.to_manager,   v_trade.offer_players, v_trade.ask_players);

  -- NOUVEAU : contrôle masse salariale des deux côtés
  perform qm_check_salary_after_trade(v_trade.from_manager, v_trade.ask_players, v_trade.offer_players);
  perform qm_check_salary_after_trade(v_trade.to_manager,   v_trade.offer_players, v_trade.ask_players);

  -- Commissions (Lecture B)
  if array_length(v_trade.offer_players,1) is not null then
    foreach v_pid in array v_trade.offer_players loop
      v_comm := qm_purchase_commission(v_trade.to_manager, v_pid);
      v_to_pays := v_to_pays + v_comm; v_from_gets := v_from_gets + (v_comm*2/3);
    end loop;
  end if;
  if array_length(v_trade.ask_players,1) is not null then
    foreach v_pid in array v_trade.ask_players loop
      v_comm := qm_purchase_commission(v_trade.from_manager, v_pid);
      v_from_pays := v_from_pays + v_comm; v_to_gets := v_to_gets + (v_comm*2/3);
    end loop;
  end if;

  if (v_from.budget - v_from.budget_locked) < (greatest(v_trade.cash_from_to,0) + v_from_pays) then
    raise exception 'Budget insuffisant côté initiateur (cash + commissions).';
  end if;
  if (v_me.budget - v_me.budget_locked) < (greatest(-v_trade.cash_from_to,0) + v_to_pays) then
    raise exception 'Votre budget est insuffisant (cash + commissions).';
  end if;

  update qm_players set owner_id = v_trade.to_manager   where id = any(v_trade.offer_players);
  update qm_players set owner_id = v_trade.from_manager where id = any(v_trade.ask_players);

  if v_trade.cash_from_to <> 0 then
    update qm_managers set budget = budget - v_trade.cash_from_to where id = v_trade.from_manager;
    update qm_managers set budget = budget + v_trade.cash_from_to where id = v_trade.to_manager;
  end if;

  update qm_managers set budget = budget - v_from_pays + v_from_gets where id = v_trade.from_manager;
  update qm_managers set budget = budget - v_to_pays + v_to_gets where id = v_trade.to_manager;

  insert into qm_transfers (player_id, from_manager, to_manager, price)
    select unnest(v_trade.offer_players), v_trade.from_manager, v_trade.to_manager, 0;
  insert into qm_transfers (player_id, from_manager, to_manager, price)
    select unnest(v_trade.ask_players), v_trade.to_manager, v_trade.from_manager, 0;

  update qm_trades set status='accepted', resolved_at=now() where id=p_trade_id returning * into v_trade;
  return v_trade;
end;
$$;
