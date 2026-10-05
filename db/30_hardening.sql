-- =====================================================================
-- ULTIMATE SQUAD — DURCISSEMENT SÉCURITÉ (signatures exactes)
-- =====================================================================
-- Retire au rôle 'anon' (non connecté) le droit d'appeler les fonctions
-- d'administration, les actions de jeu et les lectures personnelles.
-- Ne modifie AUCUNE donnée ni logique. Les connectés ('authenticated')
-- conservent tous leurs accès ; les fonctions admin restent protégées
-- en plus par qm_is_admin().
--
-- Signatures vérifiées contre la base réelle. Passe par sections.
-- =====================================================================


-- ---------------------------------------------------------------------
-- SECTION 1 — Fonctions d'administration : retirer 'anon'
-- ---------------------------------------------------------------------
revoke execute on function qm_admin_apply_note_price_one(p_id uuid) from anon;
revoke execute on function qm_admin_apply_note_prices() from anon;
revoke execute on function qm_admin_approve_proposal(p_proposal_id uuid) from anon;
revoke execute on function qm_admin_award_quiz(p_manager_id uuid, p_points integer) from anon;
revoke execute on function qm_admin_criteria(p_id uuid) from anon;
revoke execute on function qm_admin_delete_player(p_id uuid) from anon;
revoke execute on function qm_admin_open_auction(p_player_id uuid) from anon;
revoke execute on function qm_admin_pending_proposals() from anon;
revoke execute on function qm_admin_preview_prices() from anon;
revoke execute on function qm_admin_rating(p_id uuid) from anon;
revoke execute on function qm_admin_reject_proposal(p_proposal_id uuid) from anon;
revoke execute on function qm_admin_releases() from anon;
revoke execute on function qm_admin_set_bid_windows(p_cooldown integer, p_no_first integer, p_final integer) from anon;
revoke execute on function qm_admin_set_bonus_settings(p_full_day bigint, p_quiz_rate bigint) from anon;
revoke execute on function qm_admin_set_budget(p_manager_id uuid, p_budget bigint) from anon;
revoke execute on function qm_admin_set_criteria(p_id uuid, p_valeur smallint, p_performance smallint, p_regularite smallint, p_tempsjeu smallint, p_age smallint, p_championnat smallint, p_international smallint) from anon;
revoke execute on function qm_admin_set_entry_tax(p_tax bigint) from anon;
revoke execute on function qm_admin_set_market_open(p_opens_at timestamp with time zone) from anon;
revoke execute on function qm_admin_set_mercato_rules(p_max_auctions integer, p_max_daily integer, p_proposals_target integer) from anon;
revoke execute on function qm_admin_set_pass_limit(p_limit integer) from anon;
revoke execute on function qm_admin_set_phase(p_phase qm_mercato_phase) from anon;
revoke execute on function qm_admin_set_salary_cap(p_cap bigint) from anon;
revoke execute on function qm_admin_set_scout_bonus(p_bonus bigint) from anon;
revoke execute on function qm_admin_set_theme(p_accent text, p_bg text, p_title text) from anon;
revoke execute on function qm_admin_transactions() from anon;
revoke execute on function qm_admin_upsert_player(p_id uuid, p_name text, p_position qm_player_position, p_club text, p_nationality text, p_age integer, p_photo_url text, p_value bigint) from anon;


-- ---------------------------------------------------------------------
-- SECTION 2 — Actions de jeu (réservées aux connectés)
-- ---------------------------------------------------------------------
revoke execute on function qm_place_bid(p_auction_id uuid, p_amount bigint) from anon;
revoke execute on function qm_open_auction(p_player_id uuid) from anon;
revoke execute on function qm_close_auction(p_auction_id uuid) from anon;
revoke execute on function qm_trade_propose(p_to_manager uuid, p_offer_players uuid[], p_ask_players uuid[], p_cash_from_to bigint, p_message text) from anon;
revoke execute on function qm_trade_accept(p_trade_id uuid) from anon;
revoke execute on function qm_trade_refuse(p_trade_id uuid) from anon;
revoke execute on function qm_trade_cancel(p_trade_id uuid) from anon;
revoke execute on function qm_propose_player(p_player_id uuid, p_new_name text, p_new_position qm_player_position, p_new_club text, p_new_value bigint) from anon;
revoke execute on function qm_release_player(p_player_id uuid) from anon;
revoke execute on function qm_release_preview(p_player_id uuid) from anon;


-- ---------------------------------------------------------------------
-- SECTION 3 — Lectures personnelles ("mes ...")
-- ---------------------------------------------------------------------
revoke execute on function qm_my_bonuses() from anon;
revoke execute on function qm_my_dashboard() from anon;
revoke execute on function qm_my_entry_tax(p_auction_id uuid) from anon;
revoke execute on function qm_my_passes(p_auction_id uuid) from anon;
revoke execute on function qm_my_proposals() from anon;
revoke execute on function qm_my_releases() from anon;
revoke execute on function qm_my_trades() from anon;


-- ---------------------------------------------------------------------
-- SECTION 4 — Balayage des enchères expirées (cron uniquement)
-- ---------------------------------------------------------------------
revoke execute on function qm_sweep_expired_auctions() from anon;
revoke execute on function qm_sweep_expired_auctions() from authenticated;


-- =====================================================================
-- GARDÉ ACCESSIBLE À 'anon' (affichage public, NE PAS révoquer) :
--   qm_get_theme, qm_players_view, qm_auction_note_color,
--   qm_market_is_open, qm_rating, qm_rating_color, qm_player_salary...
-- =====================================================================


-- =====================================================================
-- BLOC DE CONTRÔLE (lecture seule) — à passer APRÈS
-- =====================================================================
-- Résultat idéal : ne restent QUE des fonctions d'affichage public.
select
  p.proname as fonction,
  array_agg(distinct acl.grantee::regrole::text) as accessible_par
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
cross join lateral aclexplode(p.proacl) acl
where n.nspname = 'public'
  and p.proname like 'qm_%'
  and acl.grantee::regrole::text = 'anon'
group by p.proname
order by p.proname;
