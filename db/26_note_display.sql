-- =====================================================================
-- ULTIMATE SQUAD — Affichage de la note (Étape 2 : la jauge)
-- =====================================================================
-- Le manager ne voit JAMAIS la note chiffrée d'un joueur qu'il ne
-- possède pas : il voit seulement une CATÉGORIE DE COULEUR (jauge).
-- Une fois le joueur dans son effectif, le chiffre exact est révélé.
--
-- Cette fonction renvoie, pour chaque joueur, la couleur de note
-- (toujours) et la note chiffrée (uniquement si le joueur appartient au
-- manager courant). Ainsi le chiffre exact des joueurs non possédés
-- n'est jamais envoyé au navigateur — impossible à lire dans la console.
--
-- À passer APRÈS 25_note_criteres.sql.
-- =====================================================================

create or replace function qm_players_view()
returns table (
  id uuid, name text, pos qm_player_position, club text, championship text,
  nationality text, age integer, photo_url text, current_value bigint,
  status text, owner_id uuid, owner_name text,
  note_color text,          -- toujours renvoyé (rouge/jaune/vert-clair/vert-vif)
  note smallint,            -- renvoyé uniquement si possédé par le manager courant, sinon null
  demand_score integer
)
language sql
stable
security definer
set search_path = public
as $$
  with me as (select id from qm_managers where auth_user_id = auth.uid())
  select
    p.id, p.name, p.position, p.club, p.championship,
    p.nationality, p.age, p.photo_url, p.current_value,
    p.status::text, p.owner_id,
    (select display_name from qm_managers m where m.id = p.owner_id) as owner_name,
    qm_rating_color(qm_rating(p.*)) as note_color,
    case when p.owner_id in (select id from me) then qm_rating(p.*) else null end as note,
    p.demand_score
  from qm_players p
  order by p.current_value desc;
$$;

grant execute on function qm_players_view() to anon, authenticated;

-- Version filtrée par enchères ouvertes (pour l'onglet Enchères) :
-- on renvoie aussi la couleur, jamais le chiffre pour un joueur non possédé.
create or replace function qm_auction_note_color(p_player_id uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select qm_rating_color(qm_rating(p.*)) from qm_players p where p.id = p_player_id;
$$;

grant execute on function qm_auction_note_color(uuid) to anon, authenticated;
