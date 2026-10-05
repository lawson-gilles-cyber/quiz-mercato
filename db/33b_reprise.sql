-- =====================================================================
-- ULTIMATE SQUAD — REPRISE du script 33 (après échec enum)
-- =====================================================================
-- À passer UNIQUEMENT après avoir exécuté SÉPARÉMENT les 3 lignes :
--   alter type qm_bonus_type add value if not exists 'same_pos';
--   alter type qm_bonus_type add value if not exists 'poker';
--   alter type qm_bonus_type add value if not exists 'convert';
-- ...et vérifié qu'elles apparaissent dans pg_enum (Success obtenu).
--
-- Ce fichier reprend TOUT le script 33 SAUF la création des enum
-- (déjà faite ci-dessus). Tu peux le passer d'un seul bloc.
-- Ensuite, passe le script 36 normalement.
-- =====================================================================

create unique index if not exists uq_qm_bonus_samepos
  on qm_bonuses(manager_id, ref_day) where bonus_type = 'same_pos';

-- ---------- 1. Budget de base 1 milliard ---------------------------
-- Change la valeur par défaut pour les futurs inscrits.
alter table qm_managers alter column budget set default 1000000000;

-- Réglages des nouveaux bonus dans season_state
alter table qm_season_state add column if not exists same_pos_bonus bigint not null default 15000000;
alter table qm_season_state add column if not exists poker_bonus bigint not null default 10000000;
alter table qm_season_state add column if not exists budget_to_points_rate bigint not null default 10000000; -- 10 M€ = 1 point

-- Fonction admin : (re)définir le budget d'un joueur déjà inscrit,
-- utile pour aligner les comptes existants sur le nouveau montant.
-- (qm_admin_set_budget existe déjà ; rien à faire côté fonction.)


-- ---------- 2. + 3. Bonus journée : même poste + full day ----------
-- On étend qm_check_full_day_bonus pour gérer AUSSI le bonus "même poste".
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
  v_same_pos_bonus bigint;
  v_pos text;
  v_count integer;
begin
  -- Postes DISTINCTS acquis aujourd'hui
  select array_agg(distinct p.position::text) into v_positions
  from qm_transfers tr
  join qm_players p on p.id = tr.player_id
  where tr.to_manager = p_manager_id
    and tr.created_at::date = v_today;

  -- Bonus "journée complète" : au moins un FWD, un MID et un DEF
  if v_positions @> array['FWD','MID','DEF'] then
    select full_day_bonus into v_bonus from qm_season_state where id = 1;
    begin
      insert into qm_bonuses (manager_id, bonus_type, amount, detail, ref_day)
      values (p_manager_id, 'full_day', v_bonus,
              'Journée complète : attaquant + milieu + défenseur achetés le même jour', v_today);
      update qm_managers set budget = budget + v_bonus where id = p_manager_id;
    exception when unique_violation then null;
    end;
  end if;

  -- Bonus "même poste" : 3 joueurs OU PLUS d'un même poste le même jour
  select p.position::text, count(*) into v_pos, v_count
  from qm_transfers tr
  join qm_players p on p.id = tr.player_id
  where tr.to_manager = p_manager_id
    and tr.created_at::date = v_today
  group by p.position::text
  having count(*) >= 3
  order by count(*) desc
  limit 1;

  if v_pos is not null then
    select same_pos_bonus into v_same_pos_bonus from qm_season_state where id = 1;
    begin
      insert into qm_bonuses (manager_id, bonus_type, amount, detail, ref_day)
      values (p_manager_id, 'same_pos', v_same_pos_bonus,
              'Trois joueurs au même poste (' || v_pos || ') achetés le même jour', v_today);
      update qm_managers set budget = budget + v_same_pos_bonus where id = p_manager_id;
    exception when unique_violation then null;
    end;
  end if;
end;
$$;


-- ---------- 3. Coup de poker : intégré à qm_close_auction ----------
-- On redéfinit qm_close_auction (reprend la version 31 + ajoute le
-- bonus coup de poker : gagnant unique = aucune autre offre que la sienne).
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
  v_distinct_bidders integer;
  v_poker bigint;
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

  -- Bonus dénicheur (conditions anti-abus, cf. script 31)
  if v_auction.scouted_by is not null and v_auction.scouted_by <> v_auction.top_bidder_id then
    select scout_min_bids, collusion_max_pairs into v_min_bids, v_pair_max from qm_season_state where id = 1;
    v_scout_bids := qm_scout_bid_count(p_auction_id, v_auction.scouted_by);
    v_pair_count := qm_scout_pair_count(v_auction.scouted_by, v_auction.top_bidder_id);
    if v_scout_bids >= v_min_bids and v_pair_count < v_pair_max then
      v_bonus := least(round(v_auction.current_price * 0.10)::bigint, 15000000);
      update qm_managers set budget = budget + v_bonus where id = v_auction.scouted_by;
      insert into qm_bonuses (manager_id, bonus_type, amount, detail, buyer_id)
      values (v_auction.scouted_by, 'other', v_bonus,
              'Bonus dénicheur (10%) : ' || v_player.name || ' remporté par un autre manager',
              v_auction.top_bidder_id);
    end if;
  end if;

  -- COUP DE POKER : le gagnant est-il le SEUL à avoir enchéri ?
  select count(distinct manager_id) into v_distinct_bidders
  from qm_bids where auction_id = p_auction_id;
  if v_distinct_bidders = 1 then
    select poker_bonus into v_poker from qm_season_state where id = 1;
    update qm_managers set budget = budget + v_poker where id = v_auction.top_bidder_id;
    insert into qm_bonuses (manager_id, bonus_type, amount, detail)
    values (v_auction.top_bidder_id, 'poker', v_poker,
            'Coup de poker : ' || v_player.name || ' remporté sans concurrence');
  end if;

  perform qm_check_full_day_bonus(v_auction.top_bidder_id);

  update qm_auctions set status = 'closed' where id = p_auction_id returning * into v_auction;
  return v_auction;
end;
$$;


-- ---------- 4. Conversion budget -> points (fin de mercato) --------
-- Le manager convertit une partie de son budget restant en points de
-- classement, au taux défini (défaut 10 M€ = 1 point). Sens UNIQUE
-- (pas de points -> budget, pour éviter l'inflation).
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

  -- Ne pas convertir du budget engagé sur des enchères en cours
  if p_amount > (v_manager.budget - v_manager.budget_locked) then
    raise exception 'Montant supérieur à ton budget disponible (hors enchères en cours).';
  end if;

  select budget_to_points_rate into v_rate from qm_season_state where id = 1;
  v_points := floor(p_amount / v_rate)::integer;
  if v_points < 1 then
    raise exception 'Il faut au moins % € pour convertir 1 point.', v_rate;
  end if;

  -- On ne débite que la part réellement convertie (multiple du taux)
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

-- ---------- Réglage admin des nouveaux bonus -----------------------
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
