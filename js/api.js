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
  // p : { id?, name, position, club, nationality, age, photo_url, value }
  return sb.rpc('qm_admin_upsert_player', {
    p_id: p.id ?? null,
    p_name: p.name,
    p_position: p.position,
    p_club: p.club ?? null,
    p_nationality: p.nationality ?? null,
    p_age: p.age ?? null,
    p_photo_url: p.photo_url ?? null,
    p_value: p.value
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

// ---------- TEMPS RÉEL (Realtime) ------------------------------------
export function subscribeAuction(auctionId, onChange) {
  return sb.channel(`auction:${auctionId}`)
    .on('postgres_changes',
      { event: 'UPDATE', schema: 'public', table: 'qm_auctions', filter: `id=eq.${auctionId}` },
      payload => onChange(payload.new))
    .subscribe();
}
