-- =====================================================================
-- QUIZ MERCATO — Moteur d'échange entre managers
-- =====================================================================
-- Un manager propose un troc : joueurs (± cash) contre joueurs (± cash).
-- L'autre accepte / refuse. À l'acceptation, tout bascule en une seule
-- transaction atomique : propriétés + budgets, avec vérification des
-- règles d'effectif des deux côtés. Si un contrôle échoue, tout annule.
--
-- Décisions validées :
--   1. Cash autorisé dans les deux sens
--   2. Règles d'effectif appliquées aux deux managers
--   3. Joueurs en enchère (locked) non échangeables
--   4. Échanges multiples (N contre M joueurs)
--   5. Vit dans l'onglet Mercato
-- =====================================================================

create type qm_trade_status as enum ('pending', 'accepted', 'refused', 'cancelled');

-- ---------- Table des propositions d'échange -------------------------
create table if not exists qm_trades (
  id            uuid primary key default gen_random_uuid(),
  from_manager  uuid not null references qm_managers(id) on delete cascade,
  to_manager    uuid not null references qm_managers(id) on delete cascade,
  -- joueurs offerts par l'initiateur (from) et demandés à la cible (to)
  offer_players uuid[] not null default '{}',   -- ids de joueurs de "from"
  ask_players   uuid[] not null default '{}',   -- ids de joueurs de "to"
  -- cash : positif = from paie to ; négatif = to paie from
  cash_from_to  bigint not null default 0,
  status        qm_trade_status not null default 'pending',
  message       text,
  created_at    timestamptz not null default now(),
  resolved_at   timestamptz,
  constraint different_managers check (from_manager <> to_manager),
  constraint has_content check (
    array_length(offer_players,1) is not null or array_length(ask_players,1) is not null
  )
);

create index if not exists idx_qm_trades_to   on qm_trades(to_manager) where status='pending';
create index if not exists idx_qm_trades_from on qm_trades(from_manager) where status='pending';

alter table qm_trades enable row level security;
-- Un manager voit les trades qui le concernent (envoyés ou reçus)
create policy "qm read own trades" on qm_trades for select using (
  from_manager in (select id from qm_managers where auth_user_id = auth.uid())
  or to_manager in (select id from qm_managers where auth_user_id = auth.uid())
);

-- ---------- Vérifie qu'un lot de joueurs appartient bien à un manager
-- et qu'aucun n'est en enchère (locked)
create or replace function qm_validate_trade_players(p_manager uuid, p_players uuid[])
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
  v_locked integer;
begin
  if array_length(p_players,1) is null then return; end if;

  -- Tous les joueurs doivent appartenir au manager
  select count(*) into v_count from qm_players
    where id = any(p_players) and owner_id = p_manager;
  if v_count <> array_length(p_players,1) then
    raise exception 'Un ou plusieurs joueurs n''appartiennent pas au bon manager';
  end if;

  -- Aucun ne doit être en enchère
  select count(*) into v_locked from qm_players
    where id = any(p_players) and status <> 'owned';
  if v_locked > 0 then
    raise exception 'Un joueur est en enchère ou indisponible, échange impossible';
  end if;
end;
$$;

-- ---------- Créer une proposition d'échange -------------------------
create or replace function qm_trade_propose(
  p_to_manager uuid,
  p_offer_players uuid[],
  p_ask_players uuid[],
  p_cash_from_to bigint,
  p_message text
)
returns qm_trades
language plpgsql
security definer
set search_path = public
as $$
declare
  v_from qm_managers;
  v_trade qm_trades;
begin
  select * into v_from from qm_managers where auth_user_id = auth.uid();
  if not found then raise exception 'Vous ne participez pas à cette saison'; end if;
  if v_from.id = p_to_manager then raise exception 'Impossible de troquer avec soi-même'; end if;

  -- Valide la propriété et la disponibilité des deux lots
  perform qm_validate_trade_players(v_from.id, p_offer_players);
  perform qm_validate_trade_players(p_to_manager, p_ask_players);

  insert into qm_trades (from_manager, to_manager, offer_players, ask_players, cash_from_to, message)
  values (v_from.id, p_to_manager, coalesce(p_offer_players,'{}'), coalesce(p_ask_players,'{}'),
          coalesce(p_cash_from_to,0), p_message)
  returning * into v_trade;
  return v_trade;
end;
$$;

-- ---------- Vérifie les règles d'effectif après un échange ----------
-- Simule l'effectif résultant pour un manager et applique les règles :
-- max 24, max 3 GK, max 3/club, max 2 cracks (QM>=85) par poste.
create or replace function qm_check_squad_after_trade(
  p_manager uuid,
  p_incoming uuid[],   -- joueurs qui arrivent
  p_outgoing uuid[]    -- joueurs qui partent
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_total integer;
  r record;
begin
  -- Effectif résultant = possédés - sortants + entrants
  drop table if exists _squad;
  create temp table _squad on commit drop as
    select p.* from qm_players p
    where p.owner_id = p_manager
      and (p_outgoing is null or not (p.id = any(p_outgoing)))
    union
    select p.* from qm_players p where p.id = any(coalesce(p_incoming,'{}'));

  -- 1. Total <= 24
  select count(*) into v_total from _squad;
  if v_total > 24 then
    raise exception 'Échange refusé : effectif dépasserait 24 joueurs (%).', v_total;
  end if;

  -- 2. Max 3 gardiens
  if (select count(*) from _squad where position='GK') > 3 then
    raise exception 'Échange refusé : plus de 3 gardiens.';
  end if;

  -- 3. Max 3 par club
  for r in select club, count(*) c from _squad where club is not null group by club loop
    if r.c > 3 then
      raise exception 'Échange refusé : plus de 3 joueurs du club %.', r.club;
    end if;
  end loop;

  -- 4. Max 2 cracks (QM>=85) par poste
  for r in
    select position, count(*) c from _squad
    where qm_rating(_squad.*) >= 85 group by position
  loop
    if r.c > 2 then
      raise exception 'Échange refusé : plus de 2 cracks (QM≥85) au poste %.', r.position;
    end if;
  end loop;
end;
$$;

-- ---------- Accepter un échange (LA transaction atomique) -----------
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
begin
  -- Verrou sur le trade
  select * into v_trade from qm_trades where id = p_trade_id for update;
  if not found then raise exception 'Proposition introuvable'; end if;
  if v_trade.status <> 'pending' then raise exception 'Proposition déjà traitée'; end if;

  -- Le manager courant doit être le destinataire
  select * into v_me from qm_managers where auth_user_id = auth.uid() for update;
  if v_me.id <> v_trade.to_manager then
    raise exception 'Seul le destinataire peut accepter cette proposition';
  end if;
  select * into v_from from qm_managers where id = v_trade.from_manager for update;

  -- Re-valider la propriété et disponibilité (l'état a pu changer depuis la proposition)
  perform qm_validate_trade_players(v_trade.from_manager, v_trade.offer_players);
  perform qm_validate_trade_players(v_trade.to_manager,   v_trade.ask_players);

  -- Vérifier les règles d'effectif résultant pour les DEUX managers
  -- from : perd offer_players, gagne ask_players
  perform qm_check_squad_after_trade(v_trade.from_manager, v_trade.ask_players, v_trade.offer_players);
  -- to : perd ask_players, gagne offer_players
  perform qm_check_squad_after_trade(v_trade.to_manager,   v_trade.offer_players, v_trade.ask_players);

  -- Vérifier les budgets si du cash circule
  -- cash_from_to > 0 : from paie to. from doit avoir les fonds disponibles.
  if v_trade.cash_from_to > 0 then
    if (v_from.budget - v_from.budget_locked) < v_trade.cash_from_to then
      raise exception 'Budget insuffisant côté initiateur pour le complément en cash';
    end if;
  elsif v_trade.cash_from_to < 0 then
    if (v_me.budget - v_me.budget_locked) < abs(v_trade.cash_from_to) then
      raise exception 'Votre budget est insuffisant pour ce complément en cash';
    end if;
  end if;

  -- ---- Exécution ----
  -- Transfert des joueurs offerts : from -> to
  update qm_players set owner_id = v_trade.to_manager
    where id = any(v_trade.offer_players);
  -- Transfert des joueurs demandés : to -> from
  update qm_players set owner_id = v_trade.from_manager
    where id = any(v_trade.ask_players);

  -- Mouvement de cash
  if v_trade.cash_from_to <> 0 then
    update qm_managers set budget = budget - v_trade.cash_from_to where id = v_trade.from_manager;
    update qm_managers set budget = budget + v_trade.cash_from_to where id = v_trade.to_manager;
  end if;

  -- Historique des transferts (pour la colonne "Transférés" et le fil Transfermarkt)
  insert into qm_transfers (player_id, from_manager, to_manager, price)
    select unnest(v_trade.offer_players), v_trade.from_manager, v_trade.to_manager, 0;
  insert into qm_transfers (player_id, from_manager, to_manager, price)
    select unnest(v_trade.ask_players), v_trade.to_manager, v_trade.from_manager, 0;

  update qm_trades set status='accepted', resolved_at=now() where id=p_trade_id
    returning * into v_trade;
  return v_trade;
end;
$$;

-- ---------- Refuser un échange --------------------------------------
create or replace function qm_trade_refuse(p_trade_id uuid)
returns qm_trades
language plpgsql
security definer
set search_path = public
as $$
declare v_trade qm_trades; v_me qm_managers;
begin
  select * into v_me from qm_managers where auth_user_id = auth.uid();
  select * into v_trade from qm_trades where id = p_trade_id for update;
  if not found then raise exception 'Proposition introuvable'; end if;
  if v_trade.status <> 'pending' then raise exception 'Déjà traitée'; end if;
  if v_me.id <> v_trade.to_manager then raise exception 'Seul le destinataire peut refuser'; end if;
  update qm_trades set status='refused', resolved_at=now() where id=p_trade_id returning * into v_trade;
  return v_trade;
end;
$$;

-- ---------- Annuler sa propre proposition ---------------------------
create or replace function qm_trade_cancel(p_trade_id uuid)
returns qm_trades
language plpgsql
security definer
set search_path = public
as $$
declare v_trade qm_trades; v_me qm_managers;
begin
  select * into v_me from qm_managers where auth_user_id = auth.uid();
  select * into v_trade from qm_trades where id = p_trade_id for update;
  if not found then raise exception 'Proposition introuvable'; end if;
  if v_trade.status <> 'pending' then raise exception 'Déjà traitée'; end if;
  if v_me.id <> v_trade.from_manager then raise exception 'Seul l''initiateur peut annuler'; end if;
  update qm_trades set status='cancelled', resolved_at=now() where id=p_trade_id returning * into v_trade;
  return v_trade;
end;
$$;

-- ---------- Lecture : mes propositions (reçues + envoyées) ----------
create or replace function qm_my_trades()
returns setof qm_trades
language sql
security definer
set search_path = public
as $$
  select * from qm_trades
  where from_manager in (select id from qm_managers where auth_user_id = auth.uid())
     or to_manager   in (select id from qm_managers where auth_user_id = auth.uid())
  order by created_at desc;
$$;
