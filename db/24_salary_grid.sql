-- =====================================================================
-- ULTIMATE SQUAD — Grille salariale indexée sur le prix (Audrey v2)
-- =====================================================================
-- Le salaire ne dépend plus de la note, mais du PRIX du joueur
-- (current_value). Nouvelle grille :
--   Bronze   (< 20 M€)      -> 1 M€
--   Argent   (20 - <50 M€)  -> 3 M€
--   Or       (50 - <100 M€) -> 6 M€
--   Élite    (100 - <180 M€)-> 10 M€
--   Légende  (>= 180 M€)    -> 15 M€
--
-- Seuils nets (pas de chevauchement). Redéfinit qm_player_salary ;
-- toutes les fonctions qui l'appellent (masse salariale, contrôle de
-- plafond, dashboard) utilisent automatiquement la nouvelle grille.
--
-- À passer APRÈS 19_salary.sql.
-- =====================================================================

create or replace function qm_player_salary(p_player qm_players)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select case
    when p_player.current_value >= 180000000 then 15000000  -- Légende
    when p_player.current_value >= 100000000 then 10000000  -- Élite
    when p_player.current_value >=  50000000 then  6000000  -- Or
    when p_player.current_value >=  20000000 then  3000000  -- Argent
    else                                           1000000  -- Bronze
  end;
$$;
