-- =====================================================================
-- ULTIMATE SQUAD — Notifications (A) — calcul à la volée
-- =====================================================================
-- Renvoie les événements pertinents pour le manager courant, SANS table
-- de notifications à maintenir. Trois catégories :
--   1. "outbid"  : enchères ouvertes où le manager a misé mais n'est
--                   PLUS le meilleur enchérisseur (on l'a dépassé).
--   2. "trade"   : échanges en attente de SA réponse (il est destinataire).
--   3. "winning" : enchères ouvertes où il mène actuellement (rappel).
--
-- Chaque ligne : type, titre, détail, ref (id), created_at.
-- À passer quand tu veux (indépendant). Lecture seule.
-- =====================================================================

create or replace function qm_my_notifications()
returns table (
  kind text, title text, detail text, ref uuid, created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  with me as (select id from qm_managers where auth_user_id = auth.uid())

  -- 1. Enchères où j'ai misé mais où je ne mène plus (on m'a dépassé)
  select
    'outbid'::text as kind,
    'Tu as été dépassé'::text as title,
    p.name || ' — offre actuelle ' || (a.current_price/1000000)::text || ' M€' as detail,
    a.id as ref,
    a.ends_at as created_at
  from qm_auctions a
  join qm_players p on p.id = a.player_id
  where a.status = 'open'
    and a.top_bidder_id is distinct from (select id from me)
    and exists (
      select 1 from qm_bids b
      where b.auction_id = a.id and b.manager_id = (select id from me)
    )

  union all

  -- 2. Échanges en attente de ma réponse
  select
    'trade'::text,
    'Proposition d''échange'::text,
    m2.display_name || ' te propose un échange' as detail,
    tr.id,
    tr.created_at
  from qm_trades tr
  join qm_managers m2 on m2.id = tr.from_manager
  where tr.status = 'pending'
    and tr.to_manager = (select id from me)

  union all

  -- 3. Enchères où je mène actuellement (rappel positif)
  select
    'winning'::text,
    'Tu mènes une enchère'::text,
    p.name || ' — ' || (a.current_price/1000000)::text || ' M€' as detail,
    a.id,
    a.ends_at
  from qm_auctions a
  join qm_players p on p.id = a.player_id
  where a.status = 'open'
    and a.top_bidder_id = (select id from me)

  order by created_at desc;
$$;

grant execute on function qm_my_notifications() to authenticated;
revoke execute on function qm_my_notifications() from anon;
