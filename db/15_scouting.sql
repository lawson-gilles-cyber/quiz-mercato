-- =====================================================================
-- QUIZ MERCATO — Dénichage de joueurs (proposition par les managers)
-- =====================================================================
-- Un manager déniche un joueur et le propose. L'admin valide, le joueur
-- passe aux enchères, et le système retient qui l'a déniché. À la
-- clôture, si un AUTRE manager le remporte, le dénicheur touche un bonus
-- de budget fixe (+5 M€). Rien si invendu, rien si le dénicheur gagne
-- lui-même. Max 3 propositions en attente par manager.
--
-- Objectif : récompenser ceux qui font le travail de recherche en amont,
-- et décourager les managers passifs qui attendent pour surenchérir.
--
-- À passer APRÈS 12_commissions.sql (redéfinit qm_close_auction).
-- =====================================================================

-- Montant du bonus (réglable en admin)
alter table qm_season_state add column if not exists scout_bonus bigint not null default 5000000;

-- Colonne : qui a déniché le joueur d'une enchère (null = ajouté par l'admin)
alter table qm_auctions add column if not exists scouted_by uuid references qm_managers(id);

-- ---------- Table des propositions de joueurs ------------------------
create type qm_proposal_status as enum ('pending', 'approved', 'rejected');

create table if not exists qm_player_proposals (
  id            uuid primary key default gen_random_uuid(),
  proposer_id   uuid not null references qm_managers(id) on delete cascade,
  -- Le joueur proposé : soit un joueur déjà en base, soit un nouveau à créer
  player_id     uuid references qm_players(id) on delete set null,
  new_name      text,          -- si nouveau joueur
  new_position  qm_player_position,
  new_club      text,
  new_value     bigint,
  status        qm_proposal_status not null default 'pending',
  created_at    timestamptz not null default now(),
  resolved_at   timestamptz
);

create index if not exists idx_qm_proposals_status on qm_player_proposals(status);
create index if not exists idx_qm_proposals_proposer on qm_player_proposals(proposer_id) where status='pending';

alter table qm_player_proposals enable row level security;
create policy "qm read own proposals" on qm_player_proposals for select using (
  proposer_id in (select id from qm_managers where auth_user_id = auth.uid())
  or qm_is_admin()
);

-- ---------- Manager : proposer un joueur ----------------------------
create or replace function qm_propose_player(
  p_player_id  uuid,     -- si joueur existant (sinon null)
  p_new_name   text,     -- si nouveau joueur
  p_new_position qm_player_position,
  p_new_club   text,
  p_new_value  bigint
)
returns qm_player_proposals
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me qm_managers;
  v_pending integer;
  v_prop qm_player_proposals;
begin
  select * into v_me from qm_managers where auth_user_id = auth.uid();
  if not found then raise exception 'Vous ne participez pas à cette saison'; end if;

  -- Max 3 propositions en attente
  select count(*) into v_pending from qm_player_proposals
    where proposer_id = v_me.id and status = 'pending';
  if v_pending >= 3 then
    raise exception 'Vous avez déjà 3 propositions en attente. Attendez leur validation.';
  end if;

  -- Validation minimale
  if p_player_id is null and (p_new_name is null or p_new_value is null) then
    raise exception 'Indiquez un joueur existant, ou le nom et la valeur d''un nouveau joueur.';
  end if;

  insert into qm_player_proposals (proposer_id, player_id, new_name, new_position, new_club, new_value)
  values (v_me.id, p_player_id, p_new_name, p_new_position, p_new_club, p_new_value)
  returning * into v_prop;
  return v_prop;
end;
$$;

-- ---------- Manager : mes propositions ------------------------------
create or replace function qm_my_proposals()
returns setof qm_player_proposals
language sql
security definer
set search_path = public
as $$
  select * from qm_player_proposals
  where proposer_id in (select id from qm_managers where auth_user_id = auth.uid())
  order by created_at desc;
$$;

-- ---------- Admin : liste des propositions en attente ---------------
create or replace function qm_admin_pending_proposals()
returns table (
  id uuid, proposer text, player_name text, pos qm_player_position,
  club text, value bigint, existing boolean, created_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select
    pr.id,
    m.display_name,
    coalesce(p.name, pr.new_name),
    coalesce(p.position, pr.new_position),
    coalesce(p.club, pr.new_club),
    coalesce(p.current_value, pr.new_value),
    (pr.player_id is not null),
    pr.created_at
  from qm_player_proposals pr
  join qm_managers m on m.id = pr.proposer_id
  left join qm_players p on p.id = pr.player_id
  where pr.status = 'pending'
  order by pr.created_at;
$$;

-- ---------- Admin : approuver une proposition (ouvre l'enchère) -----
create or replace function qm_admin_approve_proposal(p_proposal_id uuid)
returns qm_auctions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_prop    qm_player_proposals;
  v_player  qm_players;
  v_hours   integer;
  v_auction qm_auctions;
begin
  if not qm_is_admin() then raise exception 'Réservé aux administrateurs'; end if;

  select * into v_prop from qm_player_proposals where id = p_proposal_id for update;
  if not found then raise exception 'Proposition introuvable'; end if;
  if v_prop.status <> 'pending' then raise exception 'Proposition déjà traitée'; end if;

  -- Résoudre le joueur : existant, ou créer le nouveau
  if v_prop.player_id is not null then
    select * into v_player from qm_players where id = v_prop.player_id for update;
    if v_player.status <> 'free' then
      raise exception 'Ce joueur n''est plus disponible.';
    end if;
  else
    insert into qm_players (name, position, club, base_value, current_value)
    values (v_prop.new_name, coalesce(v_prop.new_position,'MID'), v_prop.new_club,
            v_prop.new_value, v_prop.new_value)
    returning * into v_player;
  end if;

  -- Ouvrir l'enchère en mémorisant le dénicheur
  select auction_hours into v_hours from qm_season_state where id = 1;
  insert into qm_auctions (player_id, current_price, ends_at, scouted_by)
  values (v_player.id, v_player.current_value,
          now() + (v_hours || ' hours')::interval, v_prop.proposer_id)
  returning * into v_auction;

  update qm_players set status = 'locked' where id = v_player.id;
  update qm_player_proposals set status='approved', resolved_at=now() where id=p_proposal_id;

  return v_auction;
end;
$$;

-- ---------- Admin : rejeter une proposition -------------------------
create or replace function qm_admin_reject_proposal(p_proposal_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not qm_is_admin() then raise exception 'Réservé aux administrateurs'; end if;
  update qm_player_proposals set status='rejected', resolved_at=now()
    where id=p_proposal_id and status='pending';
end;
$$;

-- =====================================================================
-- close_auction AVEC bonus au dénicheur
-- =====================================================================
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

  -- Aucun enchérisseur : joueur redevient libre, pas de bonus
  if v_auction.top_bidder_id is null then
    update qm_players set status = 'free' where id = v_player.id;
    update qm_auctions set status = 'closed' where id = p_auction_id returning * into v_auction;
    return v_auction;
  end if;

  v_commission := qm_purchase_commission(v_auction.top_bidder_id, v_auction.player_id);

  -- Le gagnant paie prix + commission
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

  -- ----- BONUS AU DÉNICHEUR -----
  -- Versé seulement si le joueur a été déniché par un manager ET
  -- qu'un AUTRE manager le remporte (pas le dénicheur lui-même).
  if v_auction.scouted_by is not null
     and v_auction.scouted_by <> v_auction.top_bidder_id then
    select scout_bonus into v_bonus from qm_season_state where id = 1;
    update qm_managers set budget = budget + v_bonus where id = v_auction.scouted_by;
  end if;

  update qm_auctions set status = 'closed' where id = p_auction_id returning * into v_auction;
  return v_auction;
end;
$$;

-- ---------- Admin : régler le montant du bonus ----------------------
create or replace function qm_admin_set_scout_bonus(p_bonus bigint)
returns qm_season_state
language plpgsql
security definer
set search_path = public
as $$
declare v_state qm_season_state;
begin
  if not qm_is_admin() then raise exception 'Réservé aux administrateurs'; end if;
  if p_bonus < 0 then raise exception 'Le bonus ne peut pas être négatif'; end if;
  update qm_season_state set scout_bonus = p_bonus, updated_at = now()
    where id = 1 returning * into v_state;
  return v_state;
end;
$$;
