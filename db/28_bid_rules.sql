-- =====================================================================
-- ULTIMATE SQUAD — Règles d'enchères anti-triche (Bloc 1, Audrey)
-- =====================================================================
-- Remplace l'anti-snipe (prolongation 10 min) par un système plus
-- robuste. L'enchère dure 48h FIXE, jamais prolongée. Règles ajoutées :
--
--  1. COOLDOWN : 2h minimum entre deux offres d'un même manager sur un
--     même joueur (calculé côté serveur, infalsifiable).
--
--  2. PAS DE PREMIÈRE OFFRE TARDIVE : un manager ne peut pas faire sa
--     TOUTE PREMIÈRE offre sur un joueur dans les 6 dernières heures
--     (anti « faux réveil »).
--
--  3. PHASE FINALE VERROUILLÉE (2 dernières heures) :
--       - seuls les managers DÉJÀ actifs (ayant déjà offert) peuvent jouer ;
--       - le cooldown de 2h ne s'applique PAS (droit de riposte) ;
--       - mais chaque manager ne peut utiliser qu'UN SEUL PAS pendant
--         cette phase finale (évite les guerres infinies).
--
-- Ces réglages (2h, 6h, 2h de phase finale) sont dans season_state.
-- À passer APRÈS 23_commission_refonte.sql.
-- =====================================================================

alter table qm_season_state add column if not exists bid_cooldown_hours   integer not null default 2;
alter table qm_season_state add column if not exists no_first_bid_hours    integer not null default 6;
alter table qm_season_state add column if not exists final_phase_hours     integer not null default 2;

-- ---------- Combien de PASS ce manager a utilisés en phase finale ? --
create or replace function qm_bids_in_final_phase(p_auction_id uuid, p_manager_id uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::integer
  from qm_bids b
  join qm_auctions a on a.id = b.auction_id
  where b.auction_id = p_auction_id
    and b.manager_id = p_manager_id
    and b.created_at >= a.ends_at - (
      (select final_phase_hours from qm_season_state where id=1) || ' hours')::interval;
$$;

-- ---------- Dernière offre du manager sur ce joueur (pour cooldown) --
create or replace function qm_last_bid_at(p_auction_id uuid, p_manager_id uuid)
returns timestamptz
language sql
stable
security definer
set search_path = public
as $$
  select max(created_at) from qm_bids
  where auction_id = p_auction_id and manager_id = p_manager_id;
$$;

-- ---------- qm_place_bid : version anti-triche complète -------------
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

  select bid_cooldown_hours, no_first_bid_hours, final_phase_hours
    into v_cooldown, v_nofirst, v_finalh from qm_season_state where id = 1;

  -- Le manager a-t-il déjà offert sur ce joueur ?
  v_last := qm_last_bid_at(p_auction_id, v_manager.id);
  v_has_bid := v_last is not null;

  -- Sommes-nous dans la phase finale (2 dernières heures) ?
  v_in_final := now() >= v_auction.ends_at - (v_finalh || ' hours')::interval;

  -- RÈGLE 2 : pas de PREMIÈRE offre dans les 6 dernières heures
  if not v_has_bid and now() >= v_auction.ends_at - (v_nofirst || ' hours')::interval then
    raise exception 'Trop tard pour entrer : aucune première offre dans les % dernières heures.', v_nofirst;
  end if;

  if v_in_final then
    -- RÈGLE 3 : phase finale verrouillée
    if not v_has_bid then
      raise exception 'Phase finale : seuls les managers déjà engagés sur ce joueur peuvent enchérir.';
    end if;
    if qm_bids_in_final_phase(p_auction_id, v_manager.id) >= 1 then
      raise exception 'Phase finale : vous avez déjà utilisé votre offre unique des % dernières heures.', v_finalh;
    end if;
    -- (pas de cooldown en phase finale : droit de riposte)
  else
    -- RÈGLE 1 : cooldown de 2h hors phase finale
    if v_has_bid and now() < v_last + (v_cooldown || ' hours')::interval then
      raise exception 'Délai de % h entre deux offres non écoulé. Prochaine offre possible à %.',
        v_cooldown, to_char(v_last + (v_cooldown || ' hours')::interval, 'HH24:MI');
    end if;
  end if;

  -- Achats/jour
  select max_daily_purchases into v_daily_max from qm_season_state where id = 1;
  v_daily := qm_daily_purchases(v_manager.id);
  if v_daily >= v_daily_max then
    raise exception 'Limite de % achats par jour atteinte. Reviens demain pour enchérir.', v_daily_max;
  end if;

  -- PASS (global sur l'enchère)
  select bid_pass_limit into v_limit from qm_season_state where id = 1;
  v_used := qm_bids_used(p_auction_id, v_manager.id);
  if v_used >= v_limit then
    raise exception 'Plus de PASS disponible : déjà % offres sur ce joueur (limite %).', v_used, v_limit;
  end if;

  -- Effectif + masse salariale
  perform qm_check_squad_rules(v_manager.id, v_auction.player_id);
  perform qm_check_salary_cap(v_manager.id, v_auction.player_id);

  -- Taxe d'entrée
  if v_auction.scouted_by is distinct from v_manager.id then
    if not exists (select 1 from qm_entry_tax_paid where auction_id=p_auction_id and manager_id=v_manager.id) then
      select entry_tax into v_tax from qm_season_state where id = 1;
      v_owes_tax := true;
    end if;
  end if;

  -- Montant minimal
  v_min_next := v_auction.current_price + qm_min_increment(v_auction.current_price);
  if p_amount < v_min_next then
    raise exception 'Offre trop basse. Minimum: % €', v_min_next;
  end if;

  -- Budget (offre + taxe ; pas de commission aux enchères)
  v_available := v_manager.budget - v_manager.budget_locked;
  if (p_amount + v_tax) > v_available then
    raise exception 'Budget insuffisant. Offre%s (% €) > disponible (% €).',
      case when v_owes_tax then ' + taxe d''entrée' else '' end, p_amount + v_tax, v_available;
  end if;

  if v_owes_tax then
    update qm_managers set budget = budget - v_tax where id = v_manager.id;
    insert into qm_entry_tax_paid (auction_id, manager_id) values (p_auction_id, v_manager.id);
  end if;

  -- Libère l'ancien meilleur enchérisseur
  if v_auction.top_bidder_id is not null then
    update qm_managers set budget_locked = budget_locked - v_auction.current_price
      where id = v_auction.top_bidder_id;
  end if;

  update qm_managers set budget_locked = budget_locked + p_amount where id = v_manager.id;

  -- 48h FIXE : plus d'anti-snipe, ends_at n'est jamais modifié
  update qm_auctions set current_price = p_amount, top_bidder_id = v_manager.id
    where id = p_auction_id returning * into v_auction;

  insert into qm_bids (auction_id, manager_id, amount) values (p_auction_id, v_manager.id, p_amount);
  update qm_players set demand_score = demand_score + 1 where id = v_auction.player_id;

  return v_auction;
end;
$$;

-- ---------- Réglage admin des fenêtres d'enchère -------------------
create or replace function qm_admin_set_bid_windows(
  p_cooldown integer, p_no_first integer, p_final integer
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
    bid_cooldown_hours = greatest(p_cooldown, 0),
    no_first_bid_hours = greatest(p_no_first, 0),
    final_phase_hours = greatest(p_final, 0),
    updated_at = now()
  where id = 1 returning * into v_state;
  return v_state;
end;
$$;
