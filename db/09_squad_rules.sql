-- =====================================================================
-- QUIZ MERCATO — Contraintes de composition d'effectif
-- =====================================================================
-- Règles vérifiées AU MOMENT d'enchérir (dans qm_place_bid), pour qu'un
-- manager ne puisse pas miser sur un joueur qui ne rentrerait pas dans
-- son effectif. Chaque violation renvoie un message clair.
--
-- Règles :
--   1. Max 24 joueurs au total
--   2. Max 3 gardiens
--   3. Max 3 joueurs d'un même club
--   4. Max 2 joueurs de note QM >= 85 à un même poste (anti-stars)
--
-- Note : on compte l'effectif ACTUEL + les enchères où le manager est
-- déjà meilleur enchérisseur (engagements en cours), pour éviter qu'il
-- contourne les règles en menant plusieurs enchères simultanées.
-- =====================================================================

create or replace function qm_check_squad_rules(
  p_manager_id uuid,
  p_player_id  uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player   qm_players;
  v_total    integer;
  v_gk       integer;
  v_club     integer;
  v_stars    integer;
  v_is_star  boolean;
begin
  select * into v_player from qm_players where id = p_player_id;
  if not found then
    raise exception 'Joueur introuvable';
  end if;

  -- Sous-requête : joueurs "comptés" pour ce manager =
  --   ceux qu'il possède déjà (owner_id)
  --   + ceux d'enchères ouvertes où il est meilleur enchérisseur
  --     (hors l'enchère du joueur courant, gérée à part)
  with squad as (
    select pl.*
    from qm_players pl
    where pl.owner_id = p_manager_id
    union
    select pl.*
    from qm_auctions au
    join qm_players pl on pl.id = au.player_id
    where au.status = 'open'
      and au.top_bidder_id = p_manager_id
      and au.player_id <> p_player_id
  )
  select count(*) into v_total from squad;

  -- 1. Effectif complet ?
  if v_total >= 24 then
    raise exception 'Effectif complet (24 joueurs). Vends un joueur avant d''enchérir.';
  end if;

  -- 2. Trop de gardiens ?
  if v_player.position = 'GK' then
    select count(*) into v_gk from (
      select pl.* from qm_players pl where pl.owner_id = p_manager_id and pl.position = 'GK'
      union
      select pl.* from qm_auctions au join qm_players pl on pl.id = au.player_id
      where au.status='open' and au.top_bidder_id=p_manager_id and au.player_id<>p_player_id and pl.position='GK'
    ) g;
    if v_gk >= 3 then
      raise exception 'Maximum 3 gardiens dans un effectif.';
    end if;
  end if;

  -- 3. Trop de joueurs du même club ?
  if v_player.club is not null then
    select count(*) into v_club from (
      select pl.* from qm_players pl where pl.owner_id = p_manager_id and pl.club = v_player.club
      union
      select pl.* from qm_auctions au join qm_players pl on pl.id = au.player_id
      where au.status='open' and au.top_bidder_id=p_manager_id and au.player_id<>p_player_id and pl.club = v_player.club
    ) c;
    if v_club >= 3 then
      raise exception 'Maximum 3 joueurs d''un même club (% en a déjà 3).', v_player.club;
    end if;
  end if;

  -- 4. Anti-stars : max 2 joueurs de note QM >= 85 au même poste
  v_is_star := qm_rating(v_player) >= 85;
  if v_is_star then
    select count(*) into v_stars from (
      select pl.* from qm_players pl
        where pl.owner_id = p_manager_id and pl.position = v_player.position and qm_rating(pl) >= 85
      union
      select pl.* from qm_auctions au join qm_players pl on pl.id = au.player_id
      where au.status='open' and au.top_bidder_id=p_manager_id and au.player_id<>p_player_id
        and pl.position = v_player.position and qm_rating(pl) >= 85
    ) s;
    if v_stars >= 2 then
      raise exception 'Maximum 2 cracks (note QM ≥ 85) au poste % dans un effectif.',
        case v_player.position when 'GK' then 'gardien' when 'DEF' then 'défenseur'
             when 'MID' then 'milieu' else 'attaquant' end;
    end if;
  end if;

  -- Toutes les règles passent : la fonction retourne sans erreur.
end;
$$;
