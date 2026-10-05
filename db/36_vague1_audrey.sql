-- =====================================================================
-- ULTIMATE SQUAD — Vague 1 : alignement sur les règles finales d'Audrey
-- =====================================================================
-- 1. Effectif 21 (au lieu de 24) ; quotas 2 GK / 7 DEF / 7 MID / 5 FWD.
-- 2. Bonus journée : 3 postes différents = 10 M€ ; 3 même poste = 5 M€.
-- 3. Coup de poker enrichi : seul enchérisseur +10 M€ ; 5+ managers +10 M€ ;
--    prix final > 100 M€ +5 M€ (cumulables).
-- 4. Conversion budget->points plafonnée à 200 M€ (fin mercato d'été).
--
-- À passer APRÈS 33_paquet_a.sql. Redéfinit les fonctions concernées.
-- =====================================================================

-- ---------- 1. Nouveaux montants de bonus (réglages) ---------------
update qm_season_state set
  full_day_bonus = 10000000,   -- 3 postes différents : 10 M€ (était 15)
  same_pos_bonus = 5000000     -- 3 même poste : 5 M€ (était 15)
  where id = 1;

-- Plafond de conversion + réglages coup de poker enrichi
alter table qm_season_state add column if not exists convert_cap bigint not null default 200000000;      -- 200 M€ max convertibles
alter table qm_season_state add column if not exists poker_crowd_bonus bigint not null default 10000000;  -- 5+ managers
alter table qm_season_state add column if not exists poker_bigprice_bonus bigint not null default 5000000; -- prix > 100 M€
alter table qm_season_state add column if not exists poker_bigprice_threshold bigint not null default 100000000;
-- Cumul déjà converti par manager (pour appliquer le plafond)
alter table qm_managers add column if not exists converted_total bigint not null default 0;


-- ---------- 2. Quotas 21 : qm_check_squad_rules --------------------
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

  with squad as (
    select pl.* from qm_players pl where pl.owner_id = p_manager_id
    union
    select pl.* from qm_auctions au join qm_players pl on pl.id = au.player_id
    where au.status='open' and au.top_bidder_id=p_manager_id and au.player_id<>p_player_id
  )
  select count(*) into v_total from squad;

  if v_total >= 21 then
    raise exception 'Effectif complet (21 joueurs). Vends un joueur avant d''enchérir.';
  end if;

  -- Quota par compartiment : GK 2, DEF 7, MID 7, FWD 5
  v_max_pos := case v_player.position
    when 'GK' then 2 when 'DEF' then 7 when 'MID' then 7 when 'FWD' then 5 else 7 end;
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


-- ---------- 3. Quotas 21 pour les échanges -------------------------
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
  if v_total > 21 then
    raise exception 'Échange refusé : effectif dépasserait 21 joueurs (%).', v_total;
  end if;

  for r in select position, count(*) c from _squad group by position loop
    v_max := case r.position when 'GK' then 2 when 'DEF' then 7 when 'MID' then 7 when 'FWD' then 5 else 7 end;
    if r.c > v_max then
      raise exception 'Échange refusé : plus de % joueurs au poste %.', v_max, r.position;
    end if;
  end loop;

  for r in select club, count(*) c from _squad where club is not null group by club loop
    if r.c > 3 then raise exception 'Échange refusé : plus de 3 joueurs du club %.', r.club; end if;
  end loop;

  for r in select championship, count(*) c from _squad where championship is not null group by championship loop
    if r.c > 6 then raise exception 'Échange refusé : plus de 6 joueurs du championnat %.', r.championship; end if;
  end loop;
end;
$$;


-- ---------- 4. Coup de poker enrichi (dans qm_close_auction) -------
-- Redéfinit qm_close_auction (version 33) en ajoutant les 3 variantes.
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
  v_poker bigint := 0;
  v_poker_solo bigint;
  v_poker_crowd bigint;
  v_poker_big bigint;
  v_poker_threshold bigint;
  v_poker_detail text := '';
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

  -- Bonus dénicheur (conditions anti-abus)
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

  -- COUP DE POKER enrichi (3 variantes cumulables)
  select count(distinct manager_id) into v_distinct_bidders
  from qm_bids where auction_id = p_auction_id;

  select poker_bonus, poker_crowd_bonus, poker_bigprice_bonus, poker_bigprice_threshold
    into v_poker_solo, v_poker_crowd, v_poker_big, v_poker_threshold
    from qm_season_state where id = 1;

  -- a) seul enchérisseur
  if v_distinct_bidders = 1 then
    v_poker := v_poker + v_poker_solo;
    v_poker_detail := 'seul enchérisseur';
  end if;
  -- b) 5 managers ou plus
  if v_distinct_bidders >= 5 then
    v_poker := v_poker + v_poker_crowd;
    v_poker_detail := v_poker_detail || case when v_poker_detail<>'' then ' + ' else '' end || '5+ managers';
  end if;
  -- c) prix final > seuil (100 M€)
  if v_auction.current_price > v_poker_threshold then
    v_poker := v_poker + v_poker_big;
    v_poker_detail := v_poker_detail || case when v_poker_detail<>'' then ' + ' else '' end || 'prix > ' || (v_poker_threshold/1000000)::text || ' M€';
  end if;

  if v_poker > 0 then
    update qm_managers set budget = budget + v_poker where id = v_auction.top_bidder_id;
    insert into qm_bonuses (manager_id, bonus_type, amount, detail)
    values (v_auction.top_bidder_id, 'poker', v_poker,
            'Coup de poker (' || v_poker_detail || ') : ' || v_player.name);
  end if;

  perform qm_check_full_day_bonus(v_auction.top_bidder_id);

  update qm_auctions set status = 'closed' where id = p_auction_id returning * into v_auction;
  return v_auction;
end;
$$;


-- ---------- 5. Conversion plafonnée à 200 M€ -----------------------
create or replace function qm_convert_budget_to_points(p_amount bigint)
returns qm_managers
language plpgsql
security definer
set search_path = public
as $$
declare
  v_manager qm_managers;
  v_rate bigint;
  v_cap bigint;
  v_points integer;
  v_spend bigint;
begin
  select * into v_manager from qm_managers where auth_user_id = auth.uid() for update;
  if not found then raise exception 'Vous ne participez pas à cette saison'; end if;
  if p_amount <= 0 then raise exception 'Montant invalide'; end if;

  if p_amount > (v_manager.budget - v_manager.budget_locked) then
    raise exception 'Montant supérieur à ton budget disponible (hors enchères en cours).';
  end if;

  select budget_to_points_rate, convert_cap into v_rate, v_cap from qm_season_state where id = 1;

  -- Plafond cumulé : on ne peut pas convertir plus que le cap au total
  if v_manager.converted_total + p_amount > v_cap then
    raise exception 'Plafond de conversion atteint : maximum % M€ convertibles au total (déjà converti : % M€).',
      (v_cap/1000000), (v_manager.converted_total/1000000);
  end if;

  v_points := floor(p_amount / v_rate)::integer;
  if v_points < 1 then
    raise exception 'Il faut au moins % € pour convertir 1 point.', v_rate;
  end if;
  v_spend := v_points::bigint * v_rate;

  update qm_managers
    set budget = budget - v_spend,
        season_points = season_points + v_points,
        converted_total = converted_total + v_spend
    where id = v_manager.id returning * into v_manager;

  insert into qm_bonuses (manager_id, bonus_type, amount, detail)
  values (v_manager.id, 'convert', v_spend,
          'Conversion budget -> ' || v_points || ' point(s) de classement');

  return v_manager;
end;
$$;

revoke execute on function qm_convert_budget_to_points(bigint) from anon;
