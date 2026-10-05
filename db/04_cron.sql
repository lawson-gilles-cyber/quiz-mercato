-- =====================================================================
-- QUIZ MERCATO — Programmation du cron de clôture
-- =====================================================================
-- Deux options. Choisis-en UNE.
-- =====================================================================

-- ---------------------------------------------------------------------
-- OPTION A (recommandée) : pg_cron appelle directement qm_close_auction
-- en SQL, sans passer par l'Edge Function. Plus simple, tout en base.
-- ---------------------------------------------------------------------
create extension if not exists pg_cron;

-- Fonction balai : clôt toutes les enchères expirées d'un coup
create or replace function qm_sweep_expired_auctions()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row qm_auctions;
  v_count integer := 0;
begin
  for v_row in
    select * from qm_auctions
    where status = 'open' and ends_at < now()
    for update skip locked      -- ignore les lignes déjà verrouillées par une offre en cours
  loop
    perform qm_close_auction(v_row.id);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- Exécution toutes les minutes
select cron.schedule(
  'sweep-qm_auctions',
  '* * * * *',
  $$ select qm_sweep_expired_auctions(); $$
);

-- Pour arrêter plus tard : select cron.unschedule('sweep-qm_auctions');

-- ---------------------------------------------------------------------
-- OPTION B : pg_cron appelle l'Edge Function via HTTP (extension pg_net)
-- À utiliser seulement si tu veux de la logique en TypeScript à la clôture
-- (notifications, webhooks…). Sinon reste sur l'option A.
-- ---------------------------------------------------------------------
-- create extension if not exists pg_net;
-- select cron.schedule('sweep-qm_auctions-edge', '* * * * *', $$
--   select net.http_post(
--     url    := 'https://TON_PROJET.supabase.co/functions/v1/close-qm_auctions',
--     headers:= jsonb_build_object('Authorization','Bearer '||current_setting('app.cron_secret')),
--     body   := '{}'::jsonb
--   );
-- $$);
