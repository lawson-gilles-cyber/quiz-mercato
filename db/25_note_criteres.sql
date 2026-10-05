-- =====================================================================
-- ULTIMATE SQUAD — Note Mercato à 7 critères (Étape 1)
-- =====================================================================
-- La note d'un joueur est désormais calculée à partir de 7 critères
-- pondérés (chacun 0-100), au lieu des attributs de jeu :
--   Valeur marchande    30 %
--   Performance saison   25 %
--   Régularité           15 %
--   Temps de jeu         10 %
--   Âge / potentiel      10 %
--   Niveau championnat    5 %
--   Carrière internat.    5 %
--
-- On REDÉFINIT qm_rating (même signature) : toutes les fonctions qui
-- l'appellent continuent de marcher, mais la note vient des 7 critères.
--
-- Une estimation de départ est calculée pour les 51 joueurs existants
-- (valeur marchande déduite du prix, autres critères à 70 par défaut).
--
-- À passer APRÈS 07_attributes.sql.
-- =====================================================================

-- ---------- Colonnes des 7 critères (0-100) -------------------------
alter table qm_players add column if not exists crit_valeur      smallint default 70;
alter table qm_players add column if not exists crit_performance smallint default 70;
alter table qm_players add column if not exists crit_regularite  smallint default 70;
alter table qm_players add column if not exists crit_tempsjeu    smallint default 70;
alter table qm_players add column if not exists crit_age         smallint default 70;
alter table qm_players add column if not exists crit_championnat smallint default 70;
alter table qm_players add column if not exists crit_international smallint default 70;

-- ---------- Redéfinition de qm_rating sur les 7 critères ------------
create or replace function qm_rating(p qm_players)
returns smallint
language sql
immutable
as $$
  select round(
    coalesce(p.crit_valeur,70)       * 0.30 +
    coalesce(p.crit_performance,70)  * 0.25 +
    coalesce(p.crit_regularite,70)   * 0.15 +
    coalesce(p.crit_tempsjeu,70)     * 0.10 +
    coalesce(p.crit_age,70)          * 0.10 +
    coalesce(p.crit_championnat,70)  * 0.05 +
    coalesce(p.crit_international,70) * 0.05
  )::smallint;
$$;

-- ---------- Estimation de départ pour les joueurs existants --------
-- Valeur marchande déduite du prix (current_value) sur une échelle 0-100.
-- Barème : 0€ -> ~40, 50M -> ~70, 100M -> ~85, 180M+ -> ~95.
-- Championnat déduit du championnat réel. Les autres restent à 70,
-- à ajuster ensuite manuellement en admin.
update qm_players set
  crit_valeur = least(100, greatest(30, round(
    case
      when current_value >= 180000000 then 95
      when current_value >= 100000000 then 85 + (current_value - 100000000) / 8000000.0
      when current_value >=  50000000 then 70 + (current_value - 50000000) / 3333333.0
      when current_value >=  20000000 then 55 + (current_value - 20000000) / 2000000.0
      else 40 + current_value / 1333333.0
    end
  )))::smallint,
  crit_championnat = case championship
    when 'Premier League' then 95
    when 'Liga' then 90
    when 'Bundesliga' then 85
    when 'Serie A' then 85
    when 'Ligue 1' then 80
    when 'Primeira Liga' then 72
    when 'Süper Lig' then 68
    when 'Saudi Pro League' then 60
    else 70
  end
where crit_valeur is null or crit_valeur = 70;  -- seulement si pas déjà personnalisé

-- ---------- Paliers de couleur (pour la jauge, étape 2) ------------
-- Renvoie une catégorie de couleur selon la note, SANS révéler le chiffre.
-- rouge < 60 · jaune 60-74 · vert-clair 75-89 · vert-vif 90+
create or replace function qm_rating_color(p_note smallint)
returns text
language sql
immutable
as $$
  select case
    when p_note >= 90 then 'vert-vif'
    when p_note >= 75 then 'vert-clair'
    when p_note >= 60 then 'jaune'
    else 'rouge'
  end;
$$;

-- ---------- Admin : saisir les 7 critères d'un joueur --------------
create or replace function qm_admin_set_criteria(
  p_id uuid,
  p_valeur smallint, p_performance smallint, p_regularite smallint,
  p_tempsjeu smallint, p_age smallint, p_championnat smallint, p_international smallint
)
returns qm_players
language plpgsql
security definer
set search_path = public
as $$
declare v_player qm_players;
begin
  if not qm_is_admin() then raise exception 'Réservé aux administrateurs'; end if;
  update qm_players set
    crit_valeur = greatest(0, least(100, p_valeur)),
    crit_performance = greatest(0, least(100, p_performance)),
    crit_regularite = greatest(0, least(100, p_regularite)),
    crit_tempsjeu = greatest(0, least(100, p_tempsjeu)),
    crit_age = greatest(0, least(100, p_age)),
    crit_championnat = greatest(0, least(100, p_championnat)),
    crit_international = greatest(0, least(100, p_international))
  where id = p_id returning * into v_player;
  if not found then raise exception 'Joueur introuvable'; end if;
  return v_player;
end;
$$;

-- ---------- Admin : note détaillée d'un joueur (les 7 + total) ------
create or replace function qm_admin_criteria(p_id uuid)
returns table (
  valeur smallint, performance smallint, regularite smallint, tempsjeu smallint,
  age smallint, championnat smallint, international smallint, note_finale smallint
)
language sql
security definer
set search_path = public
as $$
  select crit_valeur, crit_performance, crit_regularite, crit_tempsjeu,
         crit_age, crit_championnat, crit_international, qm_rating(p.*)
  from qm_players p where p.id = p_id;
$$;
