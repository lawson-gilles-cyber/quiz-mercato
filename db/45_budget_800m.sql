-- =====================================================================
-- ULTIMATE SQUAD — Budget de départ à 800 M€
-- =====================================================================
-- Le budget initial passe de 1 milliard à 800 M€ (+ bonus, qui viennent
-- s'ajouter par-dessus via le système de bonus existant).
--
-- 1. Nouveau défaut pour les futurs comptes.
-- 2. Alignement des comptes existants encore au montant initial
--    (1 milliard) et n'ayant fait aucune opération.
--
-- ⚠️ N'aligne QUE les comptes vierges (budget = 1 000 000 000 pile et
--    aucun joueur, aucune enchère), pour ne pas écraser un budget déjà
--    modifié par le jeu. À passer après 44_construction_bonus.sql.
-- =====================================================================

-- 1. Nouveau défaut
alter table qm_managers alter column budget set default 800000000;

-- 2. Alignement prudent des comptes vierges encore à 1 milliard
update qm_managers m set budget = 800000000
where m.budget = 1000000000
  and m.budget_locked = 0
  and not exists (select 1 from qm_players p where p.owner_id = m.id)
  and not exists (select 1 from qm_bonuses b where b.manager_id = m.id);
