-- =====================================================================
-- ULTIMATE SQUAD — Refonte commissions & quotas de compartiment
-- =====================================================================
-- Changements décidés :
--  1. PLUS de commission d'achat aux enchères (seule la taxe de 3M reste).
--     La commission ne s'applique QUE sur les échanges entre managers.
--  2. Quotas par compartiment (MAXIMUM, effectif souple <= 24) :
--       3 gardiens, 8 défenseurs, 8 milieux, 5 attaquants.
--     Remplace la règle des "2 cracks par poste".
--  3. La surtaxe même club reste (elle vit déjà dans qm_purchase_commission,
--     utilisée uniquement par les échanges via qm_trade_commission_acq).
--
-- À passer APRÈS 22_trade_commission_acq.sql.
-- =====================================================================

-- ---------- Règles d'effectif : quotas par compartiment -------------
create or replace function qm_check_squad_rules(
  p_manager_id uuid, p_player_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player qm_players;
  v_total  integer;
  v_pos    integer;
  v_club   integer;
  v_champ  integer;
  v_max_pos integer;
  v_pos_label text;
begin
  select * into v_player from qm_players where id = p_player_id;
  if not found then raise exception 'Joueur introuvable'; end if;

  -- Effectif courant (possédés + gagnés en enchères ouvertes)
  with squad as (
    select pl.* from qm_players pl where pl.owner_id = p_manager_id
    union
    select pl.* from qm_auctions au join qm_players pl on pl.id = au.player_id
    where au.status='open' and au.top_bidder_id=p_manager_id and au.player_id<>p_player_id
  )
  select count(*) into v_total from squad;

  if v_total >= 24 then
    raise exception 'Effectif complet (24 joueurs). Vends un joueur avant d''enchérir.';
  end if;

  -- Quota par compartiment (MAXIMUM) : GK 3, DEF 8, MID 8, FWD 5
  v_max_pos := case v_player.position
    when 'GK' then 3 when 'DEF' then 8 when 'MID' then 8 when 'FWD' then 5 else 8 end;
  v_pos_label := case v_player.position
    when 'GK' then 'gardiens' when 'DEF' then 'défenseurs'
    when 'MID' then 'milieux' else 'attaquants' end;

  select count(*) into v_pos from (
    select pl.id from qm_players pl where pl.owner_id=p_manager_id and pl.position=v_player.position
    union
    select pl.id from qm_auctions au join qm_players pl on pl.id=au.player_id
    where au.status='open' and au.top_bidder_id=p_manager_id and au.player_id<>p_player_id and pl.position=v_player.position
  ) s;
  if v_pos >= v_max_pos then
    raise exception 'Maximum % % dans un effectif.', v_max_pos, v_pos_label;
  end if;

  -- Max 3 par club
  if v_player.club is not null then
    select count(*) into v_club from (
      select pl.id from qm_players pl where pl.owner_id=p_manager_id and pl.club=v_player.club
      union
      select pl.id from qm_auctions au join qm_players pl on pl.id=au.player_id
      where au.status='open' and au.top_bidder_id=p_manager_id and au.player_id<>p_player_id and pl.club=v_player.club
    ) c;
    if v_club >= 3 then
      raise exception 'Maximum 3 joueurs d''un même club (% en a déjà 3).', v_player.club;
    end if;
  end if;

  -- Max 6 par championnat
  if v_player.championship is not null then
    select count(*) into v_champ from (
      select pl.id from qm_players pl where pl.owner_id=p_manager_id and pl.championship=v_player.championship
      union
      select pl.id from qm_auctions au join qm_players pl on pl.id=au.player_id
      where au.status='open' and au.top_bidder_id=p_manager_id and au.player_id<>p_player_id and pl.championship=v_player.championship
    ) ch;
    if v_champ >= 6 then
      raise exception 'Maximum 6 joueurs du championnat % dans un effectif.', v_player.championship;
    end if;
  end if;
end;
$$;

-- ---------- Idem pour les échanges : quotas de compartiment ---------
create or replace function qm_check_squad_after_trade(
  p_manager uuid, p_incoming uuid[], p_outgoing uuid[]
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_total integer;
  r record;
  v_max integer;
begin
  drop table if exists _squad;
  create temp table _squad on commit drop as
    select p.* from qm_players p
    where p.owner_id = p_manager
      and (p_outgoing is null or not (p.id = any(p_outgoing)))
    union
    select p.* from qm_players p where p.id = any(coalesce(p_incoming,'{}'));

  select count(*) into v_total from _squad;
  if v_total > 24 then
    raise exception 'Échange refusé : effectif dépasserait 24 joueurs (%).', v_total;
  end if;

  -- Quotas par compartiment
  for r in select position, count(*) c from _squad group by position loop
    v_max := case r.position when 'GK' then 3 when 'DEF' then 8 when 'MID' then 8 when 'FWD' then 5 else 8 end;
    if r.c > v_max then
      raise exception 'Échange refusé : plus de % joueurs au poste %.', v_max, r.position;
    end if;
  end loop;

  -- Max 3 par club
  for r in select club, count(*) c from _squad where club is not null group by club loop
    if r.c > 3 then raise exception 'Échange refusé : plus de 3 joueurs du club %.', r.club; end if;
  end loop;

  -- Max 6 par championnat
  for r in select championship, count(*) c from _squad where championship is not null group by championship loop
    if r.c > 6 then raise exception 'Échange refusé : plus de 6 joueurs du championnat %.', r.championship; end if;
  end loop;
end;
$$;

-- ---------- place_bid SANS commission d'achat (taxe conservée) ------
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

  -- Taxe d'entrée (3M à la 1re offre si pas le dénicheur)
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

  -- Budget : offre + taxe (PLUS DE COMMISSION D'ACHAT)
  v_available := v_manager.budget - v_manager.budget_locked;
  if (p_amount + v_tax) > v_available then
    raise exception 'Budget insuffisant. Offre%s (% €) > disponible (% €).',
      case when v_owes_tax then ' + taxe d''entrée' else '' end, p_amount + v_tax, v_available;
  end if;

  if v_owes_tax then
    update qm_managers set budget = budget - v_tax where id = v_manager.id;
    insert into qm_entry_tax_paid (auction_id, manager_id) values (p_auction_id, v_manager.id);
  end if;

  -- Libère l'ancien enchérisseur (juste son offre, plus de commission)
  if v_auction.top_bidder_id is not null then
    update qm_managers set budget_locked = budget_locked - v_auction.current_price
      where id = v_auction.top_bidder_id;
  end if;

  update qm_managers set budget_locked = budget_locked + p_amount where id = v_manager.id;

  if v_auction.ends_at - now() < interval '10 minutes' then
    v_auction.ends_at := now() + interval '10 minutes';
  end if;

  update qm_auctions set current_price=p_amount, top_bidder_id=v_manager.id, ends_at=v_auction.ends_at
    where id = p_auction_id returning * into v_auction;

  insert into qm_bids (auction_id, manager_id, amount) values (p_auction_id, v_manager.id, p_amount);
  update qm_players set demand_score = demand_score + 1 where id = v_auction.player_id;

  return v_auction;
end;
$$;

-- ---------- close_auction SANS commission (taxe déjà prélevée) ------
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

  -- Le gagnant paie SEULEMENT le prix (plus de commission ; la taxe a
  -- déjà été prélevée à l'entrée)
  update qm_managers
    set budget        = budget - v_auction.current_price,
        budget_locked = budget_locked - v_auction.current_price
    where id = v_auction.top_bidder_id;

  update qm_players
    set owner_id = v_auction.top_bidder_id, status = 'owned', current_value = v_auction.current_price
    where id = v_player.id;

  insert into qm_transfers (player_id, from_manager, to_manager, price)
  values (v_player.id, v_player.owner_id, v_auction.top_bidder_id, v_auction.current_price);

  -- Bonus dénicheur : 10% du prix final, plafonné à 15M
  if v_auction.scouted_by is not null and v_auction.scouted_by <> v_auction.top_bidder_id then
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

-- ---------- L'estimation de commission d'achat renvoie 0 -----------
-- (le front peut continuer à l'appeler sans effet)
create or replace function qm_estimate_commission(p_manager_id uuid, p_player_id uuid)
returns bigint language sql stable security definer set search_path = public
as $$ select 0::bigint; $$;
