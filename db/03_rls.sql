-- =====================================================================
-- QUIZ MERCATO — Row Level Security
-- =====================================================================
-- Principe : lecture publique sur les données de jeu (joueurs, enchères,
-- classement), mais écriture UNIQUEMENT via les RPC SECURITY DEFINER.
-- Un manager ne peut jamais écrire directement sur budgets/qm_players/qm_auctions.
-- =====================================================================

alter table qm_managers      enable row level security;
alter table qm_players       enable row level security;
alter table qm_auctions      enable row level security;
alter table qm_bids          enable row level security;
alter table qm_transfers     enable row level security;
alter table qm_season_state  enable row level security;
alter table qm_manager_cards enable row level security;

-- ---------- Lecture publique (données de jeu visibles par tous) -------
create policy "qm read managers"   on qm_managers      for select using (true);
create policy "qm read players"    on qm_players       for select using (true);
create policy "qm read auctions"   on qm_auctions      for select using (true);
create policy "qm read bids"       on qm_bids          for select using (true);
create policy "qm read transfers"  on qm_transfers     for select using (true);
create policy "qm read season"     on qm_season_state  for select using (true);

-- ---------- Cartes : chacun voit et gère les siennes -----------------
create policy "qm read own cards" on qm_manager_cards for select
  using (manager_id in (select id from qm_managers where auth_user_id = auth.uid()));

-- ---------- Écriture directe : INTERDITE (tout passe par les RPC) ----
-- Aucune policy INSERT/UPDATE/DELETE pour les rôles authentifiés.
-- Les fonctions qm_place_bid / qm_close_auction / qm_open_auction sont SECURITY
-- DEFINER : elles s'exécutent avec les droits du propriétaire (postgres)
-- et contournent RLS de façon contrôlée. C'est le seul chemin d'écriture.

-- Exception : un manager peut créer SA fiche à l'inscription
create policy "qm create own manager" on qm_managers for insert
  with check (auth_user_id = auth.uid());
