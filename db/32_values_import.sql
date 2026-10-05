-- =====================================================================
-- ULTIMATE SQUAD — Mise à jour des valeurs (Transfermarkt assist)
-- =====================================================================
-- Deux fonctions admin pour saisir/importer les valeurs marchandes
-- (relevées manuellement sur Transfermarkt) :
--   1. qm_admin_set_value  : met à jour la valeur d'UN joueur.
--   2. qm_admin_bulk_values : applique une liste "nom = valeur" d'un coup.
--
-- On ne met à jour que current_value ET base_value des joueurs LIBRES
-- (on ne retouche pas le prix d'un joueur déjà acheté par un manager).
-- Le salaire et la note (critère "valeur") suivent automatiquement le prix.
--
-- À passer quand tu veux (indépendant). Réservé admin.
-- =====================================================================

-- ---------- 1. Valeur d'un seul joueur -----------------------------
create or replace function qm_admin_set_value(p_id uuid, p_value bigint)
returns qm_players
language plpgsql
security definer
set search_path = public
as $$
declare v_player qm_players;
begin
  if not qm_is_admin() then raise exception 'Réservé aux administrateurs'; end if;
  if p_value < 0 then raise exception 'Valeur invalide'; end if;
  select * into v_player from qm_players where id = p_id;
  if not found then raise exception 'Joueur introuvable'; end if;
  if v_player.owner_id is not null then
    raise exception 'Ce joueur appartient à un manager : sa valeur ne peut pas être modifiée ici.';
  end if;
  update qm_players set current_value = p_value, base_value = p_value
    where id = p_id returning * into v_player;
  return v_player;
end;
$$;

revoke execute on function qm_admin_set_value(uuid, bigint) from anon;

-- ---------- 2. Import en masse : liste de (nom, valeur) -------------
-- Reçoit un JSON tableau : [{"name":"Mbappé","value":180000000}, ...]
-- Applique la valeur au joueur LIBRE dont le nom correspond (insensible
-- à la casse et aux espaces). Renvoie le nombre de joueurs mis à jour
-- et la liste des noms NON trouvés (pour que l'admin corrige).
create or replace function qm_admin_bulk_values(p_data jsonb)
returns table (updated integer, not_found text[])
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item jsonb;
  v_name text;
  v_value bigint;
  v_count integer := 0;
  v_missing text[] := array[]::text[];
  v_matched integer;
begin
  if not qm_is_admin() then raise exception 'Réservé aux administrateurs'; end if;

  for v_item in select * from jsonb_array_elements(p_data)
  loop
    v_name := trim(v_item->>'name');
    v_value := (v_item->>'value')::bigint;
    if v_name is null or v_name = '' or v_value is null or v_value < 0 then
      continue;
    end if;

    -- match sur nom (insensible casse/espaces), joueurs libres uniquement
    update qm_players
      set current_value = v_value, base_value = v_value
      where owner_id is null
        and lower(regexp_replace(name, '\s+', ' ', 'g')) = lower(regexp_replace(v_name, '\s+', ' ', 'g'));
    get diagnostics v_matched = row_count;

    if v_matched > 0 then
      v_count := v_count + v_matched;
    else
      v_missing := array_append(v_missing, v_name);
    end if;
  end loop;

  updated := v_count;
  not_found := v_missing;
  return next;
end;
$$;

revoke execute on function qm_admin_bulk_values(jsonb) from anon;
