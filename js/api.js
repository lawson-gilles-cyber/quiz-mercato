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
export async function signUp(email, password, displayName) {
  const { data, error } = await sb.auth.signUp({ email, password });
  if (error) return { error };
  // Crée la fiche manager (autorisé par la policy "create own manager")
  const { error: mErr } = await sb.from('qm_managers').insert({
    auth_user_id: data.user.id,
    display_name: displayName
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
  let q = sb.from('qm_players').select('*, owner:qm_managers(display_name)');
  if (filters.position) q = q.eq('position', filters.position);
  if (filters.status)   q = q.eq('status', filters.status);
  if (filters.search)   q = q.ilike('name', `%${filters.search}%`);
  q = q.order('current_value', { ascending: false });
  const { data } = await q;
  return data ?? [];
}

export async function listOpenAuctions() {
  const { data } = await sb.from('qm_auctions')
    .select('*, player:qm_players(*), top_bidder:qm_managers(display_name)')
    .eq('status', 'open')
    .order('ends_at', { ascending: true });
  return data ?? [];
}

export async function myTeam(managerId) {
  const { data } = await sb.from('qm_players')
    .select('*').eq('owner_id', managerId)
    .order('current_value', { ascending: false });
  return data ?? [];
}

export async function leaderboard() {
  const { data } = await sb.from('qm_managers')
    .select('id, display_name, season_points, budget, budget_locked')
    .order('season_points', { ascending: false });
  return data ?? [];
}

export async function transferHistory(playerId) {
  const { data } = await sb.from('qm_transfers')
    .select('*, from:qm_managers!qm_transfers_from_manager_fkey(display_name), to:qm_managers!qm_transfers_to_manager_fkey(display_name)')
    .eq('player_id', playerId)
    .order('created_at', { ascending: false });
  return data ?? [];
}

// ---------- ÉCRITURES (uniquement via RPC) ---------------------------
export async function placeBid(auctionId, amount) {
  return sb.rpc('qm_place_bid', { p_auction_id: auctionId, p_amount: amount });
}
export async function openAuction(playerId) {
  return sb.rpc('qm_open_auction', { p_player_id: playerId });
}

// ---------- ADMIN (RPC réservées, contrôle is_admin côté serveur) ----
export async function amIAdmin() {
  const { data } = await sb.rpc('qm_is_admin');
  return data === true;
}
export async function adminUpsertPlayer(p) {
  // p : { id?, name, position, club, nationality, age, photo_url, value, championship }
  return sb.rpc('qm_admin_upsert_player', {
    p_id: p.id ?? null,
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
export async function adminDeletePlayer(id) {
  return sb.rpc('qm_admin_delete_player', { p_id: id });
}
export async function adminOpenAuction(playerId) {
  return sb.rpc('qm_admin_open_auction', { p_player_id: playerId });
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
  const { data } = await sb.from('qm_managers').select('id, display_name').order('display_name');
  return data ?? [];
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
export async function acceptTrade(id){ return sb.rpc('qm_trade_accept', { p_trade_id: id }); }
export async function refuseTrade(id){ return sb.rpc('qm_trade_refuse', { p_trade_id: id }); }
export async function cancelTrade(id){ return sb.rpc('qm_trade_cancel', { p_trade_id: id }); }

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
  // p : { player_id?, new_name?, new_position?, new_club?, new_value?, new_championship? }
  return sb.rpc('qm_propose_player', {
    p_player_id: p.player_id ?? null,
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
export async function adminPendingProposals() {
  const { data } = await sb.rpc('qm_admin_pending_proposals');
  return data ?? [];
}
export async function adminApproveProposal(id) {
  return sb.rpc('qm_admin_approve_proposal', { p_proposal_id: id });
}
export async function adminRejectProposal(id) {
  return sb.rpc('qm_admin_reject_proposal', { p_proposal_id: id });
}
export async function adminTransactions() {
  const { data } = await sb.rpc('qm_admin_transactions');
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
  return sb.rpc('qm_admin_award_quiz', { p_manager_id: managerId, p_points: points });
}
export async function adminSetBonusSettings(fullDay, quizRate) {
  return sb.rpc('qm_admin_set_bonus_settings', { p_full_day: fullDay, p_quiz_rate: quizRate });
}

// ---------- THÈME (couleurs personnalisables) -----------------------
// ---------- MASSE SALARIALE / DOUBLE BUDGET -------------------------
export async function myDashboard() {
  const { data } = await sb.rpc('qm_my_dashboard');
  return (data && data[0]) ? data[0] : null;
}
export async function salaryOf(playerId) {
  const { data } = await sb.rpc('qm_salary_of', { p_player_id: playerId });
  return data ?? 0;
}
export async function adminSetSalaryCap(cap) {
  return sb.rpc('qm_admin_set_salary_cap', { p_cap: cap });
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
