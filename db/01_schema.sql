-- =====================================================================
-- QUIZ MERCATO — Schéma (préfixe qm_, base FHAF partagée) (PostgreSQL / Supabase)
-- =====================================================================
-- Modèle : mercato fantasy adossé aux quiz (pas de dépendance externe).
-- Les vrais joueurs sont des actifs. Les points viennent des perfs
-- des MANAGERS dans les quiz, pas des matchs réels.
-- =====================================================================

-- ---------- ENUMS -----------------------------------------------------
create type qm_player_position as enum ('GK', 'DEF', 'MID', 'FWD');
create type qm_player_status   as enum ('free', 'owned', 'locked'); -- locked = enchère en cours
create type qm_auction_status  as enum ('open', 'closed', 'cancelled');
create type qm_mercato_phase   as enum ('closed', 'open', 'frozen');   -- frozen = effectifs figés, compétition en cours

-- ---------- MANAGERS (participants) -----------------------------------
-- Un manager = un utilisateur Supabase Auth qui participe à une saison.
create table qm_managers (
  id            uuid primary key default gen_random_uuid(),
  auth_user_id  uuid not null references auth.users(id) on delete cascade,
  display_name  text not null,
  budget        bigint not null default 700000000,   -- 700 M€ en euros (bigint = pas de flottant sur l'argent)
  budget_locked bigint not null default 0,           -- fonds engagés dans des enchères actives
  season_points integer not null default 0,
  created_at    timestamptz not null default now(),
  unique (auth_user_id)
);

-- budget disponible = budget - budget_locked (calculé, jamais stocké en double)
create or replace function qm_manager_available_budget(m qm_managers)
returns bigint language sql immutable as $$
  select m.budget - m.budget_locked;
$$;

-- ---------- PLAYERS (vrais joueurs de foot = actifs) ------------------
create table qm_players (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  position      qm_player_position not null,
  club          text,
  nationality   text,
  age           integer,
  photo_url     text,
  base_value    bigint not null,                     -- valeur de départ saisie par l'admin
  current_value bigint not null,                     -- évolue selon la demande interne
  owner_id      uuid references qm_managers(id) on delete set null,
  status        qm_player_status not null default 'free',
  demand_score  integer not null default 0,          -- nb d'enchères cumulées → pilote current_value
  created_at    timestamptz not null default now()
);

create index idx_qm_players_status   on qm_players(status);
create index idx_qm_players_owner    on qm_players(owner_id);
create index idx_qm_players_position on qm_players(position);

-- ---------- RARETÉ (calculée depuis current_value) --------------------
create or replace function qm_player_rarity(value bigint)
returns text language sql immutable as $$
  select case
    when value >= 100000000 then 'legend'   -- 100M+  ⭐⭐⭐⭐⭐
    when value >=  60000000 then 'platinum'  -- 60-100 ⭐⭐⭐⭐
    when value >=  30000000 then 'gold'      -- 30-60  ⭐⭐⭐
    when value >=  10000000 then 'silver'    -- 10-30  ⭐⭐
    else 'bronze'                            -- 0-10   ⭐
  end;
$$;

-- Mise minimale selon la valeur (barème d'Audrey)
create or replace function qm_min_increment(value bigint)
returns bigint language sql immutable as $$
  select case
    when value > 150000000 then 15000000
    when value > 100000000 then 10000000
    when value >  60000000 then  5000000
    when value >  30000000 then  2000000
    when value >  10000000 then  1000000
    else                          500000
  end;
$$;

-- ---------- AUCTIONS (enchères) ---------------------------------------
create table qm_auctions (
  id             uuid primary key default gen_random_uuid(),
  player_id      uuid not null references qm_players(id) on delete cascade,
  status         qm_auction_status not null default 'open',
  current_price  bigint not null,                    -- prix actuel
  top_bidder_id  uuid references qm_managers(id) on delete set null,
  ends_at        timestamptz not null,               -- fin (48h par défaut)
  created_at     timestamptz not null default now(),
  -- Une seule enchère ouverte par joueur à la fois
  constraint one_open_auction_per_player exclude (player_id with =) where (status = 'open')
);

create index idx_qm_auctions_status on qm_auctions(status);
create index idx_qm_auctions_ends   on qm_auctions(ends_at) where status = 'open';

-- ---------- BIDS (offres) — historique complet ------------------------
create table qm_bids (
  id          uuid primary key default gen_random_uuid(),
  auction_id  uuid not null references qm_auctions(id) on delete cascade,
  manager_id  uuid not null references qm_managers(id) on delete cascade,
  amount      bigint not null,
  created_at  timestamptz not null default now()
);

create index idx_qm_bids_auction on qm_bids(auction_id, created_at desc);

-- ---------- TRANSFERS (historique type Transfermarkt) ----------------
create table qm_transfers (
  id           uuid primary key default gen_random_uuid(),
  player_id    uuid not null references qm_players(id) on delete cascade,
  from_manager uuid references qm_managers(id) on delete set null,  -- null = achat au marché
  to_manager   uuid references qm_managers(id) on delete set null,
  price        bigint not null,
  created_at   timestamptz not null default now()
);

create index idx_qm_transfers_player  on qm_transfers(player_id, created_at desc);
create index idx_qm_transfers_manager on qm_transfers(to_manager);

-- ---------- SEASON / ÉTAT GLOBAL DU MERCATO ---------------------------
create table qm_season_state (
  id           integer primary key default 1,
  phase        qm_mercato_phase not null default 'closed',
  auction_hours integer not null default 48,
  updated_at   timestamptz not null default now(),
  constraint singleton check (id = 1)
);
insert into qm_season_state (id) values (1) on conflict do nothing;

-- ---------- CARTES SPÉCIALES (une par saison par manager) ------------
create type qm_special_card as enum ('captain', 'wonderkid', 'wall', 'joker');

create table qm_manager_cards (
  id          uuid primary key default gen_random_uuid(),
  manager_id  uuid not null references qm_managers(id) on delete cascade,
  card        qm_special_card not null,
  used_at     timestamptz,                            -- null = pas encore utilisée
  target_player uuid references qm_players(id),
  unique (manager_id, card)                            -- une seule de chaque type par manager
);
