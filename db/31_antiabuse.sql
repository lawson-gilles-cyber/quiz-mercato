-- =====================================================================
-- ULTIMATE SQUAD — Anti-abus des enchères (3 mesures)
-- =====================================================================
-- 1. CONDITION BONUS DÉNICHEUR : le dénicheur ne touche son bonus que
--    s'il a placé AU MOINS 2 offres sur son propre joueur proposé.
--    Empêche de proposer une star qu'on ne veut pas juste pour le bonus.
--
-- 2. LIMITE "MÈNE" : un manager ne peut mener simultanément que N
--    enchères (défaut 6). Une enchère où il n'est plus le meilleur
--    enchérisseur ne compte plus dans sa limite -> il peut entrer
--    ailleurs. Empêche de geler des places en perdant volontairement.
--
-- 3. ANTI-COLLUSION : un dénicheur ne peut toucher le bonus grâce au
--    même acheteur que 2 fois maximum (période glissante 30 jours).
--    Empêche A propose / B achète / A propose / B achète en boucle.
--
-- À passer APRÈS 28_bid_rules.sql (redéfinit qm_place_bid, qm_close_auction).
-- =====================================================================

alter table qm_season_state add column if not exists max_leading_auctions integer not null default 6;
alter table qm_season_state add column if not exists scout_min_bids integer not null default 2;
alter table qm_season_state add column if not exists collusion_max_pairs integer not null default 2;

-- Colonne pour tracer l'acheteur qui a déclenché le bonus dénicheur
-- (créée AVANT les fonctions qui l'utilisent).
alter table qm_bonuses add column if not exists buyer_id uuid references qm_managers(id) on delete set null;

-- ---------- Combien d'enchères ce manager MÈNE actuellement ? -------
create or replace function qm_leading_auctions_count(p_manager_id uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::integer from qm_auctions
  where status = 'open' and top_bidder_id = p_manager_id;
$$;

-- ---------- Combien d'offres le manager a-t-il faites sur ce joueur ?
-- (réutilise qm_bids_used, mais on l'expose clairement pour la règle)
create or replace function qm_scout_bid_count(p_auction_id uuid, p_manager_id uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::integer from qm_bids
  where auction_id = p_auction_id and manager_id = p_manager_id;
$$;

-- ---------- Bonus dénicheur déjà générés entre ce couple (dénicheur, acheteur)
create or replace function qm_scout_pair_count(p_scout uuid, p_buyer uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::integer
  from qm_bonuses b
  where b.manager_id = p_scout
    and b.bonus_type = 'other'
    and b.detail like '%dénicheur%'
    and b.buyer_id = p_buyer
    and b.created_at >= now() - interval '30 days';
$$;

-- On ajoute une colonne pour tracer l'acheteur qui a déclenché le bonus
-- (déjà créée en tête de script)

-- ---------- qm_place_bid : + limite d'enchères menées ---------------
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
  v_limit     integer;
  v_used      integer;
  v_daily     integer;
  v_daily_max integer;
  v_tax       bigint := 0;
  v_owes_tax  boolean := false;
  v_cooldown  integer;
  v_nofirst   integer;
  v_finalh    integer;
  v_last      timestamptz;
  v_has_bid   boolean;
  v_in_final  boolean;
  v_lead_max  integer;
  v_leading   integer;
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

  -- LIMITE "MÈNE" : ne pas mener plus de N enchères à la fois.
  -- (une enchère où on a été dépassé ne compte plus, donc on peut la
  -- récupérer en re-enchérissant si on n'est pas au plafond)
  select max_leading_auctions into v_lead_max from qm_season_state where id = 1;
  v_leading := qm_leading_auctions_count(v_manager.id);
  if v_leading >= v_lead_max then
    raise exception 'Tu mènes déjà % enchères (maximum). Attends d''en remporter ou d''être dépassé sur l''une d''elles.', v_lead_max;
  end if;

  select bid_cooldown_hours, no_first_bid_hours, final_phase_hours
    into v_cooldown, v_nofirst, v_finalh from qm_season_state where id = 1;

  v_last := qm_last_bid_at(p_auction_id, v_manager.id);
  v_has_bid := v_last is not null;
  v_in_final := now() >= v_auction.ends_at - (v_finalh || ' hours')::interval;

  if not v_has_bid and now() >= v_auction.ends_at - (v_nofirst || ' hours')::interval then
    raise exception 'Trop tard pour entrer : aucune première offre dans les % dernières heures.', v_nofirst;
  end if;

  if v_in_final then
    if not v_has_bid then
      raise exception 'Phase finale : seuls les managers déjà engagés sur ce joueur peuvent enchérir.';
    end if;
    if qm_bids_in_final_phase(p_auction_id, v_manager.id) >= 1 then
      raise exception 'Phase finale : vous avez déjà utilisé votre offre unique des % dernières heures.', v_finalh;
    end if;
  else
    if v_has_bid and now() < v_last + (v_cooldown || ' hours')::interval then
      raise exception 'Délai de % h entre deux offres non écoulé. Prochaine offre possible à %.',
        v_cooldown, to_char(v_last + (v_cooldown || ' hours')::interval, 'HH24:MI');
    end if;
  end if;

  select max_daily_purchases into v_daily_max from qm_season_state where id = 1;
  v_daily := qm_daily_purchases(v_manager.id);
  if v_daily >= v_daily_max then
    raise exception 'Limite de % achats par jour atteinte. Reviens demain pour enchérir.', v_daily_max;
  end if;

  select bid_pass_limit into v_limit from qm_season_state where id = 1;
  v_used := qm_bids_used(p_auction_id, v_manager.id);
  if v_used >= v_limit then
    raise exception 'Plus de PASS disponible : déjà % offres sur ce joueur (limite %).', v_used, v_limit;
  end if;

  perform qm_check_squad_rules(v_manager.id, v_auction.player_id);
  perform qm_check_salary_cap(v_manager.id, v_auction.player_id);

  if v_auction.scouted_by is distinct from v_manager.id then
    if not exists (select 1 from qm_entry_tax_paid where auction_id=p_auction_id and manager_id=v_manager.id) then
      select entry_tax into v_tax from qm_season_state where id = 1;
      v_owes_tax := true;
    end if;
  end if;

  v_min_next := v_auction.current_price + qm_min_increment(v_auction.current_price);
  if p_amount < v_min_next then
    raise exception 'Offre trop basse. Minimum: % €', v_min_next;
  end if;

  v_available := v_manager.budget - v_manager.budget_locked;
  if (p_amount + v_tax) > v_available then
    raise exception 'Budget insuffisant. Offre%s (% €) > disponible (% €).',
      case when v_owes_tax then ' + taxe d''entrée' else '' end, p_amount + v_tax, v_available;
  end if;

  if v_owes_tax then
    update qm_managers set budget = budget - v_tax where id = v_manager.id;
    insert into qm_entry_tax_paid (auction_id, manager_id) values (p_auction_id, v_manager.id);
  end if;

  if v_auction.top_bidder_id is not null then
    update qm_managers set budget_locked = budget_locked - v_auction.current_price
      where id = v_auction.top_bidder_id;
  end if;

  update qm_managers set budget_locked = budget_locked + p_amount where id = v_manager.id;

  update qm_auctions set current_price = p_amount, top_bidder_id = v_manager.id
    where id = p_auction_id returning * into v_auction;

  insert into qm_bids (auction_id, manager_id, amount) values (p_auction_id, v_manager.id, p_amount);
  update qm_players set demand_score = demand_score + 1 where id = v_auction.player_id;

  return v_auction;
end;
$$;

-- ---------- qm_close_auction : conditions bonus dénicheur ----------
create or replace function qm_close_auction(p_auction_id uuid)
returns qm_auctions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_auction qm_auctions;
  v_player  qm_players;
  v_bonus   bigint;
  v_scout_bids integer;
  v_min_bids integer;
  v_pair_count integer;
  v_pair_max integer;
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

  update qm_managers
    set budget        = budget - v_auction.current_price,
        budget_locked = budget_locked - v_auction.current_price
    where id = v_auction.top_bidder_id;

  update qm_players
    set owner_id = v_auction.top_bidder_id, status = 'owned', current_value = v_auction.current_price
    where id = v_player.id;

  insert into qm_transfers (player_id, from_manager, to_manager, price)
  values (v_player.id, v_player.owner_id, v_auction.top_bidder_id, v_auction.current_price);

  -- Bonus dénicheur, SOUS CONDITIONS :
  if v_auction.scouted_by is not null and v_auction.scouted_by <> v_auction.top_bidder_id then
    select scout_min_bids, collusion_max_pairs into v_min_bids, v_pair_max from qm_season_state where id = 1;

    -- Condition 1 : le dénicheur a placé au moins N offres sur SON joueur
    v_scout_bids := qm_scout_bid_count(p_auction_id, v_auction.scouted_by);

    -- Condition 2 (anti-collusion) : pas plus de N bonus avec ce même acheteur
    v_pair_count := qm_scout_pair_count(v_auction.scouted_by, v_auction.top_bidder_id);

    if v_scout_bids >= v_min_bids and v_pair_count < v_pair_max then
      v_bonus := least(round(v_auction.current_price * 0.10)::bigint, 15000000);
      update qm_managers set budget = budget + v_bonus where id = v_auction.scouted_by;
      insert into qm_bonuses (manager_id, bonus_type, amount, detail, buyer_id)
      values (v_auction.scouted_by, 'other', v_bonus,
              'Bonus dénicheur (10%) : ' || v_player.name || ' remporté par un autre manager',
              v_auction.top_bidder_id);
    end if;
    -- Sinon : pas de bonus (spéculation ou collusion détectée) — silencieux
  end if;

  perform qm_check_full_day_bonus(v_auction.top_bidder_id);

  update qm_auctions set status = 'closed' where id = p_auction_id returning * into v_auction;
  return v_auction;
end;
$$;

-- ---------- Réglage admin des seuils anti-abus ---------------------
create or replace function qm_admin_set_antiabuse(
  p_max_leading integer, p_scout_min_bids integer, p_collusion_max integer
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
    max_leading_auctions = greatest(p_max_leading, 1),
    scout_min_bids = greatest(p_scout_min_bids, 0),
    collusion_max_pairs = greatest(p_collusion_max, 1),
    updated_at = now()
  where id = 1 returning * into v_state;
  return v_state;
end;
$$;

revoke execute on function qm_admin_set_antiabuse(integer, integer, integer) from anon;
