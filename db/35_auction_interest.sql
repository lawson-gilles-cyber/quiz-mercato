-- =====================================================================
-- ULTIMATE SQUAD — Nombre de managers intéressés par enchère
-- =====================================================================
-- Renvoie, pour chaque enchère ouverte, le nombre de managers DISTINCTS
-- ayant déjà enchéri (= niveau d'intérêt / de convoitise du joueur).
-- Affiché sur les cartes d'enchères pour donner une idée de la concurrence.
-- Lecture seule. À passer quand tu veux.
-- =====================================================================

create or replace function qm_auction_interest(p_auction_id uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select count(distinct manager_id)::integer
  from qm_bids where auction_id = p_auction_id;
$$;

grant execute on function qm_auction_interest(uuid) to anon, authenticated;
