-- =====================================================================
-- QUIZ MERCATO — Notation QM par attributs de compétence
-- =====================================================================
-- Système propriétaire, indépendant de FIFA/EA. 7 attributs sur 100,
-- saisis à la main (comme un scout). La note globale (rating_qm) est
-- CALCULÉE par pondération selon le poste, et reste CACHÉE côté public :
-- les managers ne voient que les attributs, pas la note finale.
-- Aucune dépendance à des stats externes.
-- =====================================================================

-- ---------- Colonnes d'attributs (0-100, défaut 50) ------------------
alter table qm_players add column if not exists attr_finition    smallint not null default 50;
alter table qm_players add column if not exists attr_creativite   smallint not null default 50;
alter table qm_players add column if not exists attr_vitesse      smallint not null default 50;
alter table qm_players add column if not exists attr_intelligence smallint not null default 50;
alter table qm_players add column if not exists attr_physique     smallint not null default 50;
alter table qm_players add column if not exists attr_defense      smallint not null default 50;
alter table qm_players add column if not exists attr_regularite   smallint not null default 50;

-- Bornes : chaque attribut reste entre 0 et 100
alter table qm_players drop constraint if exists qm_attr_bounds;
alter table qm_players add constraint qm_attr_bounds check (
  attr_finition between 0 and 100 and attr_creativite between 0 and 100 and
  attr_vitesse between 0 and 100 and attr_intelligence between 0 and 100 and
  attr_physique between 0 and 100 and attr_defense between 0 and 100 and
  attr_regularite between 0 and 100
);

-- ---------- Calcul de la note globale QM selon le poste ---------------
-- Pondérations distinctes par poste : un attaquant est jugé sur sa
-- finition, un défenseur sur sa défense, etc. La régularité compte
-- partout. Somme des poids = 100 pour chaque poste.
create or replace function qm_rating(p qm_players)
returns smallint
language sql
immutable
as $$
  select round(
    case p.position
      when 'FWD' then
        p.attr_finition*0.32 + p.attr_creativite*0.18 + p.attr_vitesse*0.18
        + p.attr_intelligence*0.12 + p.attr_physique*0.08 + p.attr_defense*0.02
        + p.attr_regularite*0.10
      when 'MID' then
        p.attr_finition*0.12 + p.attr_creativite*0.28 + p.attr_vitesse*0.10
        + p.attr_intelligence*0.26 + p.attr_physique*0.06 + p.attr_defense*0.08
        + p.attr_regularite*0.10
      when 'DEF' then
        p.attr_finition*0.03 + p.attr_creativite*0.07 + p.attr_vitesse*0.15
        + p.attr_intelligence*0.20 + p.attr_physique*0.20 + p.attr_defense*0.25
        + p.attr_regularite*0.10
      when 'GK' then
        -- Pour un gardien : "finition"=jeu au pied, "défense"=réflexes/arrêts,
        -- "intelligence"=placement, "physique"=détente. Lecture adaptée.
        p.attr_finition*0.08 + p.attr_creativite*0.05 + p.attr_vitesse*0.05
        + p.attr_intelligence*0.25 + p.attr_physique*0.17 + p.attr_defense*0.30
        + p.attr_regularite*0.10
    end
  )::smallint;
$$;

-- ---------- Vue publique : attributs visibles, note globale MASQUÉE ---
-- Le front lit cette vue pour ne jamais exposer rating_qm directement.
-- (La note globale reste calculable côté admin.)
create or replace view qm_players_public as
  select
    id, name, position, club, nationality, age, photo_url,
    base_value, current_value, owner_id, status, demand_score,
    attr_finition, attr_creativite, attr_vitesse, attr_intelligence,
    attr_physique, attr_defense, attr_regularite
    -- note : PAS de qm_rating ici, volontairement masqué au public
  from qm_players;

-- ---------- RPC admin : mettre à jour les attributs -------------------
create or replace function qm_admin_set_attributes(
  p_id uuid,
  p_finition smallint, p_creativite smallint, p_vitesse smallint,
  p_intelligence smallint, p_physique smallint, p_defense smallint,
  p_regularite smallint
)
returns qm_players
language plpgsql
security definer
set search_path = public
as $$
declare v_player qm_players;
begin
  if not qm_is_admin() then
    raise exception 'Réservé aux administrateurs';
  end if;
  update qm_players set
    attr_finition = p_finition, attr_creativite = p_creativite,
    attr_vitesse = p_vitesse, attr_intelligence = p_intelligence,
    attr_physique = p_physique, attr_defense = p_defense,
    attr_regularite = p_regularite
  where id = p_id
  returning * into v_player;
  if not found then raise exception 'Joueur introuvable'; end if;
  return v_player;
end;
$$;

-- ---------- RPC admin : lire la note globale d'un joueur --------------
-- Réservé admin — permet de voir la note QM calculée (invisible au public).
create or replace function qm_admin_rating(p_id uuid)
returns smallint
language plpgsql
security definer
set search_path = public
as $$
declare v_player qm_players;
begin
  if not qm_is_admin() then
    raise exception 'Réservé aux administrateurs';
  end if;
  select * into v_player from qm_players where id = p_id;
  return qm_rating(v_player);
end;
$$;

-- =====================================================================
-- Note : mise à jour mensuelle des attributs = tu ré-exécutes
-- qm_admin_set_attributes depuis la console admin quand tu veux faire
-- évoluer un joueur (ex. un jeune qui progresse). Rien d'automatique,
-- 100 % sous ton contrôle, zéro dépendance externe.
-- =====================================================================
