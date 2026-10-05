-- =====================================================================
-- ULTIMATE SQUAD — Vague 3, Étape 1 : FONDATIONS
-- =====================================================================
-- Pose le socle du système "11 titulaires notés par journée" :
--   1. Rôle Coach : un second compte lié à l'équipe (associé par l'admin).
--   2. Journées de championnat (qm_matchdays).
--   3. Compositions : les 11 alignés par équipe et par journée (qm_lineups).
--   4. Notes de journée : note + statut par joueur et par journée (qm_player_scores).
--   5. Points d'équipe par journée (qm_matchday_points).
--
-- Cette étape crée uniquement les TABLES et les enums. Les fonctions de
-- jeu (aligner, saisir, calculer) viennent aux étapes suivantes.
-- Rien de visible côté joueur encore. À passer après le script 36.
--
-- ⚠️ Contient des CREATE TYPE. Si le SQL Editor bute sur un enum, passe
--    d'abord les CREATE TYPE seuls (section 0), puis le reste.
-- =====================================================================

-- ---------- 0. Enums ------------------------------------------------
do $$ begin
  if not exists (select 1 from pg_type where typname='qm_matchday_status') then
    create type qm_matchday_status as enum ('upcoming','open','scoring','closed');
  end if;
  if not exists (select 1 from pg_type where typname='qm_play_status') then
    create type qm_play_status as enum ('starter','sub','dnp');  -- titulaire / entré en jeu / pas joué
  end if;
end $$;

-- ---------- 1. Rôle Coach : lien vers l'équipe ---------------------
-- Le Coach est un compte qm_managers "rattaché" à une équipe principale.
-- coach_of pointe vers l'équipe (le Manager) que ce compte coache.
-- NULL = ce compte n'est pas un coach (c'est un manager à part entière).
alter table qm_managers add column if not exists coach_of uuid references qm_managers(id) on delete set null;
alter table qm_managers add column if not exists is_coach boolean not null default false;

-- ---------- 2. Journées de championnat -----------------------------
create table if not exists qm_matchdays (
  id           uuid primary key default gen_random_uuid(),
  number       integer not null,                 -- J1, J2, J3...
  label        text,                             -- libellé libre ("Journée 5")
  status       qm_matchday_status not null default 'upcoming',
  lineup_deadline timestamptz,                   -- date limite d'alignement (lundi 8h etc.)
  created_at   timestamptz not null default now(),
  unique (number)
);
create index if not exists idx_qm_matchdays_status on qm_matchdays(status);

-- ---------- 3. Compositions (les 11 par équipe et par journée) -----
create table if not exists qm_lineups (
  id           uuid primary key default gen_random_uuid(),
  manager_id   uuid not null references qm_managers(id) on delete cascade,
  matchday_id  uuid not null references qm_matchdays(id) on delete cascade,
  player_ids   uuid[] not null default '{}',     -- les 11 joueurs alignés
  set_by       uuid references qm_managers(id),  -- qui a aligné (coach ou manager)
  reconducted  boolean not null default false,   -- true si repris automatiquement
  updated_at   timestamptz not null default now(),
  unique (manager_id, matchday_id)
);
create index if not exists idx_qm_lineups_md on qm_lineups(matchday_id);

-- ---------- 4. Notes de journée (par joueur, saisies par les admins)-
-- UNE ligne par joueur et par journée : la note est saisie une seule
-- fois même si le joueur est aligné par plusieurs équipes.
create table if not exists qm_player_scores (
  id           uuid primary key default gen_random_uuid(),
  player_id    uuid not null references qm_players(id) on delete cascade,
  matchday_id  uuid not null references qm_matchdays(id) on delete cascade,
  rating       numeric(4,2),                     -- note Sofascore (ex : 7.85), NULL si pas encore saisi
  play_status  qm_play_status not null default 'dnp',
  scored_by    uuid references qm_managers(id),  -- quel admin a saisi
  updated_at   timestamptz not null default now(),
  unique (player_id, matchday_id)
);
create index if not exists idx_qm_scores_md on qm_player_scores(matchday_id);

-- ---------- 5. Points d'équipe par journée -------------------------
create table if not exists qm_matchday_points (
  id           uuid primary key default gen_random_uuid(),
  manager_id   uuid not null references qm_managers(id) on delete cascade,
  matchday_id  uuid not null references qm_matchdays(id) on delete cascade,
  points       numeric(6,2) not null default 0,  -- somme pondérée des 11 notes
  detail       jsonb,                            -- trace du calcul (optionnel)
  created_at   timestamptz not null default now(),
  unique (manager_id, matchday_id)
);
create index if not exists idx_qm_mdpoints_md on qm_matchday_points(matchday_id);

-- ---------- 6. RLS (lecture publique, écriture par fonctions) ------
alter table qm_matchdays enable row level security;
alter table qm_lineups enable row level security;
alter table qm_player_scores enable row level security;
alter table qm_matchday_points enable row level security;

-- Lecture : tout le monde peut voir les journées, notes, points, compos
do $$ begin
  if not exists (select 1 from pg_policies where tablename='qm_matchdays' and policyname='qm_matchdays_read') then
    create policy qm_matchdays_read on qm_matchdays for select using (true);
  end if;
  if not exists (select 1 from pg_policies where tablename='qm_player_scores' and policyname='qm_scores_read') then
    create policy qm_scores_read on qm_player_scores for select using (true);
  end if;
  if not exists (select 1 from pg_policies where tablename='qm_matchday_points' and policyname='qm_mdpoints_read') then
    create policy qm_mdpoints_read on qm_matchday_points for select using (true);
  end if;
  -- Compos : lecture publique (voir les équipes des autres), écriture via fonctions SECURITY DEFINER
  if not exists (select 1 from pg_policies where tablename='qm_lineups' and policyname='qm_lineups_read') then
    create policy qm_lineups_read on qm_lineups for select using (true);
  end if;
end $$;

-- Aucune policy d'écriture directe : toutes les écritures passeront par
-- des fonctions SECURITY DEFINER (étapes suivantes), donc le socle est sûr.
