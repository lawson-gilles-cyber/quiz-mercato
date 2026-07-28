# Quiz Mercato

Plateforme de mercato fantasy adossée aux quiz. Les participants sont des
**managers** qui achètent de vrais joueurs de foot aux enchères, constituent
un effectif de 24, et marquent des points via leurs performances dans les quiz.

- **Stack :** Vanilla JS + Supabase (base FHAF partagée, tables préfixées `qm_`)
- **Modèle de points :** adossé aux quiz (autonome, aucune API sportive payante)
- **Valeurs joueurs :** saisies par l'admin, évoluent selon la demande interne
  (pas de scraping Transfermarkt)

---

## Organigramme du projet

```
quiz-mercato/
│
├── README.md                    ← ce fichier (organigramme + avancement)
│
├── db/                          ← scripts SQL (à exécuter DANS L'ORDRE)
│   ├── 01_schema.sql            ✅ tables, types, fonctions (préfixe qm_)
│   ├── 02_rpc_auctions.sql      ✅ logique d'enchères atomique (anti-race-condition)
│   ├── 03_rls.sql               ✅ sécurité : lecture publique, écriture via RPC only
│   └── 04_cron.sql              ✅ clôture automatique des enchères (pg_cron)
│
├── js/
│   └── api.js                   ✅ couche client Supabase (auth, lectures, RPC, Realtime)
│
├── edge/
│   └── close-auctions.ts        ✅ Edge Function de clôture (option B, secours)
│
└── quiz-mercato.html            ✅ interface complète (mode démo, design Kanban)
```

Légende : ✅ fait · 🚧 en cours · ⬜ à faire

---

## Objets créés dans la base (tous préfixés `qm_`)

Tout est isolé des tables FHAF existantes. Rien ne touche aux données FHAF.

**Tables**
`qm_managers` · `qm_players` · `qm_auctions` · `qm_bids` · `qm_transfers`
· `qm_season_state` · `qm_manager_cards`

**Types (enums)**
`qm_player_position` · `qm_player_status` · `qm_auction_status`
· `qm_mercato_phase` · `qm_special_card`

**Fonctions**
`qm_manager_available_budget` · `qm_player_rarity` · `qm_min_increment`
· `qm_open_auction` · `qm_place_bid` · `qm_close_auction`
· `qm_sweep_expired_auctions`

**Le cœur du système : `qm_place_bid`**
Verrouille l'enchère (`FOR UPDATE`), vérifie le budget disponible, libère les
fonds de l'ancien enchérisseur, bloque ceux du nouveau, applique l'anti-snipe
(+10 min si offre dans les 10 dernières minutes). Impossible en no-code —
c'est ce qui rend les enchères concurrentes fiables.

---

## Déploiement — étapes

### 1. Base de données (Supabase FHAF existant)
Dans *SQL Editor*, exécuter dans l'ordre : `01` → `02` → `03` → `04`.
Pour `04`, activer d'abord l'extension **pg_cron** (*Database → Extensions*).

### 2. Brancher `api.js`
Renseigner en haut du fichier :
```js
const SUPABASE_URL  = 'https://<projet-fhaf>.supabase.co';
const SUPABASE_ANON = '<anon_key>';
```

### 3. Mise en ligne du front
Dépôt Git → Cloudflare Pages (cohérent avec le workflow FHAF) ou Vercel.
Site statique : aucun build nécessaire.

---

## Reste à construire

- ⬜ **Lien quiz → points** : fonction qui convertit les perfs quiz FHAF en
  `season_points` des managers (facilité par la base partagée).
- ⬜ **Évolution automatique de `current_value`** selon `demand_score`.
- ⬜ **Tableau d'administration** : ajouter joueurs, ouvrir/fermer le mercato,
  corriger un budget.
- ⬜ **Branchement réel du HTML** : remplacer les données démo par les appels
  `api.js`.
- ⬜ **Cartes spéciales** : logique d'application (Capitaine, Jeune prodige,
  Mur défensif, Joker mercato).

---

## Règlement (V1, d'après Audrey)

- 20 managers max · budget 700 M€ · 24 joueurs (max 3 gardiens)
- Enchères 48 h · anti-snipe +10 min · dernier enchérisseur remporte
- Mise minimale selon la valeur (barème dans `qm_min_increment`)
- Rareté : Bronze / Argent / Or / Platine / Légende (dans `qm_player_rarity`)
- Un joueur = un seul manager
