-- =====================================================================
-- ULTIMATE SQUAD — Thème personnalisable (3 couleurs)
-- =====================================================================
-- L'admin peut personnaliser 3 couleurs clés du site :
--   * theme_accent : couleur d'accent (boutons, prix, éléments clés)
--   * theme_bg     : fond principal (ambiance générale)
--   * theme_title  : couleur des titres et accents de texte
--
-- Ces couleurs sont lues au chargement du site et surchargent les
-- variables CSS. Si elles sont nulles, le thème par défaut s'applique.
-- Un reset consiste à les remettre à null.
--
-- À passer APRÈS 17_bonuses.sql (ou à tout moment, indépendant).
-- =====================================================================

alter table qm_season_state add column if not exists theme_accent text;
alter table qm_season_state add column if not exists theme_bg text;
alter table qm_season_state add column if not exists theme_title text;

-- ---------- Lecture publique du thème (pour tous les visiteurs) ------
-- Accessible sans authentification : le thème doit s'appliquer même
-- avant connexion.
create or replace function qm_get_theme()
returns table (accent text, bg text, title text)
language sql
stable
security definer
set search_path = public
as $$
  select theme_accent, theme_bg, theme_title
  from qm_season_state where id = 1;
$$;

-- ---------- Réglage admin -------------------------------------------
-- Passer null sur une couleur = revenir au défaut pour celle-ci.
create or replace function qm_admin_set_theme(
  p_accent text, p_bg text, p_title text
)
returns qm_season_state
language plpgsql
security definer
set search_path = public
as $$
declare v_state qm_season_state;
begin
  if not qm_is_admin() then raise exception 'Réservé aux administrateurs'; end if;

  -- Validation basique : couleur hex #rgb ou #rrggbb, ou null
  if p_accent is not null and p_accent !~ '^#[0-9a-fA-F]{3,8}$' then
    raise exception 'Couleur accent invalide (format attendu : #RRGGBB)';
  end if;
  if p_bg is not null and p_bg !~ '^#[0-9a-fA-F]{3,8}$' then
    raise exception 'Couleur fond invalide (format attendu : #RRGGBB)';
  end if;
  if p_title is not null and p_title !~ '^#[0-9a-fA-F]{3,8}$' then
    raise exception 'Couleur titre invalide (format attendu : #RRGGBB)';
  end if;

  update qm_season_state
    set theme_accent = p_accent, theme_bg = p_bg, theme_title = p_title,
        updated_at = now()
    where id = 1 returning * into v_state;
  return v_state;
end;
$$;

-- Autoriser tout le monde (y compris anonyme) à lire le thème
grant execute on function qm_get_theme() to anon, authenticated;
