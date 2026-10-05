-- =====================================================================
-- QUIZ MERCATO — Commissions sur les échanges (Lecture B, Audrey)
-- =====================================================================
-- Sur un échange, CHAQUE joueur qui change de main génère une commission,
-- basée sur sa valeur (mêmes paliers que les achats) + surtaxe "même club"
-- côté receveur. Répartition (Lecture B) :
--   * le RECEVEUR (acheteur du joueur) paie la commission entière
--   * le CÉDANT (vendeur) reçoit 2/3
--   * la ligue garde 1/3 (s'évapore : anti-inflation)
--
-- Redéfinit qm_trade_accept pour intégrer ce calcul. À passer APRÈS
-- 11_trades.sql et 12_commissions.sql.
-- =====================================================================

-- Commission d'un joueur reçu par un manager (base palier + surtaxe club).
-- Réutilise qm_purchase_commission : elle compte déjà les joueurs du même
-- club que le receveur possède AU MOMENT de l'appel.
create or replace function qm_trade_commission_for(
  p_receiver uuid,
  p_player_id uuid
)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select qm_purchase_commission(p_receiver, p_player_id);
$$;

-- ---------- qm_trade_accept avec commissions ------------------------
create or replace function qm_trade_accept(p_trade_id uuid)
returns qm_trades
language plpgsql
security definer
set search_path = public
as $$
declare
  v_trade qm_trades;
  v_me    qm_managers;
  v_from  qm_managers;
  v_pid   uuid;
  v_comm  bigint;
  -- Totaux de commission par manager (ce qu'il PAIE en tant que receveur)
  v_from_pays bigint := 0;   -- from reçoit les ask_players
  v_to_pays   bigint := 0;   -- to reçoit les offer_players
  -- Totaux reçus par manager (2/3 en tant que cédant)
  v_from_gets bigint := 0;   -- from cède les offer_players
  v_to_gets   bigint := 0;   -- to cède les ask_players
begin
  select * into v_trade from qm_trades where id = p_trade_id for update;
  if not found then raise exception 'Proposition introuvable'; end if;
  if v_trade.status <> 'pending' then raise exception 'Proposition déjà traitée'; end if;

  select * into v_me from qm_managers where auth_user_id = auth.uid() for update;
  if v_me.id <> v_trade.to_manager then
    raise exception 'Seul le destinataire peut accepter cette proposition';
  end if;
  select * into v_from from qm_managers where id = v_trade.from_manager for update;

  -- Re-validation
  perform qm_validate_trade_players(v_trade.from_manager, v_trade.offer_players);
  perform qm_validate_trade_players(v_trade.to_manager,   v_trade.ask_players);

  -- Règles d'effectif des deux côtés
  perform qm_check_squad_after_trade(v_trade.from_manager, v_trade.ask_players, v_trade.offer_players);
  perform qm_check_squad_after_trade(v_trade.to_manager,   v_trade.offer_players, v_trade.ask_players);

  -- ----- Calcul des commissions (AVANT transfert, pour compter les clubs correctement) -----
  -- offer_players : cédés par from, reçus par to  -> to paie, from touche 2/3
  if array_length(v_trade.offer_players,1) is not null then
    foreach v_pid in array v_trade.offer_players loop
      v_comm := qm_trade_commission_for(v_trade.to_manager, v_pid);
      v_to_pays := v_to_pays + v_comm;
      v_from_gets := v_from_gets + (v_comm * 2 / 3);
    end loop;
  end if;
  -- ask_players : cédés par to, reçus par from  -> from paie, to touche 2/3
  if array_length(v_trade.ask_players,1) is not null then
    foreach v_pid in array v_trade.ask_players loop
      v_comm := qm_trade_commission_for(v_trade.from_manager, v_pid);
      v_from_pays := v_from_pays + v_comm;
      v_to_gets := v_to_gets + (v_comm * 2 / 3);
    end loop;
  end if;

  -- ----- Vérification des budgets (cash + commissions payées) -----
  -- from : dépense cash_from_to (si >0) + v_from_pays (commissions), gagne v_from_gets + (cash si <0)
  -- Solde net de from :
  --   - cash_from_to (si positif il paie ; si négatif il reçoit)
  --   - v_from_pays  (commissions qu'il paie)
  --   + v_from_gets  (2/3 qu'il touche)
  if (v_from.budget - v_from.budget_locked)
     < (greatest(v_trade.cash_from_to,0) + v_from_pays) then
    raise exception 'Budget insuffisant côté initiateur (cash + commissions).';
  end if;
  if (v_me.budget - v_me.budget_locked)
     < (greatest(-v_trade.cash_from_to,0) + v_to_pays) then
    raise exception 'Votre budget est insuffisant (cash + commissions).';
  end if;

  -- ---- Exécution : transfert des joueurs ----
  update qm_players set owner_id = v_trade.to_manager   where id = any(v_trade.offer_players);
  update qm_players set owner_id = v_trade.from_manager where id = any(v_trade.ask_players);

  -- ---- Mouvement de cash de l'échange ----
  if v_trade.cash_from_to <> 0 then
    update qm_managers set budget = budget - v_trade.cash_from_to where id = v_trade.from_manager;
    update qm_managers set budget = budget + v_trade.cash_from_to where id = v_trade.to_manager;
  end if;

  -- ---- Mouvement des commissions ----
  -- Chaque manager paie ses commissions de receveur et touche ses 2/3 de cédant.
  -- Le 1/3 restant n'est reversé à personne (s'évapore = taxe de ligue).
  update qm_managers set budget = budget - v_from_pays + v_from_gets
    where id = v_trade.from_manager;
  update qm_managers set budget = budget - v_to_pays + v_to_gets
    where id = v_trade.to_manager;

  -- ---- Historique ----
  insert into qm_transfers (player_id, from_manager, to_manager, price)
    select unnest(v_trade.offer_players), v_trade.from_manager, v_trade.to_manager, 0;
  insert into qm_transfers (player_id, from_manager, to_manager, price)
    select unnest(v_trade.ask_players), v_trade.to_manager, v_trade.from_manager, 0;

  update qm_trades set status='accepted', resolved_at=now() where id=p_trade_id
    returning * into v_trade;
  return v_trade;
end;
$$;

-- ---------- Estimation des commissions d'un échange (pour le front) --
-- Retourne combien CHAQUE manager paierait, pour affichage avant accept.
create or replace function qm_estimate_trade_commissions(p_trade_id uuid)
returns table (from_pays bigint, to_pays bigint, from_gets bigint, to_gets bigint)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_trade qm_trades;
  v_pid uuid;
  v_comm bigint;
  fp bigint := 0; tp bigint := 0; fg bigint := 0; tg bigint := 0;
begin
  select * into v_trade from qm_trades where id = p_trade_id;
  if not found then return; end if;

  if array_length(v_trade.offer_players,1) is not null then
    foreach v_pid in array v_trade.offer_players loop
      v_comm := qm_purchase_commission(v_trade.to_manager, v_pid);
      tp := tp + v_comm; fg := fg + (v_comm*2/3);
    end loop;
  end if;
  if array_length(v_trade.ask_players,1) is not null then
    foreach v_pid in array v_trade.ask_players loop
      v_comm := qm_purchase_commission(v_trade.from_manager, v_pid);
      fp := fp + v_comm; tg := tg + (v_comm*2/3);
    end loop;
  end if;

  from_pays := fp; to_pays := tp; from_gets := fg; to_gets := tg;
  return next;
end;
$$;
