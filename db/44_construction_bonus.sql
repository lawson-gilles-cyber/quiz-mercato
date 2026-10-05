-- =====================================================================
-- ULTIMATE SQUAD — Bonus "Construction"
-- =====================================================================
-- Récompensent la vitesse de construction de l'effectif et sa diversité :
--   - 11 joueurs avant la fin du 5e jour  -> +10 M€
--   - 15 joueurs avant la fin du 8e jour  -> +10 M€
--   - 19 joueurs avant la fin du 10e jour -> +15 M€
--   - joueurs de 10 clubs différents (à tout moment) -> +10 M€
--
-- Les "jours" se comptent à partir de l'ouverture du MERCATO D'ÉTÉ
-- (opens_at de la fenêtre summer). Chaque bonus n'est versé qu'UNE fois.
--
-- ⚠️ ORDRE : la SECTION 0 (enum) doit être passée SEULE et EN PREMIER,
--    attendre "Success", PUIS le reste. Sinon erreur "unsafe use of new
--    value of enum type".
-- À passer après 43_wave3_minutes.sql.
-- =====================================================================

-- ---------- SECTION 0 : enum (À PASSER SEULE ET EN PREMIER) ---------
alter type qm_bonus_type add value if not exists 'construction';

-- =====================================================================
-- SECTION 1 : le reste (à passer APRÈS le commit de la section 0)
-- =====================================================================

-- ref_key : clé texte identifiant le palier (ex 'build_11', 'build_15',
-- 'build_19', 'build_clubs'). On ajoute la colonne AVANT l'index.
alter table qm_bonuses add column if not exists ref_key text;

-- Un seul bonus construction par manager et par palier
create unique index if not exists uq_qm_bonus_construction
  on qm_bonuses(manager_id, ref_key) where bonus_type = 'construction';

-- Montants réglables
alter table qm_season_state add column if not exists build_11_bonus  bigint not null default 10000000;
alter table qm_season_state add column if not exists build_15_bonus  bigint not null default 10000000;
alter table qm_season_state add column if not exists build_19_bonus  bigint not null default 15000000;
alter table qm_season_state add column if not exists build_clubs_bonus bigint not null default 10000000;

-- ---------- Date d'ouverture du mercato d'été ----------------------
create or replace function qm_summer_open_date()
returns timestamptz
language sql stable security definer set search_path = public
as $$
  select opens_at from qm_market_windows
  where kind = 'summer' and opens_at is not null
  order by opens_at asc limit 1;
$$;

-- ---------- Vérifier et verser les bonus Construction --------------
-- Appelée après chaque acquisition. Vérifie les paliers atteints et non
-- encore récompensés, dans le respect des échéances (jours depuis
-- l'ouverture du mercato d'été).
create or replace function qm_check_construction_bonus(p_manager_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_count integer;
  v_clubs integer;
  v_open timestamptz;
  v_days numeric;
  v_b11 bigint; v_b15 bigint; v_b19 bigint; v_bclubs bigint;
begin
  select build_11_bonus, build_15_bonus, build_19_bonus, build_clubs_bonus
    into v_b11, v_b15, v_b19, v_bclubs from qm_season_state where id = 1;

  -- Effectif actuel (joueurs possédés)
  select count(*) into v_count from qm_players where owner_id = p_manager_id;
  -- Clubs distincts dans l'effectif
  select count(distinct club) into v_clubs from qm_players
    where owner_id = p_manager_id and club is not null;

  -- Jours écoulés depuis l'ouverture du mercato d'été
  v_open := qm_summer_open_date();
  if v_open is not null then
    v_days := extract(epoch from (now() - v_open)) / 86400.0;
  else
    v_days := null;  -- pas de date => on n'applique pas les paliers datés
  end if;

  -- Palier 11 joueurs avant la fin du 5e jour (<= 5 jours)
  if v_count >= 11 and v_days is not null and v_days <= 5 then
    begin
      insert into qm_bonuses (manager_id, bonus_type, amount, detail, ref_key)
      values (p_manager_id, 'construction', v_b11, '11 joueurs avant la fin du 5e jour', 'build_11');
      update qm_managers set budget = budget + v_b11 where id = p_manager_id;
    exception when unique_violation then null; end;
  end if;

  -- Palier 15 joueurs avant la fin du 8e jour
  if v_count >= 15 and v_days is not null and v_days <= 8 then
    begin
      insert into qm_bonuses (manager_id, bonus_type, amount, detail, ref_key)
      values (p_manager_id, 'construction', v_b15, '15 joueurs avant la fin du 8e jour', 'build_15');
      update qm_managers set budget = budget + v_b15 where id = p_manager_id;
    exception when unique_violation then null; end;
  end if;

  -- Palier 19 joueurs avant la fin du 10e jour
  if v_count >= 19 and v_days is not null and v_days <= 10 then
    begin
      insert into qm_bonuses (manager_id, bonus_type, amount, detail, ref_key)
      values (p_manager_id, 'construction', v_b19, '19 joueurs avant la fin du 10e jour', 'build_19');
      update qm_managers set budget = budget + v_b19 where id = p_manager_id;
    exception when unique_violation then null; end;
  end if;

  -- 10 clubs différents (à tout moment)
  if v_clubs >= 10 then
    begin
      insert into qm_bonuses (manager_id, bonus_type, amount, detail, ref_key)
      values (p_manager_id, 'construction', v_bclubs, 'Joueurs de 10 clubs différents ou plus', 'build_clubs');
      update qm_managers set budget = budget + v_bclubs where id = p_manager_id;
    exception when unique_violation then null; end;
  end if;
end; $$;

-- ---------- Brancher la vérification sur les acquisitions ----------
-- On redéfinit les deux points d'acquisition (fin d'enchère + recrutement
-- direct) pour qu'ils appellent aussi qm_check_construction_bonus.
-- On garde tout le comportement existant et on ajoute juste l'appel.

-- a) Fin d'enchère : on encapsule sans réécrire toute la fonction.
--    On ajoute un trigger léger : après insertion d'un transfert (toute
--    acquisition passe par qm_transfers), on vérifie la construction.
create or replace function qm_after_transfer_construction()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if NEW.to_manager is not null then
    perform qm_check_construction_bonus(NEW.to_manager);
  end if;
  return NEW;
end; $$;

drop trigger if exists trg_qm_construction on qm_transfers;
create trigger trg_qm_construction
  after insert on qm_transfers
  for each row execute function qm_after_transfer_construction();

-- ---------- Réglage admin des montants Construction ----------------
create or replace function qm_admin_set_construction_bonuses(
  p_b11 bigint, p_b15 bigint, p_b19 bigint, p_clubs bigint
)
returns qm_season_state
language plpgsql security definer set search_path = public
as $$
declare v_state qm_season_state;
begin
  if not qm_is_admin() then raise exception 'Réservé aux administrateurs'; end if;
  update qm_season_state set
    build_11_bonus = greatest(p_b11,0),
    build_15_bonus = greatest(p_b15,0),
    build_19_bonus = greatest(p_b19,0),
    build_clubs_bonus = greatest(p_clubs,0),
    updated_at = now()
  where id = 1 returning * into v_state;
  return v_state;
end; $$;

revoke execute on function qm_admin_set_construction_bonuses(bigint, bigint, bigint, bigint) from anon;
