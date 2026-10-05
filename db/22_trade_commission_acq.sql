-- =====================================================================
-- ULTIMATE SQUAD — Commission d'échange sur prix d'acquisition (Chantier 2)
-- =====================================================================
-- La commission d'échange se base désormais sur le PRIX RÉEL qu'a payé
-- le cédant pour acquérir le joueur (son dernier transfert entrant),
-- au lieu de la valeur théorique du joueur.
--
-- Si le joueur n'a pas de prix d'acquisition connu (cas limite), on
-- retombe sur sa valeur actuelle. La répartition reste : le receveur
-- paie la commission, le cédant touche 2/3, la ligue garde 1/3.
--
-- À passer APRÈS 19_salary.sql (redéfinit qm_trade_accept et l'estimation).
-- =====================================================================

-- ---------- Prix d'acquisition d'un joueur par un manager -----------
-- Retourne le prix du dernier transfert où ce manager a ACQUIS ce joueur.
create or replace function qm_acquisition_price(p_manager_id uuid, p_player_id uuid)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select tr.price from qm_transfers tr
       where tr.player_id = p_player_id and tr.to_manager = p_manager_id
       order by tr.created_at desc limit 1),
    -- Fallback : valeur actuelle du joueur si aucun transfert trouvé
    (select current_value from qm_players where id = p_player_id),
    0
  );
$$;

-- ---------- Commission d'échange basée sur le prix d'acquisition ----
-- Applique les mêmes paliers que qm_base_commission, mais sur le prix
-- payé par le cédant, pas sur la valeur du joueur. La surtaxe "même
-- club" côté receveur reste appliquée.
create or replace function qm_trade_commission_acq(
  p_ceder uuid,      -- celui qui cède le joueur (dont on prend le prix d'achat)
  p_receiver uuid,   -- celui qui reçoit (pour la surtaxe même club)
  p_player_id uuid
)
returns bigint
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_acq_price bigint;
  v_base bigint;
  v_player qm_players;
  v_same_club integer := 0;
  v_multiplier numeric;
begin
  v_acq_price := qm_acquisition_price(p_ceder, p_player_id);
  v_base := qm_base_commission(v_acq_price);

  select * into v_player from qm_players where id = p_player_id;
  if v_player.club is not null then
    select count(*) into v_same_club from qm_players
      where owner_id = p_receiver and club = v_player.club;
  end if;
  v_multiplier := 1 + (v_same_club * 0.5);

  return round(v_base * v_multiplier)::bigint;
end;
$$;

-- ---------- qm_trade_accept : commission sur prix d'acquisition -----
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

  perform qm_check_squad_after_trade(v_trade.from_manager, v_trade.ask_players, v_trade.offer_players);
  perform qm_check_squad_after_trade(v_trade.to_manager,   v_trade.offer_players, v_trade.ask_players);

  perform qm_check_salary_after_trade(v_trade.from_manager, v_trade.ask_players, v_trade.offer_players);
  perform qm_check_salary_after_trade(v_trade.to_manager,   v_trade.offer_players, v_trade.ask_players);

  -- Commissions sur PRIX D'ACQUISITION du cédant
  -- offer_players : cédés par from, reçus par to -> to paie (sur prix payé par from), from touche 2/3
  if array_length(v_trade.offer_players,1) is not null then
    foreach v_pid in array v_trade.offer_players loop
      v_comm := qm_trade_commission_acq(v_trade.from_manager, v_trade.to_manager, v_pid);
      v_to_pays := v_to_pays + v_comm; v_from_gets := v_from_gets + (v_comm*2/3);
    end loop;
  end if;
  -- ask_players : cédés par to, reçus par from -> from paie (sur prix payé par to), to touche 2/3
  if array_length(v_trade.ask_players,1) is not null then
    foreach v_pid in array v_trade.ask_players loop
      v_comm := qm_trade_commission_acq(v_trade.to_manager, v_trade.from_manager, v_pid);
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

-- ---------- Estimation (front) : commission d'échange sur acquisition
create or replace function qm_estimate_trade_commissions(p_trade_id uuid)
returns table (from_pays bigint, to_pays bigint, from_gets bigint, to_gets bigint)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_trade qm_trades; v_pid uuid; v_comm bigint;
  fp bigint := 0; tp bigint := 0; fg bigint := 0; tg bigint := 0;
begin
  select * into v_trade from qm_trades where id = p_trade_id;
  if not found then return; end if;

  if array_length(v_trade.offer_players,1) is not null then
    foreach v_pid in array v_trade.offer_players loop
      v_comm := qm_trade_commission_acq(v_trade.from_manager, v_trade.to_manager, v_pid);
      tp := tp + v_comm; fg := fg + (v_comm*2/3);
    end loop;
  end if;
  if array_length(v_trade.ask_players,1) is not null then
    foreach v_pid in array v_trade.ask_players loop
      v_comm := qm_trade_commission_acq(v_trade.to_manager, v_trade.from_manager, v_pid);
      fp := fp + v_comm; tg := tg + (v_comm*2/3);
    end loop;
  end if;

  from_pays := fp; to_pays := tp; from_gets := fg; to_gets := tg;
  return next;
end;
$$;
