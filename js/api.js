// =====================================================================
// QUIZ MERCATO — Couche API (Supabase, Vanilla JS)
// =====================================================================
// Aucune écriture directe : tout passe par les RPC côté DB.
// =====================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

// À renseigner avec tes clés (projet dédié, pas celui de FHAF)
const SUPABASE_URL = 'https://jfqxxlllqlynvllfsvdt.supabase.co';
const SUPABASE_ANON = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImpmcXh4bGxscWx5bnZsbGZzdmR0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA3NjY1NDYsImV4cCI6MjA5NjM0MjU0Nn0.W0BEHCjZfgtLvSs9RoOsYGTOlGmcMhgOskYVwSe5p2I';

export const sb = createClient(SUPABASE_URL, SUPABASE_ANON);

// ---------- Formatage argent (bigint euros → "180,0 M€") -------------
export function fmtMoney(euros) {
  const v = Number(euros);
  if (v >= 1e9) return (v / 1e9).toFixed(2).replace('.', ',') + ' Md€';
  if (v >= 1e6) return (v / 1e6).toFixed(1).replace('.', ',') + ' M€';
  if (v >= 1e3) return Math.round(v / 1e3) + ' k€';
  return v + ' €';
}

// ---------- Rareté (miroir de la fonction SQL, pour l'affichage) -----
export function rarity(value) {
  const v = Number(value);
  if (v >= 100e6) return { key: 'legend',   stars: 5, label: 'Légende' };
  if (v >=  60e6) return { key: 'platinum', stars: 4, label: 'Platine' };
  if (v >=  30e6) return { key: 'gold',     stars: 3, label: 'Or' };
  if (v >=  10e6) return { key: 'silver',   stars: 2, label: 'Argent' };
  return                 { key: 'bronze',   stars: 1, label: 'Bronze' };
}

export function minIncrement(value) {
  const v = Number(value);
  if (v > 150e6) return 15e6;
  if (v > 100e6) return 10e6;
  if (v >  60e6) return  5e6;
  if (v >  30e6) return  2e6;
  if (v >  10e6) return  1e6;
  return 500e3;
}

// ---------- AUTH ------------------------------------------------------
export async function signIn(email, password) {
  return sb.auth.signInWithPassword({ email, password });
}
export async function signUp(email, password, displayName, teamName) {
  const { data, error } = await sb.auth.signUp({ email, password });
  if (error) return { error };
  // Crée la fiche manager (autorisé par la policy "create own manager")
  const { error: mErr } = await sb.from('qm_managers').insert({
    auth_user_id: data.user.id,
    display_name: displayName,
    team_name: teamName || null
  });
  return { data, error: mErr };
}
export async function currentManager() {
  const { data: { user } } = await sb.auth.getUser();
  if (!user) return null;
  const { data } = await sb.from('qm_managers')
    .select('*').eq('auth_user_id', user.id).single();
  return data;
}

// ---------- LECTURES --------------------------------------------------
export async function listPlayers(filters = {}) {
  // Utilise la vue qui renvoie note_color (toujours) et note (si possédé)
  const { data, error } = await sb.rpc('qm_players_view');
  let rows = (error || !data) ? [] : data.map(p => ({
    ...p,
    position: p.pos,
    owner: p.owner_name ? { display_name: p.owner_name } : null
  }));
  if (filters.position) rows = rows.filter(p => p.position === filters.position);
  if (filters.status)   rows = rows.filter(p => p.status === filters.status);
  if (filters.search)   rows = rows.filter(p => p.name.toLowerCase().includes(filters.search.toLowerCase()));
  return rows;
}

// ---------- Enchères programmées (planifiées pour plus tard) ----------
export async function listScheduledAuctions() {
  const { data, error } = await sb.from('qm_auctions')
    .select('*, player:qm_players(*)')
    .eq('status', 'scheduled')
    .order('starts_at', { ascending: true });
  if (error) { console.warn('listScheduledAuctions:', error.message); return []; }
  return data ?? [];
}
export async function scheduleAuction(playerId, startsAtISO) {
  return sb.rpc('qm_admin_schedule_auction_logged', { p_player_id: playerId, p_starts_at: startsAtISO });
}
export async function cancelScheduledAuction(auctionId) {
  return sb.rpc('qm_admin_cancel_scheduled', { p_auction_id: auctionId });
}
// Annuler une enchère EN COURS (admin, avec remboursement du meneur).
export async function adminCancelAuction(auctionId) {
  return sb.rpc('qm_admin_cancel_auction', { p_auction_id: auctionId });
}
// Corriger le prix de départ d'une enchère (si aucune offre encore).
export async function adminFixAuctionPrice(auctionId, newPrice) {
  return sb.rpc('qm_admin_fix_auction_price', { p_auction_id: auctionId, p_new_price: newPrice });
}
// Déclenche le démarrage des enchères programmées dues (filet de sécurité).
export async function sweepDueAuctions() {
  const { data } = await sb.rpc('qm_sweep_due_auctions');
  return data ?? 0;
}
// Forcer le démarrage d'une enchère programmée précise (admin).
export async function adminStartScheduled(auctionId) {
  return sb.rpc('qm_admin_start_scheduled', { p_auction_id: auctionId });
}

export async function listOpenAuctions() {
  // Requête principale ROBUSTE : enchères + joueur (jointure sûre) uniquement.
  // On évite les jointures top_bidder/bids qui peuvent casser toute la requête.
  const { data, error } = await sb.from('qm_auctions')
    .select('*, player:qm_players(*)')
    .eq('status', 'open')
    .order('ends_at', { ascending: true });
  if (error) { console.warn('listOpenAuctions:', error.message); return []; }
  const auctions = data ?? [];
  if (!auctions.length) return [];

  // Nombre de managers intéressés : récupéré à part, sans bloquer l'affichage.
  let bidsByAuction = {};
  try {
    const ids = auctions.map(a => a.id);
    const { data: bids } = await sb.from('qm_bids')
      .select('auction_id, manager_id').in('auction_id', ids);
    (bids ?? []).forEach(b => {
      (bidsByAuction[b.auction_id] ||= new Set()).add(b.manager_id);
    });
  } catch (e) { /* si ça échoue, interest = 0, les enchères s'affichent quand même */ }

  // Nom du meilleur enchérisseur : à part aussi, facultatif.
  let nameById = {};
  try {
    const bidderIds = [...new Set(auctions.map(a => a.top_bidder_id).filter(Boolean))];
    if (bidderIds.length) {
      const { data: mgrs } = await sb.from('qm_managers')
        .select('id, display_name').in('id', bidderIds);
      (mgrs ?? []).forEach(m => { nameById[m.id] = m.display_name; });
    }
  } catch (e) { /* facultatif */ }

  return auctions.map(a => ({
    ...a,
    interest: bidsByAuction[a.id] ? bidsByAuction[a.id].size : 0,
    top_bidder: a.top_bidder_id ? { display_name: nameById[a.top_bidder_id] || '—' } : null
  }));
}

export async function myTeam(managerId) {
  const { data } = await sb.from('qm_players')
    .select('*').eq('owner_id', managerId)
    .order('current_value', { ascending: false });
  return data ?? [];
}

// Recherche de joueurs par nom (pour le sélecteur d'alerte, etc.).
export async function searchPlayersByName(q, limit = 8) {
  const term = (q || '').trim();
  if (term.length < 2) return [];
  const { data } = await sb.from('qm_players')
    .select('id, name, first_name, club, position, current_value')
    .ilike('name', `%${term}%`)
    .order('current_value', { ascending: false })
    .limit(limit);
  return data ?? [];
}

export async function leaderboard() {
  // division_id peut ne pas encore exister (script 80 non passé) : on retente sans.
  let { data, error } = await sb.from('qm_managers')
    .select('id, display_name, team_name, color_primary, color_secondary, season_points, budget, budget_locked, is_admin, coach_of, division_id')
    .order('season_points', { ascending: false });
  if (error) {
    ({ data } = await sb.from('qm_managers')
      .select('id, display_name, team_name, color_primary, color_secondary, season_points, budget, budget_locked, is_admin, coach_of')
      .order('season_points', { ascending: false }));
  }
  // Seuls les compétiteurs : on exclut les admins et les coachs (pas d'effectif propre).
  return (data ?? []).filter(m => !m.is_admin && !m.coach_of);
}

export async function transferHistory(playerId) {
  const { data } = await sb.from('qm_transfers')
    .select('*, from:qm_managers!qm_transfers_from_manager_fkey(display_name), to:qm_managers!qm_transfers_to_manager_fkey(display_name)')
    .eq('player_id', playerId)
    .order('created_at', { ascending: false });
  return data ?? [];
}
export async function recentTransfers(limit = 30) {
  // Fil d'actualité : tous les mouvements récents, avec joueur et managers
  const { data } = await sb.from('qm_transfers')
    .select('*, player:qm_players(name, club, position), from:qm_managers!qm_transfers_from_manager_fkey(display_name), to:qm_managers!qm_transfers_to_manager_fkey(display_name)')
    .order('created_at', { ascending: false })
    .limit(limit);
  return data ?? [];
}
export async function myTransfers(teamId) {
  // Mes transferts : achats (to_manager = moi) et ventes/échanges (from = moi).
  if (!teamId) return [];
  const { data } = await sb.from('qm_transfers')
    .select('*, player:qm_players(name, club, position), from:qm_managers!qm_transfers_from_manager_fkey(display_name), to:qm_managers!qm_transfers_to_manager_fkey(display_name)')
    .or(`to_manager.eq.${teamId},from_manager.eq.${teamId}`)
    .order('created_at', { ascending: false });
  return data ?? [];
}
export async function myNotifications() {
  const { data } = await sb.rpc('qm_my_notifications');
  return data ?? [];
}

// ---------- ÉCRITURES (uniquement via RPC) ---------------------------
export async function placeBid(auctionId, amount) {
  return sb.rpc('qm_place_bid', { p_auction_id: auctionId, p_amount: amount });
}
export async function openAuction(playerId) {
  return sb.rpc('qm_open_auction', { p_player_id: playerId });
}

// ---------- Enchère automatique (proxy bid) -------------------------
export async function setAutoBid(auctionId, maxAmount) {
  return sb.rpc('qm_autobid_set', { p_auction_id: auctionId, p_max: maxAmount });
}
export async function cancelAutoBid(auctionId) {
  return sb.rpc('qm_autobid_cancel', { p_auction_id: auctionId });
}
export async function myAutoBid(auctionId) {
  const { data } = await sb.rpc('qm_my_autobid', { p_auction_id: auctionId });
  return data ?? null;  // montant max, ou null si pas d'enchère auto
}

// ---------- Journal des offres + suivi d'enchères (vague 1) ----------
export async function auctionBids(auctionId) {
  const { data } = await sb.rpc('qm_auction_bids', { p_auction_id: auctionId });
  return data ?? [];
}
export async function watchToggle(auctionId) {
  return sb.rpc('qm_watch_toggle', { p_auction_id: auctionId });
}
export async function myWatchlist() {
  const { data } = await sb.rpc('qm_my_watchlist');
  // renvoie un Set d'IDs d'enchères suivies, pratique pour l'affichage
  return new Set((data ?? []).map(r => r.auction_id));
}

// ---------- Alertes personnalisées (push ciblé) ----------
// Crée une alerte : kind 'player' (p_player_id requis) ou 'position' (p_position requis).
export async function alertCreate({ kind, playerId = null, position = null, maxPrice }) {
  return sb.rpc('qm_alert_create', {
    p_kind: kind,
    p_player_id: playerId,
    p_position: position,
    p_max_price: maxPrice,
  });
}
export async function myAlerts() {
  const { data } = await sb.rpc('qm_my_alerts');
  return data ?? [];
}
export async function alertDelete(alertId) {
  return sb.rpc('qm_alert_delete', { p_alert_id: alertId });
}

// ---------- ADMIN (RPC réservées, contrôle is_admin côté serveur) ----
export async function amIAdmin() {
  const { data } = await sb.rpc('qm_is_admin');
  return data === true;
}
export async function adminUpsertPlayer(p) {
  // p : { id?, first_name?, name, position, club, nationality, age, photo_url, value, championship }
  return sb.rpc('qm_admin_upsert_player', {
    p_id: p.id ?? null,
    p_first_name: p.first_name ?? null,
    p_name: p.name,
    p_position: p.position,
    p_club: p.club ?? null,
    p_nationality: p.nationality ?? null,
    p_age: p.age ?? null,
    p_photo_url: p.photo_url ?? null,
    p_value: p.value,
    p_championship: p.championship ?? null
  });
}
export async function adminDeletePlayer(id, reason) {
  return sb.rpc('qm_admin_delete_player', { p_player_id: id, p_reason: reason ?? null });
}
export async function adminManagerSquad(managerId) {
  const { data } = await sb.rpc('qm_admin_manager_squad', { p_manager_id: managerId });
  return data ?? [];
}
// ---------- Profil public d'un manager ----------------------------
// Classement avec évolution ▲▼ depuis la dernière journée clôturée.
export async function rankingWithTrend() {
  const { data } = await sb.rpc('qm_ranking_with_trend');
  return data ?? [];
}
export async function managerPublicCard(managerId) {
  const { data } = await sb.rpc('qm_manager_public_card', { p_manager_id: managerId });
  return (data && data[0]) ? data[0] : null;
}
export async function managerProfile(managerId) {
  const { data } = await sb.rpc('qm_manager_profile', { p_manager_id: managerId });
  return (data && data[0]) ? data[0] : null;
}
export async function publicSquad(managerId) {
  const { data } = await sb.rpc('qm_public_squad', { p_manager_id: managerId });
  return data ?? [];
}
export async function managerAwards(managerId) {
  const { data } = await sb.rpc('qm_manager_awards', { p_manager_id: managerId });
  return data ?? [];
}
// Historique enrichi (vague 4)
export async function managerHistory(managerId) {
  const { data } = await sb.rpc('qm_manager_history', { p_manager_id: managerId });
  return data ?? [];
}
export async function managerBalance(managerId) {
  const { data } = await sb.rpc('qm_manager_balance', { p_manager_id: managerId });
  return (data && data[0]) ? data[0] : null;
}
export async function managerBestDeal(managerId) {
  const { data } = await sb.rpc('qm_manager_best_deal', { p_manager_id: managerId });
  return (data && data[0]) ? data[0] : null;
}
// Bilan de fin de mercato (carte récap partageable).
export async function managerMercatoSummary(managerId) {
  const { data } = await sb.rpc('qm_manager_mercato_summary', { p_manager_id: managerId });
  return (data && data[0]) ? data[0] : null;
}

// Comparateur avant enchère : joueur visé + mes joueurs au même poste.
export async function compareTarget(playerId) {
  const { data } = await sb.rpc('qm_player_compare_target', { p_player_id: playerId });
  return (data && data[0]) ? data[0] : null;
}
export async function mySquadAtPosition(playerId) {
  const { data } = await sb.rpc('qm_my_squad_at_position', { p_player_id: playerId });
  return data ?? [];
}
// Divisions (vague 4)
export async function divisionsList() {
  const { data } = await sb.rpc('qm_divisions_list');
  return data ?? [];
}
export async function divisionStandings(divisionId) {
  const { data } = await sb.rpc('qm_division_standings', { p_division_id: divisionId });
  return data ?? [];
}
export async function myDivision() {
  const { data } = await sb.rpc('qm_my_division');
  return (data && data[0]) ? data[0] : null;
}
export async function adminUpsertDivision(level, label, capacity) {
  return sb.rpc('qm_admin_upsert_division', { p_level: level, p_label: label, p_capacity: capacity });
}
export async function adminAssignDivision(managerId, divisionId) {
  return sb.rpc('qm_admin_assign_division', { p_manager_id: managerId, p_division_id: divisionId });
}
export async function adminApplyPromotionRelegation(count = 2) {
  return sb.rpc('qm_admin_apply_promotion_relegation', { p_count: count });
}
// Réglages publics (règles vivantes)
export async function publicSettings() {
  const { data } = await sb.rpc('qm_public_settings');
  return (data && data[0]) ? data[0] : null;
}
// ---------- Annonce / message de l'organisation ----------
// ---------- Mur des records (temple de la renommée) ----------
export async function seasonRecords() {
  const { data } = await sb.rpc('qm_season_records');
  return data ?? [];
}
export async function getAnnouncement() {
  const { data } = await sb.rpc('qm_announcement');
  const row = (data && data[0]) ? data[0] : null;
  return (row && row.text) ? row : null;   // null si pas d'annonce / expirée
}
export async function adminSetAnnouncement(text, untilISO) {
  return sb.rpc('qm_admin_set_announcement', { p_text: text ?? null, p_until: untilISO ?? null });
}
// Hommage / distinction (ex. Ballon d'Or) — bannière accueil + badge fiche.
export async function getHonor() {
  const { data } = await sb.rpc('qm_honor');
  const row = (data && data[0]) ? data[0] : null;
  return (row && row.title) ? row : null;   // null si pas d'hommage / expiré
}
export async function adminSetHonor({ active, title, playerId = null, untilISO = null }) {
  return sb.rpc('qm_admin_set_honor', {
    p_active: active, p_title: title ?? null, p_player_id: playerId, p_until: untilISO ?? null,
  });
}
// Commentaires sur les transferts (chambrage)
export async function postComment(transferId, body) {
  return sb.rpc('qm_post_comment', { p_transfer_id: transferId, p_body: body });
}
export async function deleteComment(commentId) {
  return sb.rpc('qm_delete_comment', { p_comment_id: commentId });
}
export async function transferComments(transferId) {
  const { data } = await sb.rpc('qm_transfer_comments', { p_transfer_id: transferId });
  return data ?? [];
}
export async function commentCounts(ids) {
  if (!ids || !ids.length) return {};
  const { data } = await sb.rpc('qm_comment_counts', { p_ids: ids });
  const out = {};
  (data ?? []).forEach(r => { out[r.transfer_id] = r.n; });
  return out;
}
// Mode saison / archives
export async function adminCloseSeason(label) {
  return sb.rpc('qm_admin_close_season', { p_label: label ?? null });
}
export async function seasonsList() {
  const { data } = await sb.rpc('qm_seasons_list');
  return data ?? [];
}
export async function seasonDetail(seasonId) {
  const { data } = await sb.rpc('qm_season_detail', { p_season_id: seasonId });
  return data ?? [];
}
// Badges (gamification)
export async function allBadges() {
  const { data } = await sb.rpc('qm_all_badges');
  return data ?? [];
}
export async function managerBadges(managerId) {
  const { data } = await sb.rpc('qm_manager_badges', { p_manager_id: managerId });
  return data ?? [];
}
export async function adminSetValue(id, value) {
  return sb.rpc('qm_admin_set_value_logged', { p_id: id, p_value: value });
}
export async function adminBulkValues(data) {
  // data : [{name, value}, ...]
  return sb.rpc('qm_admin_bulk_values', { p_data: data });
}
export async function adminOpenAuction(playerId) {
  return sb.rpc('qm_admin_open_auction_logged', { p_player_id: playerId });
}
// Enchère « éclair » : durée courte choisie (heures).
export async function adminOpenAuctionDuration(playerId, hours) {
  return sb.rpc('qm_admin_open_auction_duration_logged', { p_player_id: playerId, p_hours: hours });
}
export async function adminSetPhase(phase) {
  return sb.rpc('qm_admin_set_phase', { p_phase: phase });
}
export async function adminSetBudget(managerId, budget) {
  return sb.rpc('qm_admin_set_budget', { p_manager_id: managerId, p_budget: budget });
}
export async function adminSetAttributes(id, a) {
  return sb.rpc('qm_admin_set_attributes', {
    p_id: id,
    p_finition: a.finition, p_creativite: a.creativite, p_vitesse: a.vitesse,
    p_intelligence: a.intelligence, p_physique: a.physique, p_defense: a.defense,
    p_regularite: a.regularite
  });
}
export async function adminRating(id) {
  const { data } = await sb.rpc('qm_admin_rating', { p_id: id });
  return data;
}

// ---------- PERFORMANCES / POINTS (admin) ---------------------------
export async function ownedPlayers() {
  const { data } = await sb.rpc('qm_owned_players');
  return data ?? [];
}
export async function adminRecordPerformance(perf) {
  return sb.rpc('qm_admin_record_performance', {
    p_player_id: perf.player_id, p_matchday: perf.matchday, p_minutes: perf.minutes,
    p_goals: perf.goals, p_assists: perf.assists, p_clean_sheet: perf.clean_sheet,
    p_penalty_saved: perf.penalty_saved, p_yellow: perf.yellow, p_red: perf.red,
    p_own_goals: perf.own_goals, p_penalty_missed: perf.penalty_missed,
    p_motm: perf.motm, p_team_result: perf.team_result
  });
}

// ---------- ÉCHANGES ENTRE MANAGERS ---------------------------------
export async function listManagers() {
  const { data } = await sb.from('qm_managers').select('id, display_name, team_name, is_admin, coach_of').order('display_name');
  return data ?? [];
}
// Suppression définitive d'un manager (admin) : libère ses joueurs, bloque s'il
// mène une enchère en cours, puis efface le compte (auth + données liées).
export async function adminDeleteManager(managerId) {
  return sb.rpc('qm_admin_delete_manager', { p_manager_id: managerId });
}
export async function proposeTrade(t) {
  return sb.rpc('qm_trade_propose', {
    p_to_manager: t.to_manager,
    p_offer_players: t.offer_players,
    p_ask_players: t.ask_players,
    p_cash_from_to: t.cash_from_to,
    p_message: t.message ?? null
  });
}
export async function myTrades() {
  const { data } = await sb.rpc('qm_my_trades');
  return data ?? [];
}
// Journal public des échanges conclus (acceptés).
export async function tradesLog(limit = 50) {
  const { data } = await sb.rpc('qm_trades_log', { p_limit: limit });
  return data ?? [];
}
export async function acceptTrade(id){ return sb.rpc('qm_trade_accept', { p_trade_id: id }); }
export async function refuseTrade(id){ return sb.rpc('qm_trade_refuse', { p_trade_id: id }); }
export async function cancelTrade(id){ return sb.rpc('qm_trade_cancel', { p_trade_id: id }); }
// Place de marché (vitrine des échanges)
export async function setForTrade(playerId, on, price){
  return sb.rpc('qm_set_for_trade', { p_player_id: playerId, p_on: on, p_price: (price ?? null) });
}
export async function marketListings(){
  const { data } = await sb.rpc('qm_market_listings');
  return data ?? [];
}
// Offres directes sur la vitrine (cash et/ou un joueur).
export async function listingMakeOffer({ listedPlayerId, offerPlayerId = null, cash = 0, message = null }){
  return sb.rpc('qm_listing_make_offer', {
    p_listed_player_id: listedPlayerId, p_offer_player_id: offerPlayerId,
    p_cash: cash, p_message: message,
  });
}
export async function listingOffersReceived(){
  const { data } = await sb.rpc('qm_listing_offers_received');
  return data ?? [];
}
export async function listingOffersSent(){
  const { data } = await sb.rpc('qm_listing_offers_sent');
  return data ?? [];
}
export async function listingAcceptOffer(tradeId){
  return sb.rpc('qm_listing_accept_offer', { p_trade_id: tradeId });
}

// ---------- PRÊTS DE JOUEURS (vague 2) ------------------------------
export async function proposeLoan(l) {
  return sb.rpc('qm_loan_propose', {
    p_player_id: l.player_id, p_borrower_id: l.borrower_id,
    p_days: l.days, p_fee: l.fee ?? 0, p_message: l.message ?? null,
    p_option_price: l.option_price ?? 0, p_firm: l.firm ?? false
  });
}
export async function acceptLoan(id){ return sb.rpc('qm_loan_accept', { p_loan_id: id }); }
export async function refuseLoan(id){ return sb.rpc('qm_loan_refuse', { p_loan_id: id }); }
export async function cancelLoan(id){ return sb.rpc('qm_loan_cancel', { p_loan_id: id }); }
export async function returnLoan(id){ return sb.rpc('qm_loan_return', { p_loan_id: id }); }
export async function buyLoanOption(id){ return sb.rpc('qm_loan_buy_option', { p_loan_id: id }); }
export async function myLoans() {
  const { data } = await sb.rpc('qm_my_loans');
  return data ?? [];
}

// ---------- COTE DYNAMIQUE (admin, vague 2) -------------------------
export async function adminRecalcValues(){ return sb.rpc('qm_admin_recalc_values'); }
export async function adminAdjustValue(playerId, deltaPct){
  return sb.rpc('qm_admin_adjust_value', { p_player_id: playerId, p_delta_pct: deltaPct });
}
export async function adminPreviewDemand(){
  const { data } = await sb.rpc('qm_admin_preview_demand');
  return data ?? [];
}
export async function positionScarcity(){
  const { data } = await sb.rpc('qm_position_scarcity');
  return data ?? [];
}

// ---------- Récap de journée ----------------------------------------
export async function recap(hours = 24){
  const { data } = await sb.rpc('qm_recap', { p_hours: hours });
  return data ?? null;
}

// ---------- Éditeur de barèmes (réglages consolidés) ----------------
export async function adminSettings(){
  const { data } = await sb.rpc('qm_admin_settings');
  return data ?? null;
}
export async function adminSetSettings(obj){
  return sb.rpc('qm_admin_set_settings', { p: obj });
}

// ---------- COMMISSIONS / MARCHÉ ------------------------------------
export async function estimateCommission(managerId, playerId) {
  const { data } = await sb.rpc('qm_estimate_commission', {
    p_manager_id: managerId, p_player_id: playerId
  });
  return data ?? 0;
}
export async function marketIsOpen() {
  const { data } = await sb.rpc('qm_market_is_open');
  return data === true;
}
export async function adminSetMarketOpen(isoDate) {
  return sb.rpc('qm_admin_set_market_open', { p_opens_at: isoDate });
}
export async function estimateTradeCommissions(tradeId) {
  const { data } = await sb.rpc('qm_estimate_trade_commissions', { p_trade_id: tradeId });
  return (data && data[0]) ? data[0] : { from_pays:0, to_pays:0, from_gets:0, to_gets:0 };
}
export async function myPasses(auctionId) {
  const { data } = await sb.rpc('qm_my_passes', { p_auction_id: auctionId });
  return data ?? 0;
}

// ---------- DÉNICHAGE DE JOUEURS ------------------------------------
export async function proposePlayer(p) {
  // p : { player_id?, new_first_name?, new_name?, new_position?, new_club?, new_value?, new_championship? }
  return sb.rpc('qm_propose_player', {
    p_player_id: p.player_id ?? null,
    p_new_first_name: p.new_first_name ?? null,
    p_new_name: p.new_name ?? null,
    p_new_position: p.new_position ?? null,
    p_new_club: p.new_club ?? null,
    p_new_value: p.new_value ?? null,
    p_new_championship: p.new_championship ?? null
  });
}
export async function myProposals() {
  const { data } = await sb.rpc('qm_my_proposals');
  return data ?? [];
}
// Double approbation Manager+Coach
export async function teamDrafts() {
  const { data } = await sb.rpc('qm_team_drafts');
  return data ?? [];
}
export async function proposalApproveSubmit(id) {
  return sb.rpc('qm_proposal_approve_submit', { p_proposal_id: id });
}
export async function proposalDiscardDraft(id) {
  return sb.rpc('qm_proposal_discard_draft', { p_proposal_id: id });
}
export async function adminPendingProposals() {
  const { data } = await sb.rpc('qm_admin_pending_proposals');
  return data ?? [];
}
// ---------- Validation du marché (proposition Audrey) -------------
export async function adminProposals(status) {
  const { data } = await sb.rpc('qm_admin_proposals', { p_status: status ?? null });
  return data ?? [];
}
export async function adminProposalCounts() {
  const { data } = await sb.rpc('qm_admin_proposal_counts');
  return (data && data[0]) ? data[0] : { pending: 0, approved: 0, needs_changes: 0 };
}
export async function adminProposalsHistory(limit = 100) {
  const { data } = await sb.rpc('qm_admin_proposals_history', { p_limit: limit });
  return data ?? [];
}
export async function proposalDuplicates(id) {
  const { data } = await sb.rpc('qm_proposal_duplicates', { p_proposal_id: id });
  return data ?? [];
}
export async function adminApproveProposal(id) {
  return sb.rpc('qm_admin_approve_proposal', { p_proposal_id: id });
}
export async function adminPublishProposal(id) {
  return sb.rpc('qm_admin_publish_proposal', { p_proposal_id: id });
}
export async function adminRequestChanges(id, reason) {
  return sb.rpc('qm_admin_request_changes', { p_proposal_id: id, p_reason: reason });
}
export async function adminRejectProposal(id, reason) {
  return sb.rpc('qm_admin_reject_proposal', { p_proposal_id: id, p_reason: reason ?? null });
}
// ---------- Manager : corriger / annuler une proposition ----------
export async function resubmitProposal(p) {
  // p : { id, new_first_name, new_name, new_position, new_club, new_value, new_championship }
  return sb.rpc('qm_resubmit_proposal', {
    p_proposal_id: p.id,
    p_new_first_name: p.new_first_name ?? null,
    p_new_name: p.new_name ?? null,
    p_new_position: p.new_position ?? null,
    p_new_club: p.new_club ?? null,
    p_new_value: p.new_value ?? null,
    p_new_championship: p.new_championship ?? null
  });
}
export async function cancelProposal(id) {
  return sb.rpc('qm_cancel_proposal', { p_proposal_id: id });
}
export async function adminTransactions() {
  const { data } = await sb.rpc('qm_admin_transactions');
  return data ?? [];
}
export async function adminOverview() {
  let { data, error } = await sb.rpc('qm_admin_overview');
  // Cache de schéma PostgREST périmé ("could not find the function … in the
  // schema cache") : on retente une fois après une courte pause, le temps
  // que le cache se recharge.
  if (error && /schema cache|find the function/i.test(error.message || '')) {
    await new Promise(r => setTimeout(r, 1500));
    ({ data, error } = await sb.rpc('qm_admin_overview'));
  }
  if (error) { console.error('qm_admin_overview:', error.message); return { __error: error.message }; }
  return (data && data[0]) ? data[0] : null;
}

// ---------- DRAFT ---------------------------------------------------
export async function draftState() {
  const { data } = await sb.rpc('qm_draft_state');
  return (data && data[0]) ? data[0] : null;
}
export async function draftPick(playerId) {
  return sb.rpc('qm_draft_pick', { p_player_id: playerId });
}
export async function draftPicksList(draftId = null) {
  const { data } = await sb.rpc('qm_draft_picks_list', { p_draft_id: draftId });
  return data ?? [];
}
export async function adminCreateDraft(rounds) {
  return sb.rpc('qm_admin_create_draft', { p_rounds: rounds });
}
export async function adminStartDraft(id) {
  return sb.rpc('qm_admin_start_draft', { p_draft_id: id });
}
export async function adminCancelDraft(id) {
  return sb.rpc('qm_admin_cancel_draft', { p_draft_id: id });
}
// Temps réel : le draft avance -> on rafraîchit
export function subscribeDraft(onChange) {
  return sb.channel('draft:live')
    .on('postgres_changes', { event: '*', schema: 'public', table: 'qm_drafts' }, () => { try{onChange();}catch(e){} })
    .on('postgres_changes', { event: '*', schema: 'public', table: 'qm_draft_picks' }, () => { try{onChange();}catch(e){} })
    .subscribe();
}

// ---------- COMPARATEUR D'EFFECTIFS ---------------------------------
export async function squadSummary(managerId) {
  const { data } = await sb.rpc('qm_squad_summary', { p_manager_id: managerId });
  return data ?? [];
}

// ---------- COURBE DE VALEUR D'UN JOUEUR ----------------------------
export async function valueHistory(playerId, limit = 60) {
  const { data } = await sb.rpc('qm_value_history', { p_player_id: playerId, p_limit: limit });
  return data ?? [];
}

// ---------- FORME RÉCENTE D'UN JOUEUR (dernières notes de journée) ----
export async function playerForm(playerId, limit = 5) {
  if (!playerId) return [];
  // Notes saisies ; on trie par numéro de journée côté client (robuste).
  const { data } = await sb.from('qm_player_scores')
    .select('rating, play_status, matchday:qm_matchdays(number, label)')
    .eq('player_id', playerId)
    .not('rating', 'is', null);
  const rows = (data ?? []).map(r => ({
    rating: Number(r.rating),
    play_status: r.play_status,
    md_number: r.matchday?.number ?? 0,
    md_label: r.matchday?.label
  }));
  rows.sort((a, b) => b.md_number - a.md_number);
  return rows.slice(0, limit);
}

// ---------- PRONOSTICS ----------------------------------------------
export async function pronosList() {
  const { data } = await sb.rpc('qm_pronos_list');
  return data ?? [];
}
export async function pronoBet(pronoId, optionIdx, stake) {
  return sb.rpc('qm_prono_bet', { p_prono_id: pronoId, p_option_idx: optionIdx, p_stake: stake });
}
export async function pronosLeaderboard() {
  const { data } = await sb.rpc('qm_pronos_leaderboard');
  return data ?? [];
}
export async function myPronosPoints() {
  const { data } = await sb.rpc('qm_my_pronos_points');
  return data ?? 0;
}
export async function adminPronos() {
  const { data } = await sb.rpc('qm_admin_pronos');
  return data ?? [];
}
export async function adminCreateProno(question, options, hours) {
  return sb.rpc('qm_admin_create_prono', { p_question: question, p_options: options, p_hours: hours ?? 24 });
}
export async function adminCloseProno(id) {
  return sb.rpc('qm_admin_close_prono', { p_prono_id: id });
}
export async function adminResolveProno(id, winnerIdx) {
  return sb.rpc('qm_admin_resolve_prono', { p_prono_id: id, p_winner_idx: winnerIdx });
}

// ---------- CHAT DE LIGUE -------------------------------------------
export async function chatSend(body) {
  return sb.rpc('qm_chat_send', { p_body: body });
}
export async function chatRecent(limit = 60) {
  const { data } = await sb.rpc('qm_chat_recent', { p_limit: limit });
  return (data ?? []).reverse();  // du plus ancien au plus récent pour l'affichage
}
export async function chatDelete(id) {
  return sb.rpc('qm_chat_delete', { p_id: id });
}
// Message épinglé (consigne de l'orga).
export async function chatPinned() {
  const { data } = await sb.rpc('qm_chat_pinned');
  return (data && data[0]) ? data[0] : null;
}
export async function adminPinMessage(id, on) {
  return sb.rpc('qm_admin_pin_message', { p_id: id, p_on: on });
}
export async function adminSetMute(managerId, muted) {
  return sb.rpc('qm_admin_set_mute', { p_manager_id: managerId, p_muted: muted });
}
export async function adminClearChat() {
  return sb.rpc('qm_admin_clear_chat');
}
// Abonnement temps réel au chat : onMsg() appelé à chaque nouveau message.
export function subscribeChat(onChange) {
  return sb.channel('chat:league')
    .on('postgres_changes', { event: '*', schema: 'public', table: 'qm_chat_messages' },
      () => { try { onChange(); } catch(e){} })
    .subscribe();
}

// ---------- RÉACTIONS (stickers) sur les transferts -----------------
export async function react(transferId, kind) {
  return sb.rpc('qm_react', { p_transfer_id: transferId, p_kind: kind });
}
export async function reactionCounts(ids) {
  if (!ids || !ids.length) return [];
  const { data } = await sb.rpc('qm_reaction_counts', { p_ids: ids });
  return data ?? [];
}

// ---------- DÉFIS HEBDO ---------------------------------------------
export async function myChallenges() {
  const { data } = await sb.rpc('qm_my_challenges');
  return data ?? [];
}
export async function claimChallenge(id) {
  return sb.rpc('qm_claim_challenge', { p_challenge_id: id });
}
export async function adminChallenges() {
  const { data } = await sb.rpc('qm_admin_challenges');
  return data ?? [];
}
export async function adminCreateChallenge(c) {
  // c : { kind, label, param_text, param_num, reward, days }
  return sb.rpc('qm_admin_create_challenge', {
    p_kind: c.kind, p_label: c.label, p_param_text: c.param_text ?? null,
    p_param_num: c.param_num, p_reward: c.reward, p_days: c.days ?? 7
  });
}
export async function adminSetChallengeActive(id, active) {
  return sb.rpc('qm_admin_set_challenge_active', { p_challenge_id: id, p_active: active });
}

// ---------- Effectifs complets (surveillance pré-J10) ---------------
export async function adminSquadFill() {
  const { data } = await sb.rpc('qm_admin_squad_fill');
  return (data && data[0]) ? data[0] : null;
}

// ---------- DIAGNOSTIC / SANTÉ (admin) ------------------------------
export async function adminHealthcheck() {
  const { data, error } = await sb.rpc('qm_admin_healthcheck');
  if (error) { console.error('qm_admin_healthcheck:', error.message); return []; }
  return data ?? [];
}

// ---------- DASHBOARD FINANCIER (admin, vague 3) --------------------
export async function adminFinance() {
  const { data, error } = await sb.rpc('qm_admin_finance');
  if (error) { console.error('qm_admin_finance:', error.message); return null; }
  return (data && data[0]) ? data[0] : null;
}
export async function adminManagerFinance() {
  const { data } = await sb.rpc('qm_admin_manager_finance');
  return data ?? [];
}
export async function adminTopPlayers(limit = 10) {
  const { data } = await sb.rpc('qm_admin_top_players', { p_limit: limit });
  return data ?? [];
}

// ---------- BONUS -----------------------------------------------------
export async function myBonuses() {
  const { data } = await sb.rpc('qm_my_bonuses');
  return data ?? [];
}
export async function adminAllBonuses() {
  const { data } = await sb.rpc('qm_admin_all_bonuses');
  return data ?? [];
}
export async function adminAwardQuiz(managerId, points) {
  return sb.rpc('qm_admin_award_quiz_logged', { p_manager_id: managerId, p_points: points });
}
export async function adminSetBonusSettings(fullDay, quizRate) {
  return sb.rpc('qm_admin_set_bonus_settings', { p_full_day: fullDay, p_quiz_rate: quizRate });
}

// ---------- THÈME (couleurs personnalisables) -----------------------
// ---------- MASSE SALARIALE / DOUBLE BUDGET -------------------------
export async function myDashboard() {
  const { data, error } = await sb.rpc('qm_my_dashboard');
  if (error) { console.error('qm_my_dashboard:', error.message, error); return null; }
  return (data && data[0]) ? data[0] : null;
}
export async function salaryOf(playerId) {
  const { data } = await sb.rpc('qm_salary_of', { p_player_id: playerId });
  return data ?? 0;
}
export async function adminSetSalaryCap(cap) {
  return sb.rpc('qm_admin_set_salary_cap', { p_cap: cap });
}

// ---------- RÈGLES DE RYTHME DU MERCATO -----------------------------
export async function proposalsReminder() {
  const { data } = await sb.rpc('qm_proposals_reminder');
  return (data && data[0]) ? data[0] : { made:0, target:2, remaining:2 };
}
export async function activeAuctionsCount() {
  const { data } = await sb.rpc('qm_active_auctions_count');
  return data ?? 0;
}
export async function adminSetMercatoRules(maxAuctions, maxDaily, proposalsTarget) {
  return sb.rpc('qm_admin_set_mercato_rules', {
    p_max_auctions: maxAuctions, p_max_daily: maxDaily, p_proposals_target: proposalsTarget
  });
}
export async function myEntryTax(auctionId) {
  const { data } = await sb.rpc('qm_my_entry_tax', { p_auction_id: auctionId });
  return data ?? 0;
}
export async function adminSetEntryTax(tax) {
  return sb.rpc('qm_admin_set_entry_tax', { p_tax: tax });
}

// ---------- NOTE À 7 CRITÈRES ---------------------------------------
export async function adminSetCriteria(id, c) {
  // c : { valeur, performance, regularite, tempsjeu, age, championnat, international }
  return sb.rpc('qm_admin_set_criteria', {
    p_id: id,
    p_valeur: c.valeur, p_performance: c.performance, p_regularite: c.regularite,
    p_tempsjeu: c.tempsjeu, p_age: c.age, p_championnat: c.championnat, p_international: c.international
  });
}
export async function adminCriteria(id) {
  const { data } = await sb.rpc('qm_admin_criteria', { p_id: id });
  return (data && data[0]) ? data[0] : null;
}
// ---------- PRIX DÉRIVÉ DE LA NOTE ----------------------------------
export async function adminPreviewPrices() {
  const { data } = await sb.rpc('qm_admin_preview_prices');
  return data ?? [];
}
export async function adminApplyNotePrices() {
  return sb.rpc('qm_admin_apply_note_prices');
}
export async function adminApplyNotePriceOne(id) {
  return sb.rpc('qm_admin_apply_note_price_one', { p_id: id });
}
export async function adminSetBidWindows(cooldown, noFirst, final) {
  return sb.rpc('qm_admin_set_bid_windows', {
    p_cooldown: cooldown, p_no_first: noFirst, p_final: final
  });
}

// ---------- LIBÉRATION DE JOUEUR ------------------------------------
export async function releasePreview(playerId) {
  const { data } = await sb.rpc('qm_release_preview', { p_player_id: playerId });
  return (data && data[0]) ? data[0] : null;
}
export async function releasePlayer(playerId) {
  return sb.rpc('qm_release_player', { p_player_id: playerId });
}
export async function myReleases() {
  const { data } = await sb.rpc('qm_my_releases');
  return data ?? [];
}
export async function adminReleases() {
  const { data } = await sb.rpc('qm_admin_releases');
  return data ?? [];
}
export async function adminSetAntiAbuse(maxLeading, scoutMinBids, collusionMax) {
  return sb.rpc('qm_admin_set_antiabuse', {
    p_max_leading: maxLeading, p_scout_min_bids: scoutMinBids, p_collusion_max: collusionMax
  });
}
export async function leadingAuctionsCount(managerId) {
  const { data } = await sb.rpc('qm_leading_auctions_count', { p_manager_id: managerId });
  return data ?? 0;
}
export async function convertBudgetToPoints(amount) {
  return sb.rpc('qm_convert_budget_to_points', { p_amount: amount });
}
export async function adminSetExtraBonuses(samePos, poker, convertRate) {
  return sb.rpc('qm_admin_set_extra_bonuses', {
    p_same_pos: samePos, p_poker: poker, p_convert_rate: convertRate
  });
}

export async function getTheme() {
  const { data } = await sb.rpc('qm_get_theme');
  return (data && data[0]) ? data[0] : { accent:null, bg:null, title:null };
}
export async function adminSetTheme(accent, bg, title) {
  return sb.rpc('qm_admin_set_theme', {
    p_accent: accent || null, p_bg: bg || null, p_title: title || null
  });
}
// Applique un thème en surchargeant les variables CSS (appelé au chargement)
export function applyTheme(theme) {
  const root = document.documentElement;
  if(theme.accent){
    root.style.setProperty('--transfer', theme.accent);
    root.style.setProperty('--transfer-deep', theme.accent);
  }
  if(theme.bg){
    root.style.setProperty('--pitch', theme.bg);
  }
  if(theme.title){
    root.style.setProperty('--chalk', theme.title);
  }
}

// ---------- TEMPS RÉEL (Realtime) ------------------------------------
export function subscribeAuction(auctionId, onChange) {
  return sb.channel(`auction:${auctionId}`)
    .on('postgres_changes',
      { event: 'UPDATE', schema: 'public', table: 'qm_auctions', filter: `id=eq.${auctionId}` },
      payload => onChange(payload.new))
    .subscribe();
}

// Abonnement GLOBAL au marché : toute enchère (créée, modifiée, clôturée)
// et toute offre déclenchent onChange. Sert à rafraîchir la salle des
// enchères, l'accueil et la cloche en direct, sans que personne ne recharge.
// Renvoie le channel ; appeler sb.removeChannel(ch) pour se désabonner.
export function subscribeMarket(onChange) {
  let timer = null;
  const ping = (kind) => {
    // On regroupe les rafales (plusieurs events en < 400 ms = un seul refresh)
    clearTimeout(timer);
    timer = setTimeout(() => { try { onChange(kind); } catch(e){} }, 400);
  };
  return sb.channel('market:global')
    .on('postgres_changes', { event: '*', schema: 'public', table: 'qm_auctions' }, () => ping('auction'))
    .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'qm_bids' }, () => ping('bid'))
    .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'qm_transfers' }, () => ping('transfer'))
    .subscribe();
}
export function unsubscribe(channel) {
  if (channel) { try { sb.removeChannel(channel); } catch(e){} }
}

// ---------- WEB PUSH (notifications app fermée) ---------------------
export function pushAvailable() {
  return ('serviceWorker' in navigator) && ('PushManager' in window)
    && VAPID_PUBLIC_KEY && VAPID_PUBLIC_KEY !== 'TA_CLE_VAPID_PUBLIQUE';
}
function urlB64ToUint8Array(base64String) {
  const padding = '='.repeat((4 - base64String.length % 4) % 4);
  const base64 = (base64String + padding).replace(/-/g, '+').replace(/_/g, '/');
  const raw = atob(base64);
  const arr = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) arr[i] = raw.charCodeAt(i);
  return arr;
}
// Abonne l'appareil courant aux notifications push. Renvoie true si OK.
export async function enablePush() {
  if (!pushAvailable()) return { ok: false, reason: 'unavailable' };
  const perm = await Notification.requestPermission();
  if (perm !== 'granted') return { ok: false, reason: 'denied' };
  const reg = await navigator.serviceWorker.ready;
  let sub = await reg.pushManager.getSubscription();
  if (!sub) {
    sub = await reg.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: urlB64ToUint8Array(VAPID_PUBLIC_KEY)
    });
  }
  const json = sub.toJSON();
  const { error } = await sb.rpc('qm_push_subscribe', {
    p_endpoint: sub.endpoint,
    p_p256dh: json.keys.p256dh,
    p_auth: json.keys.auth
  });
  if (error) return { ok: false, reason: error.message };
  return { ok: true };
}
export async function disablePush() {
  if (!('serviceWorker' in navigator)) return;
  const reg = await navigator.serviceWorker.ready;
  const sub = await reg.pushManager.getSubscription();
  if (sub) {
    await sb.rpc('qm_push_unsubscribe', { p_endpoint: sub.endpoint });
    await sub.unsubscribe();
  }
}
export async function pushEnabledHere() {
  if (!('serviceWorker' in navigator) || !('PushManager' in window)) return false;
  try {
    const reg = await navigator.serviceWorker.ready;
    const sub = await reg.pushManager.getSubscription();
    return !!sub;
  } catch(e){ return false; }
}

// ---------- VAGUE 3 : Journées, Coach, Compositions ----------------
export async function adminCreateMatchday(number, label, deadline) {
  return sb.rpc('qm_admin_create_matchday', { p_number: number, p_label: label, p_deadline: deadline });
}
export async function adminSetMatchdayStatus(matchdayId, status) {
  return sb.rpc('qm_admin_set_matchday_status', { p_matchday_id: matchdayId, p_status: status });
}
export async function listMatchdays() {
  const { data } = await sb.from('qm_matchdays').select('*').order('number', { ascending: true });
  return data ?? [];
}
export async function adminAssignCoach(coachId, teamId) {
  return sb.rpc('qm_admin_assign_coach', { p_coach_id: coachId, p_team_id: teamId });
}
export async function adminUnassignCoach(coachId) {
  return sb.rpc('qm_admin_unassign_coach', { p_coach_id: coachId });
}
export async function myTeamId() {
  const { data } = await sb.rpc('qm_my_team_id');
  return data ?? null;
}
export async function setLineup(matchdayId, playerIds, benchIds) {
  return sb.rpc('qm_set_lineup', {
    p_matchday_id: matchdayId,
    p_player_ids: playerIds,
    p_bench_ids: benchIds || []
  });
}
export async function myLineup(matchdayId) {
  const { data } = await sb.rpc('qm_my_lineup', { p_matchday_id: matchdayId });
  return data ?? null;
}
export async function adminCloseMatchday(matchdayId) {
  // La fonction SQL qm_admin_close_matchday sera créée à l'étape 4
  return sb.rpc('qm_admin_close_matchday', { p_matchday_id: matchdayId });
}

// ---------- VAGUE 3 : Saisie des notes ----------------------------
export async function scoringPlayers(matchdayId) {
  const { data } = await sb.rpc('qm_scoring_players', { p_matchday_id: matchdayId });
  return data ?? [];
}
export async function adminSetScores(matchdayId, data) {
  return sb.rpc('qm_admin_set_scores', { p_matchday_id: matchdayId, p_data: data });
}
export async function scoringProgress(matchdayId) {
  const { data } = await sb.rpc('qm_scoring_progress', { p_matchday_id: matchdayId });
  return (data && data[0]) ? data[0] : { total: 0, scored: 0 };
}

// ---------- VAGUE 3 : Points & classement par journée -------------
// Journal des remplacements d'une journée (admin).
export async function matchdaySubs(matchdayId) {
  const { data } = await sb.rpc('qm_admin_matchday_subs', { p_matchday_id: matchdayId });
  return data ?? [];
}
export async function lineupBreakdown(managerId, matchdayId) {
  const { data } = await sb.rpc('qm_lineup_breakdown', { p_manager: managerId, p_matchday_id: matchdayId });
  return data ?? [];
}
export async function matchdayStandings(matchdayId) {
  const { data } = await sb.rpc('qm_matchday_standings', { p_matchday_id: matchdayId });
  return data ?? [];
}

// ---------- VAGUE 3 temps 1 : Mercatos & recrutement direct -------
export async function windowIsOpen() {
  const { data } = await sb.rpc('qm_window_is_open');
  return data ?? false;
}
export async function currentWindow() {
  const { data } = await sb.rpc('qm_current_window');
  return data ?? null;
}
export async function listWindows() {
  const { data } = await sb.from('qm_market_windows').select('*').order('created_at', { ascending: true });
  return data ?? [];
}
export async function adminCreateWindow(kind, label, opens, closes) {
  return sb.rpc('qm_admin_create_window', { p_kind: kind, p_label: label, p_opens: opens, p_closes: closes });
}
export async function adminSetWindowActive(windowId, active) {
  return sb.rpc('qm_admin_set_window_active', { p_window_id: windowId, p_active: active });
}
export async function directRecruit(playerId) {
  return sb.rpc('qm_direct_recruit', { p_player_id: playerId });
}
// ---------- Agents libres (joueurs libérés, recrutement gratuit) ----------
export async function freeAgents() {
  const { data } = await sb.rpc('qm_free_agents');
  return data ?? [];
}
export async function claimFreeAgent(playerId) {
  return sb.rpc('qm_claim_free_agent', { p_player_id: playerId });
}

// ---------- VAGUE 3 temps 2 : Points->budget & récompenses --------
export async function convertPointsToBudget(points) {
  return sb.rpc('qm_convert_points_to_budget', { p_points: points });
}
export async function listAwards() {
  const { data } = await sb.from('qm_awards')
    .select('*, manager:qm_managers(display_name)')
    .order('awarded_at', { ascending: false });
  return data ?? [];
}
export async function adminGrantAward(managerId, title, detail) {
  return sb.rpc('qm_admin_grant_award', { p_manager_id: managerId, p_title: title, p_detail: detail });
}
export async function adminCrownChampion() {
  return sb.rpc('qm_admin_crown_champion');
}

// ---------- Outils admin : fonds / taxe / bonus dénicheur ---------
export async function adminCreditBudget(managerId, amount, reason) {
  return sb.rpc('qm_admin_credit_budget_logged', { p_manager_id: managerId, p_amount: amount, p_reason: reason ?? null });
}
// Journal des actions admin + annulation (undo).
export async function adminActionsRecent(limit = 50) {
  const { data } = await sb.rpc('qm_admin_actions_recent', { p_limit: limit });
  return data ?? [];
}
export async function adminUndo(actionId) {
  return sb.rpc('qm_admin_undo', { p_action_id: actionId });
}
export async function adminExemptEntryTax(auctionId, managerId) {
  return sb.rpc('qm_admin_exempt_entry_tax', { p_auction_id: auctionId, p_manager_id: managerId });
}
export async function adminForceScoutBonus(managerId, referencePrice, playerLabel) {
  return sb.rpc('qm_admin_force_scout_bonus', { p_manager_id: managerId, p_reference_price: referencePrice, p_player_label: playerLabel ?? null });
}

// ---------- Bonus Construction ------------------------------------
export async function adminSetConstructionBonuses(b11, b15, b19, clubs) {
  return sb.rpc('qm_admin_set_construction_bonuses', { p_b11: b11, p_b15: b15, p_b19: b19, p_clubs: clubs });
}

// ---------- Identité d'équipe (nom + couleurs) --------------------
export async function setTeamIdentity(teamName, primary, secondary) {
  return sb.rpc('qm_set_team_identity', { p_team_name: teamName, p_primary: primary, p_secondary: secondary });
}
export async function teamIdentity() {
  const { data } = await sb.rpc('qm_team_identity');
  return (data && data[0]) ? data[0] : null;
}

// ---------- Photos des joueurs (upload fichier OU URL) ------------
// Upload un fichier image vers le bucket 'player-photos', renvoie l'URL publique.
export async function uploadPlayerPhoto(playerId, file) {
  const ext = (file.name.split('.').pop() || 'jpg').toLowerCase();
  const path = `${playerId}-${Date.now()}.${ext}`;
  const { error } = await sb.storage.from('player-photos').upload(path, file, { upsert: true });
  if (error) return { error };
  const { data } = sb.storage.from('player-photos').getPublicUrl(path);
  return { url: data.publicUrl };
}
// Enregistre l'URL de la photo sur le joueur (après upload, ou URL collée).
export async function setPlayerPhoto(playerId, photoUrl) {
  return sb.rpc('qm_admin_set_player_photo', { p_player_id: playerId, p_photo_url: photoUrl });
}

// ---------- Blessures & remplacement ------------------------------
export async function declareInjury(playerId) {
  return sb.rpc('qm_declare_injury', { p_player_id: playerId });
}
export async function canDirectRecruit() {
  const { data } = await sb.rpc('qm_can_direct_recruit');
  return data ?? false;
}
// Interrupteur admin "recrutement direct" (mode test)
export async function directRecruitTestOn() {
  const { data } = await sb.rpc('qm_direct_recruit_test_on');
  return data ?? false;
}
export async function adminSetDirectRecruitTest(on) {
  return sb.rpc('qm_admin_set_direct_recruit_test', { p_on: on });
}
export async function adminReviewInjury(injuryId, approve) {
  return sb.rpc('qm_admin_review_injury', { p_injury_id: injuryId, p_approve: approve });
}
export async function adminPendingInjuries() {
  const { data } = await sb.rpc('qm_admin_pending_injuries');
  return data ?? [];
}
