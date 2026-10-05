-- =====================================================================
-- ULTIMATE SQUAD — Libération de joueur (Bloc 2, Audrey)
-- =====================================================================
-- Un manager peut LIBÉRER un joueur (l'abandonner), distinct de la
-- revente par échange. Règles :
--
--  * Délai minimum : 24h de détention avant de pouvoir libérer.
--  * Pénalité PROGRESSIVE selon le temps de détention :
--      24-48h  -> récupère 85 % (pénalité 15 %)
--      48h-7j  -> récupère 90 % (pénalité 10 %)
--      +7j     -> récupère 95 % (pénalité  5 %)
--  * Le montant récupéré = pourcentage du PRIX D'ACHAT réel.
--  * La pénalité est définitivement perdue (sort du jeu).
--  * Le joueur redevient LIBRE (réenchérissable).
--  * Maximum 2 libérations par manager par période glissante de 7 jours.
--
-- Toutes les libérations sont tracées (onglet Pénalité).
-- À passer APRÈS 22_trade_commission_acq.sql.
-- =====================================================================

-- ---------- Table de traçage des libérations / pénalités -----------
create table if not exists qm_releases (
  id            uuid primary key default gen_random_uuid(),
  manager_id    uuid not null references qm_managers(id) on delete cascade,
  player_id     uuid references qm_players(id) on delete set null,
  player_name   text not null,             -- gardé même si le joueur est supprimé
  purchase_price bigint not null,          -- prix d'achat de référence
  refund        bigint not null,           -- montant récupéré
  penalty       bigint not null,           -- pénalité perdue
  penalty_pct   integer not null,          -- % de pénalité appliqué (5/10/15)
  held_hours    integer not null,          -- durée de détention en heures
  created_at    timestamptz not null default now()
);

alter table qm_releases enable row level security;
create policy "qm read own releases" on qm_releases for select using (
  manager_id in (select id from qm_managers where auth_user_id = auth.uid()) or qm_is_admin()
);

-- ---------- Date d'acquisition d'un joueur par un manager ----------
create or replace function qm_acquisition_date(p_manager_id uuid, p_player_id uuid)
returns timestamptz
language sql
stable
security definer
set search_path = public
as $$
  select max(created_at) from qm_transfers
  where player_id = p_player_id and to_manager = p_manager_id;
$$;

-- ---------- Libérations d'un manager sur les 7 derniers jours ------
create or replace function qm_releases_last_7d(p_manager_id uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::integer from qm_releases
  where manager_id = p_manager_id and created_at >= now() - interval '7 days';
$$;

-- ---------- Prévisualisation : ce que donnerait une libération -----
-- Renvoie held_hours, penalty_pct, refund, penalty (0 si pas libérable).
create or replace function qm_release_preview(p_player_id uuid)
returns table (held_hours integer, penalty_pct integer, refund bigint, penalty bigint, can_release boolean, reason text)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_me uuid;
  v_player qm_players;
  v_acq_date timestamptz;
  v_acq_price bigint;
  v_hours integer;
  v_pct integer;
  v_refund bigint;
begin
  select id into v_me from qm_managers where auth_user_id = auth.uid();
  select * into v_player from qm_players where id = p_player_id;

  held_hours := 0; penalty_pct := 0; refund := 0; penalty := 0;
  can_release := false; reason := '';

  if v_me is null or v_player.owner_id is distinct from v_me then
    reason := 'Vous ne possédez pas ce joueur.'; return next; return;
  end if;

  if qm_releases_last_7d(v_me) >= 2 then
    reason := 'Limite de 2 libérations sur 7 jours atteinte.'; return next; return;
  end if;

  v_acq_date := qm_acquisition_date(v_me, p_player_id);
  v_acq_price := qm_acquisition_price(v_me, p_player_id);
  v_hours := floor(extract(epoch from (now() - coalesce(v_acq_date, now()))) / 3600)::integer;
  held_hours := v_hours;

  if v_hours < 24 then
    reason := 'Détention minimale de 24h non atteinte (actuellement ' || v_hours || 'h).';
    return next; return;
  end if;

  -- Pénalité progressive
  if v_hours >= 168 then v_pct := 5;        -- +7 jours
  elsif v_hours >= 48 then v_pct := 10;     -- 48h - 7j
  else v_pct := 15;                          -- 24h - 48h
  end if;

  v_refund := round(v_acq_price * (100 - v_pct) / 100.0)::bigint;
  penalty_pct := v_pct;
  refund := v_refund;
  penalty := v_acq_price - v_refund;
  can_release := true;
  reason := 'OK';
  return next;
end;
$$;

-- ---------- Libérer un joueur --------------------------------------
create or replace function qm_release_player(p_player_id uuid)
returns qm_releases
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me qm_managers;
  v_player qm_players;
  v_acq_date timestamptz;
  v_acq_price bigint;
  v_hours integer;
  v_pct integer;
  v_refund bigint;
  v_rel qm_releases;
begin
  select * into v_me from qm_managers where auth_user_id = auth.uid() for update;
  if not found then raise exception 'Vous ne participez pas à cette saison'; end if;

  select * into v_player from qm_players where id = p_player_id for update;
  if not found then raise exception 'Joueur introuvable'; end if;
  if v_player.owner_id is distinct from v_me.id then
    raise exception 'Vous ne possédez pas ce joueur.';
  end if;

  -- Limite 2 / 7 jours
  if qm_releases_last_7d(v_me.id) >= 2 then
    raise exception 'Limite de 2 libérations sur une période de 7 jours atteinte.';
  end if;

  -- Détention minimale 24h
  v_acq_date := qm_acquisition_date(v_me.id, p_player_id);
  v_hours := floor(extract(epoch from (now() - coalesce(v_acq_date, now()))) / 3600)::integer;
  if v_hours < 24 then
    raise exception 'Vous devez détenir le joueur au moins 24h avant de le libérer (actuellement %h).', v_hours;
  end if;

  -- Pénalité progressive
  if v_hours >= 168 then v_pct := 5;
  elsif v_hours >= 48 then v_pct := 10;
  else v_pct := 15;
  end if;

  v_acq_price := qm_acquisition_price(v_me.id, p_player_id);
  v_refund := round(v_acq_price * (100 - v_pct) / 100.0)::bigint;

  -- Remboursement au manager (le reste = pénalité, sort du jeu)
  update qm_managers set budget = budget + v_refund where id = v_me.id;

  -- Le joueur redevient libre
  update qm_players set owner_id = null, status = 'free' where id = p_player_id;

  -- Trace
  insert into qm_releases (manager_id, player_id, player_name, purchase_price, refund, penalty, penalty_pct, held_hours)
  values (v_me.id, p_player_id, v_player.name, v_acq_price, v_refund, v_acq_price - v_refund, v_pct, v_hours)
  returning * into v_rel;

  -- Historise comme un "transfert sortant" vers le marché (from=manager, to=null)
  insert into qm_transfers (player_id, from_manager, to_manager, price)
  values (p_player_id, v_me.id, null, 0);

  return v_rel;
end;
$$;

-- ---------- Mes libérations (onglet Pénalité, côté manager) --------
create or replace function qm_my_releases()
returns setof qm_releases
language sql
stable
security definer
set search_path = public
as $$
  select r.* from qm_releases r
  join qm_managers m on m.id = r.manager_id
  where m.auth_user_id = auth.uid()
  order by r.created_at desc;
$$;

-- ---------- Toutes les libérations (admin) -------------------------
create or replace function qm_admin_releases()
returns table (
  manager_name text, player_name text, purchase_price bigint,
  refund bigint, penalty bigint, penalty_pct integer, held_hours integer, created_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select m.display_name, r.player_name, r.purchase_price,
         r.refund, r.penalty, r.penalty_pct, r.held_hours, r.created_at
  from qm_releases r
  join qm_managers m on m.id = r.manager_id
  order by r.created_at desc
  limit 200;
$$;
