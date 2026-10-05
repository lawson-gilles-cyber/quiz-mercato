-- =====================================================================
-- ULTIMATE SQUAD — Prix de départ dérivé de la note (Étape 3)
-- =====================================================================
-- La note Mercato (/100) détermine le prix de départ du joueur, selon
-- la grille d'Audrey :
--   Note      Catégorie   Prix de départ
--   < 60      Bronze      0 - 20 M€
--   60-74     Argent      20 - 50 M€
--   75-84     Or          50 - 100 M€
--   85-89     Élite       100 - 180 M€
--   90+       Légende     180 - 220 M€
--
-- Dans chaque tranche, le prix est interpolé selon la note (une note
-- juste au-dessus du seuil = bas de la tranche, une note en haut de la
-- tranche = haut de la tranche). Prix arrondi au million.
--
-- IMPORTANT : le prix pilote le salaire (grille du script 24). Donc
-- appliquer ces prix met aussi à jour les salaires. L'application est
-- MANUELLE (fonction admin), jamais automatique, pour garder le contrôle.
--
-- À passer APRÈS 25_note_criteres.sql et 24_salary_grid.sql.
-- =====================================================================

-- ---------- Prix de départ calculé depuis la note ------------------
create or replace function qm_price_from_note(p_note smallint)
returns bigint
language sql
immutable
as $$
  -- Interpolation linéaire dans la tranche, arrondi au million.
  select (round(
    case
      when p_note >= 90 then 180 + (least(p_note,100) - 90) * (220 - 180) / 10.0   -- Légende 180-220
      when p_note >= 85 then 100 + (p_note - 85) * (180 - 100) / 5.0                -- Élite 100-180
      when p_note >= 75 then  50 + (p_note - 75) * (100 - 50) / 10.0                -- Or 50-100
      when p_note >= 60 then  20 + (p_note - 60) * (50 - 20) / 15.0                 -- Argent 20-50
      else                     0 + greatest(p_note,0) * (20 - 0) / 60.0            -- Bronze 0-20
    end
  ) * 1000000)::bigint;
$$;

-- ---------- Prévisualisation (admin) : note -> prix, sans appliquer -
create or replace function qm_admin_preview_prices()
returns table (id uuid, name text, note smallint, current_value bigint, suggested_price bigint)
language sql
security definer
set search_path = public
as $$
  select p.id, p.name, qm_rating(p.*) as note, p.current_value,
         qm_price_from_note(qm_rating(p.*)) as suggested_price
  from qm_players p
  where p.owner_id is null            -- uniquement les joueurs libres
  order by qm_rating(p.*) desc;
$$;

-- ---------- Appliquer les prix dérivés (admin, sur demande) ---------
-- Met à jour current_value ET base_value des joueurs LIBRES uniquement
-- (on ne touche pas aux joueurs déjà achetés par un manager).
create or replace function qm_admin_apply_note_prices()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare v_count integer;
begin
  if not qm_is_admin() then raise exception 'Réservé aux administrateurs'; end if;
  update qm_players p
    set current_value = qm_price_from_note(qm_rating(p.*)),
        base_value    = qm_price_from_note(qm_rating(p.*))
    where p.owner_id is null;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- ---------- Appliquer à UN joueur précis (admin) -------------------
create or replace function qm_admin_apply_note_price_one(p_id uuid)
returns qm_players
language plpgsql
security definer
set search_path = public
as $$
declare v_player qm_players; v_price bigint;
begin
  if not qm_is_admin() then raise exception 'Réservé aux administrateurs'; end if;
  select * into v_player from qm_players where id = p_id;
  if not found then raise exception 'Joueur introuvable'; end if;
  if v_player.owner_id is not null then
    raise exception 'Ce joueur appartient à un manager : son prix ne peut pas être réinitialisé.';
  end if;
  v_price := qm_price_from_note(qm_rating(v_player.*));
  update qm_players set current_value = v_price, base_value = v_price
    where id = p_id returning * into v_player;
  return v_player;
end;
$$;
