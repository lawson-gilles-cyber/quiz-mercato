-- =====================================================================
-- ULTIMATE SQUAD — Taxe d'entrée sur enchère (Chantier 1)
-- =====================================================================
-- Pour entrer sur une enchère qu'on n'a PAS dénichée, un manager paie
-- une taxe fixe (3 M€) UNE SEULE FOIS, à sa première offre sur ce joueur.
-- Le dénicheur (scout) de l'enchère est exempté sur son propre joueur.
--
-- La taxe sort du système (comme les commissions d'achat = anti-inflation).
-- Réglable en admin. À passer APRÈS 20_mercato_rules.sql.
-- =====================================================================

alter table qm_season_state add column if not exists entry_tax bigint not null default 3000000;

-- Table pour tracer qui a déjà payé la taxe sur quelle enchère
-- (évite de la prélever à chaque offre : une fois par manager/enchère).
create table if not exists qm_entry_tax_paid (
  auction_id uuid not null references qm_auctions(id) on delete cascade,
  manager_id uuid not null references qm_managers(id) on delete cascade,
  paid_at    timestamptz not null default now(),
  primary key (auction_id, manager_id)
);

alter table qm_entry_tax_paid enable row level security;
create policy "qm read own entry tax" on qm_entry_tax_paid for select using (
  manager_id in (select id from qm_managers where auth_user_id = auth.uid()) or qm_is_admin()
);

-- ---------- qm_place_bid : ajoute la taxe d'entrée -----------------
-- Version complète : marché, achats/jour, PASS, effectif, salaire,
-- budget+commission, ET taxe d'entrée (3M à la 1re offre, scout exempté).
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
  v_tax       bigint := 0;
  v_owes_tax  boolean := false;
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

  -- Achats/jour
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

  -- Effectif + masse salariale
  perform qm_check_squad_rules(v_manager.id, v_auction.player_id);
  perform qm_check_salary_cap(v_manager.id, v_auction.player_id);

  -- ----- Taxe d'entrée : 3M à la 1re offre si pas le dénicheur -----
  if v_auction.scouted_by is distinct from v_manager.id then
    -- pas encore payée ?
    if not exists (select 1 from qm_entry_tax_paid
                   where auction_id = p_auction_id and manager_id = v_manager.id) then
      select entry_tax into v_tax from qm_season_state where id = 1;
      v_owes_tax := true;
    end if;
  end if;

  -- Montant minimal
  v_min_next := v_auction.current_price + qm_min_increment(v_auction.current_price);
  if p_amount < v_min_next then
    raise exception 'Offre trop basse. Minimum: % €', v_min_next;
  end if;

  -- Budget : offre + commission + taxe éventuelle
  v_commission := qm_purchase_commission(v_manager.id, v_auction.player_id);
  v_available := v_manager.budget - v_manager.budget_locked;
  if (p_amount + v_commission + v_tax) > v_available then
    raise exception 'Budget insuffisant. Offre + commission% (% €) > disponible (% €).',
      case when v_owes_tax then ' + taxe d''entrée' else '' end,
      p_amount + v_commission + v_tax, v_available;
  end if;

  -- Prélève la taxe d'entrée immédiatement (elle sort du système)
  if v_owes_tax then
    update qm_managers set budget = budget - v_tax where id = v_manager.id;
    insert into qm_entry_tax_paid (auction_id, manager_id) values (p_auction_id, v_manager.id);
  end if;

  -- Libère l'ancien enchérisseur
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

-- ---------- Le front : le manager doit-il une taxe sur cette enchère ?
create or replace function qm_my_entry_tax(p_auction_id uuid)
returns bigint
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_manager_id uuid;
  v_scout uuid;
  v_tax bigint;
begin
  select id into v_manager_id from qm_managers where auth_user_id = auth.uid();
  if v_manager_id is null then return 0; end if;

  select scouted_by into v_scout from qm_auctions where id = p_auction_id;
  -- Dénicheur exempté
  if v_scout is not distinct from v_manager_id then return 0; end if;
  -- Déjà payée ?
  if exists (select 1 from qm_entry_tax_paid
             where auction_id = p_auction_id and manager_id = v_manager_id) then
    return 0;
  end if;
  select entry_tax into v_tax from qm_season_state where id = 1;
  return v_tax;
end;
$$;

-- ---------- Réglage admin de la taxe -------------------------------
create or replace function qm_admin_set_entry_tax(p_tax bigint)
returns qm_season_state
language plpgsql
security definer
set search_path = public
as $$
declare v_state qm_season_state;
begin
  if not qm_is_admin() then raise exception 'Réservé aux administrateurs'; end if;
  if p_tax < 0 then raise exception 'La taxe ne peut pas être négative'; end if;
  update qm_season_state set entry_tax = p_tax, updated_at = now()
    where id = 1 returning * into v_state;
  return v_state;
end;
$$;
