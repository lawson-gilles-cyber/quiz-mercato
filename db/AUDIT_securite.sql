-- =====================================================================
-- ULTIMATE SQUAD — AUDIT DE SÉCURITÉ (lecture seule, ne modifie rien)
-- =====================================================================
-- Passe chaque bloc SÉPARÉMENT dans le SQL Editor et lis le rapport.
-- Aucune de ces requêtes n'écrit en base — c'est un diagnostic.
-- =====================================================================


-- =====================================================================
-- BLOC 1 — RLS activé sur toutes les tables qm_ ? (POINT CRITIQUE)
-- =====================================================================
-- Colonne rls_active : true attendu PARTOUT. Toute table à false est
-- une porte ouverte : lisible/modifiable directement via la clé anon.
select
  c.relname               as table_name,
  c.relrowsecurity        as rls_active,
  case when c.relrowsecurity then '✓ OK' else '✗ DANGER : RLS désactivé' end as verdict
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relkind = 'r'
  and c.relname like 'qm_%'
order by c.relrowsecurity asc, c.relname;   -- les DANGER en premier


-- =====================================================================
-- BLOC 2 — Chaque table a-t-elle des POLITIQUES RLS ? (POINT CRITIQUE)
-- =====================================================================
-- Une table avec RLS activé MAIS sans politique bloque tout (ou, pire,
-- si une policy est 'using(true)' en write, laisse tout passer).
-- On veut : chaque table sensible a au moins une policy de SELECT,
-- et AUCUNE policy permissive d'UPDATE/INSERT/DELETE côté public.
select
  schemaname,
  tablename,
  policyname,
  cmd            as commande,       -- SELECT / INSERT / UPDATE / DELETE / ALL
  roles,
  qual           as condition_lecture,
  with_check     as condition_ecriture
from pg_policies
where schemaname = 'public'
  and tablename like 'qm_%'
order by tablename, cmd;


-- =====================================================================
-- BLOC 2 bis — Tables SANS AUCUNE politique (à repérer)
-- =====================================================================
-- Ces tables ont peut-être le RLS activé mais aucune règle : soit tout
-- est bloqué (le jeu ne marche pas), soit — si RLS off — tout est ouvert.
select c.relname as table_sans_policy
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r' and c.relname like 'qm_%'
  and not exists (
    select 1 from pg_policies p
    where p.schemaname = 'public' and p.tablename = c.relname
  )
order by c.relname;


-- =====================================================================
-- BLOC 3 — Politiques d'ÉCRITURE dangereuses (POINT CRITIQUE)
-- =====================================================================
-- On cherche les policies qui autorisent INSERT/UPDATE/DELETE avec une
-- condition trop permissive (true) pour le rôle anon/authenticated.
-- Idéalement, l'écriture directe sur qm_managers (budget, points, admin)
-- ne devrait PAS être permise : tout passe par les fonctions definer.
select
  tablename,
  policyname,
  cmd,
  roles,
  with_check,
  case
    when with_check = 'true' then '✗ DANGER : écriture permissive'
    when with_check is null and cmd in ('INSERT','UPDATE','ALL') then '⚠ à vérifier'
    else '✓ conditionnée'
  end as verdict
from pg_policies
where schemaname = 'public'
  and tablename like 'qm_%'
  and cmd in ('INSERT','UPDATE','DELETE','ALL')
order by verdict, tablename;


-- =====================================================================
-- BLOC 4 — qm_is_admin() est-elle infalsifiable ? (POINT CRITIQUE)
-- =====================================================================
-- On veut voir sa définition : elle DOIT lire is_admin depuis
-- qm_managers via auth.uid(), et ne JAMAIS accepter de paramètre client.
select pg_get_functiondef('qm_is_admin'::regproc) as definition_is_admin;


-- =====================================================================
-- BLOC 5 — Toutes les fonctions sensibles sont-elles SECURITY DEFINER ?
-- =====================================================================
-- Les fonctions qui modifient l'état (place_bid, close_auction, trade,
-- release, admin_*) doivent être SECURITY DEFINER + search_path fixé.
-- security_type = 'DEFINER' attendu ; INVOKER sur une fonction d'écriture
-- est suspect.
select
  p.proname                                          as fonction,
  case when p.prosecdef then 'DEFINER' else 'INVOKER' end as securite,
  case when p.prosecdef then '✓' else '⚠ INVOKER (à vérifier)' end as verdict,
  pg_get_function_identity_arguments(p.oid)          as arguments
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname like 'qm_%'
order by p.prosecdef asc, p.proname;   -- les INVOKER en premier


-- =====================================================================
-- BLOC 6 — Les fonctions definer ont-elles un search_path fixé ?
-- =====================================================================
-- Sans 'set search_path = public', une fonction DEFINER est vulnérable
-- au détournement de schéma. On veut voir proconfig contenir search_path.
select
  p.proname as fonction,
  p.proconfig as config,
  case when p.proconfig::text like '%search_path%' then '✓ search_path fixé'
       else '✗ DANGER : search_path non fixé' end as verdict
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname like 'qm_%'
  and p.prosecdef = true            -- uniquement les DEFINER
order by verdict, p.proname;


-- =====================================================================
-- BLOC 7 — Qui est admin ? (POINT OPÉRATIONNEL)
-- =====================================================================
-- Avant la saison : vérifier qu'aucun compte n'est admin par erreur.
-- Attendu : 1 ou 2 comptes admin identifiés, tous les managers réels
-- en is_admin = false.
select
  display_name,
  is_admin,
  budget,
  season_points,
  created_at
from qm_managers
order by is_admin desc, created_at;


-- =====================================================================
-- BLOC 8 — Grants exposés à anon (POINT DE FORME)
-- =====================================================================
-- Quelles fonctions qm_ sont exécutables par le rôle anonyme ?
-- Les fonctions d'AFFICHAGE public (get_theme, players_view) : OK.
-- Une fonction admin_* exécutable par anon = DANGER.
select
  p.proname as fonction,
  array_agg(distinct acl.grantee::regrole::text) as accessible_par
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
cross join lateral aclexplode(p.proacl) acl
where n.nspname = 'public'
  and p.proname like 'qm_%'
  and acl.grantee::regrole::text in ('anon','authenticated','public')
group by p.proname
order by p.proname;
