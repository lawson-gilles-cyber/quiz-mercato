-- =====================================================================
-- QUIZ MERCATO / ULTIMATE SQUAD — Championnat + règle des 6
-- =====================================================================
-- Ajoute le championnat à chaque joueur, le déduit depuis le club pour
-- les joueurs existants, et ajoute la règle : max 6 joueurs d'un même
-- championnat dans un effectif.
--
-- À passer APRÈS 09_squad_rules.sql (étend qm_check_squad_rules) et
-- 11_trades.sql (étend qm_check_squad_after_trade).
-- =====================================================================

-- ---------- Colonne championnat --------------------------------------
alter table qm_players add column if not exists championship text;

-- ---------- Déduction automatique depuis le club (joueurs existants) --
-- Table de correspondance club -> championnat pour les clubs connus.
update qm_players set championship = case
  when club in ('Man City','Manchester City','Liverpool','Arsenal','Chelsea',
                'Man United','Manchester United','Tottenham','Newcastle',
                'Aston Villa','West Ham','Brighton') then 'Premier League'
  when club in ('Real Madrid','Barcelona','Atlético','Atletico','Athletic Bilbao',
                'Sevilla','Real Sociedad','Villarreal','Valencia','Betis') then 'Liga'
  when club in ('PSG','Paris SG','Monaco','Marseille','Lyon','Lille','Nice','Lens') then 'Ligue 1'
  when club in ('Bayern','Bayern Munich','Dortmund','Borussia Dortmund','Leverkusen',
                'RB Leipzig','Leipzig') then 'Bundesliga'
  when club in ('Inter','Milan','AC Milan','Juventus','Napoli','Roma','Lazio','Atalanta') then 'Serie A'
  when club in ('Al-Nassr','Al-Hilal','Al Nassr','Al Hilal') then 'Saudi Pro League'
  when club in ('Galatasaray','Fenerbahce') then 'Süper Lig'
  when club in ('Porto','Benfica','Sporting') then 'Primeira Liga'
  else championship  -- garde la valeur existante si club inconnu
end
where championship is null;

-- ---------- Règle des 6 : intégrée dans qm_check_squad_rules ---------
-- On redéfinit la fonction en ajoutant le contrôle du championnat.
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
  v_champ    integer;
  v_stars    integer;
  v_is_star  boolean;
begin
  select * into v_player from qm_players where id = p_player_id;
  if not found then raise exception 'Joueur introuvable'; end if;

  with squad as (
    select pl.* from qm_players pl where pl.owner_id = p_manager_id
    union
    select pl.* from qm_auctions au join qm_players pl on pl.id = au.player_id
    where au.status = 'open' and au.top_bidder_id = p_manager_id and au.player_id <> p_player_id
  )
  select count(*) into v_total from squad;

  if v_total >= 24 then
    raise exception 'Effectif complet (24 joueurs). Vends un joueur avant d''enchérir.';
  end if;

  if v_player.position = 'GK' then
    select count(*) into v_gk from (
      select pl.* from qm_players pl where pl.owner_id = p_manager_id and pl.position = 'GK'
      union
      select pl.* from qm_auctions au join qm_players pl on pl.id = au.player_id
      where au.status='open' and au.top_bidder_id=p_manager_id and au.player_id<>p_player_id and pl.position='GK'
    ) g;
    if v_gk >= 3 then raise exception 'Maximum 3 gardiens dans un effectif.'; end if;
  end if;

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

  -- NOUVEAU : max 6 joueurs d'un même championnat
  if v_player.championship is not null then
    select count(*) into v_champ from (
      select pl.* from qm_players pl where pl.owner_id = p_manager_id and pl.championship = v_player.championship
      union
      select pl.* from qm_auctions au join qm_players pl on pl.id = au.player_id
      where au.status='open' and au.top_bidder_id=p_manager_id and au.player_id<>p_player_id and pl.championship = v_player.championship
    ) ch;
    if v_champ >= 6 then
      raise exception 'Maximum 6 joueurs du championnat % dans un effectif.', v_player.championship;
    end if;
  end if;

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
end;
$$;

-- ---------- Règle des 6 aussi pour les échanges ---------------------
-- Redéfinit qm_check_squad_after_trade en ajoutant le contrôle championnat.
create or replace function qm_check_squad_after_trade(
  p_manager uuid,
  p_incoming uuid[],
  p_outgoing uuid[]
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_total integer;
  r record;
begin
  drop table if exists _squad;
  create temp table _squad on commit drop as
    select p.* from qm_players p
    where p.owner_id = p_manager
      and (p_outgoing is null or not (p.id = any(p_outgoing)))
    union
    select p.* from qm_players p where p.id = any(coalesce(p_incoming,'{}'));

  select count(*) into v_total from _squad;
  if v_total > 24 then
    raise exception 'Échange refusé : effectif dépasserait 24 joueurs (%).', v_total;
  end if;

  if (select count(*) from _squad where position='GK') > 3 then
    raise exception 'Échange refusé : plus de 3 gardiens.';
  end if;

  for r in select club, count(*) c from _squad where club is not null group by club loop
    if r.c > 3 then
      raise exception 'Échange refusé : plus de 3 joueurs du club %.', r.club;
    end if;
  end loop;

  -- NOUVEAU : max 6 par championnat
  for r in select championship, count(*) c from _squad where championship is not null group by championship loop
    if r.c > 6 then
      raise exception 'Échange refusé : plus de 6 joueurs du championnat %.', r.championship;
    end if;
  end loop;

  for r in
    select position, count(*) c from _squad
    where qm_rating(_squad.*) >= 85 group by position
  loop
    if r.c > 2 then
      raise exception 'Échange refusé : plus de 2 cracks (QM≥85) au poste %.', r.position;
    end if;
  end loop;
end;
$$;

-- ---------- Étendre l'ajout/màj de joueur pour inclure le championnat -
-- Redéfinit qm_admin_upsert_player avec le paramètre championnat.
create or replace function qm_admin_upsert_player(
  p_id uuid, p_name text, p_position qm_player_position, p_club text,
  p_nationality text, p_age integer, p_photo_url text, p_value bigint,
  p_championship text default null
)
returns qm_players
language plpgsql
security definer
set search_path = public
as $$
declare v_player qm_players;
begin
  if not qm_is_admin() then raise exception 'Réservé aux administrateurs'; end if;
  if p_value < 0 then raise exception 'La valeur ne peut pas être négative'; end if;

  if p_id is null then
    insert into qm_players (name, position, club, nationality, age, photo_url, base_value, current_value, championship)
    values (p_name, p_position, p_club, p_nationality, p_age, p_photo_url, p_value, p_value, p_championship)
    returning * into v_player;
  else
    update qm_players set
      name=p_name, position=p_position, club=p_club, nationality=p_nationality,
      age=p_age, photo_url=p_photo_url, base_value=p_value,
      championship=coalesce(p_championship, championship),
      current_value=case when status='free' then p_value else current_value end
    where id=p_id returning * into v_player;
    if not found then raise exception 'Joueur introuvable'; end if;
  end if;
  return v_player;
end;
$$;

-- ---------- Étendre la proposition de joueur (dénichage) ------------
create or replace function qm_propose_player(
  p_player_id uuid, p_new_name text, p_new_position qm_player_position,
  p_new_club text, p_new_value bigint, p_new_championship text default null
)
returns qm_player_proposals
language plpgsql
security definer
set search_path = public
as $$
declare v_me qm_managers; v_pending integer; v_prop qm_player_proposals;
begin
  select * into v_me from qm_managers where auth_user_id = auth.uid();
  if not found then raise exception 'Vous ne participez pas à cette saison'; end if;
  select count(*) into v_pending from qm_player_proposals
    where proposer_id = v_me.id and status = 'pending';
  if v_pending >= 3 then
    raise exception 'Vous avez déjà 3 propositions en attente.';
  end if;
  if p_player_id is null and (p_new_name is null or p_new_value is null) then
    raise exception 'Indiquez un joueur existant, ou le nom et la valeur d''un nouveau joueur.';
  end if;
  insert into qm_player_proposals (proposer_id, player_id, new_name, new_position, new_club, new_value)
  values (v_me.id, p_player_id, p_new_name, p_new_position,
          -- on stocke le championnat dans new_club sous forme "Club|Championnat" ? Non : on ajoute une colonne.
          p_new_club, p_new_value)
  returning * into v_prop;
  -- Stocke le championnat proposé
  update qm_player_proposals set new_championship = p_new_championship where id = v_prop.id
  returning * into v_prop;
  return v_prop;
end;
$$;

-- Ajoute la colonne championnat aux propositions
alter table qm_player_proposals add column if not exists new_championship text;

-- Répercute le championnat à la validation d'une proposition
create or replace function qm_admin_approve_proposal(p_proposal_id uuid)
returns qm_auctions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_prop qm_player_proposals; v_player qm_players; v_hours integer; v_auction qm_auctions;
begin
  if not qm_is_admin() then raise exception 'Réservé aux administrateurs'; end if;
  select * into v_prop from qm_player_proposals where id = p_proposal_id for update;
  if not found then raise exception 'Proposition introuvable'; end if;
  if v_prop.status <> 'pending' then raise exception 'Proposition déjà traitée'; end if;

  if v_prop.player_id is not null then
    select * into v_player from qm_players where id = v_prop.player_id for update;
    if v_player.status <> 'free' then raise exception 'Ce joueur n''est plus disponible.'; end if;
  else
    insert into qm_players (name, position, club, base_value, current_value, championship)
    values (v_prop.new_name, coalesce(v_prop.new_position,'MID'), v_prop.new_club,
            v_prop.new_value, v_prop.new_value, v_prop.new_championship)
    returning * into v_player;
  end if;

  select auction_hours into v_hours from qm_season_state where id = 1;
  insert into qm_auctions (player_id, current_price, ends_at, scouted_by)
  values (v_player.id, v_player.current_value, now() + (v_hours || ' hours')::interval, v_prop.proposer_id)
  returning * into v_auction;

  update qm_players set status = 'locked' where id = v_player.id;
  update qm_player_proposals set status='approved', resolved_at=now() where id=p_proposal_id;
  return v_auction;
end;
$$;

-- ---------- Historique complet des transactions (admin) ------------
create or replace function qm_admin_transactions()
returns table (
  player_name text, from_manager text, to_manager text, price bigint, created_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select
    p.name,
    fm.display_name,
    tm.display_name,
    tr.price,
    tr.created_at
  from qm_transfers tr
  join qm_players p on p.id = tr.player_id
  left join qm_managers fm on fm.id = tr.from_manager
  left join qm_managers tm on tm.id = tr.to_manager
  order by tr.created_at desc
  limit 200;
$$;
