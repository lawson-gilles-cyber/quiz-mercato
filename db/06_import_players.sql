-- =====================================================================
-- QUIZ MERCATO — Import catalogue de joueurs (51 joueurs)
-- Valeurs en euros. base_value = current_value au départ. status 'free'.
-- Idempotent : ON CONFLICT ne fait rien si le joueur existe déjà (par nom).
-- =====================================================================

-- Contrainte d'unicité sur le nom pour rendre l'import rejouable sans doublon
create unique index if not exists uq_qm_players_name on qm_players(name);

insert into qm_players (name, position, club, nationality, age, base_value, current_value) values
  ('Gianluigi Donnarumma','GK','Man City','🇮🇹',27,45000000,45000000),
  ('Thibaut Courtois','GK','Real Madrid','🇧🇪',34,30000000,30000000),
  ('Alisson','GK','Liverpool','🇧🇷',33,28000000,28000000),
  ('Ederson','GK','Al-Nassr','🇧🇷',32,18000000,18000000),
  ('Mike Maignan','GK','Chelsea','🇫🇷',31,32000000,32000000),
  ('Unai Simón','GK','Athletic Bilbao','🇪🇸',29,22000000,22000000),
  ('Diogo Costa','GK','Porto','🇵🇹',26,40000000,40000000),
  ('William Saliba','DEF','Arsenal','🇫🇷',25,75000000,75000000),
  ('Achraf Hakimi','DEF','PSG','🇲🇦',27,65000000,65000000),
  ('Josko Gvardiol','DEF','Man City','🇭🇷',24,75000000,75000000),
  ('Alessandro Bastoni','DEF','Inter','🇮🇹',27,70000000,70000000),
  ('Ronald Araújo','DEF','Barcelona','🇺🇾',27,60000000,60000000),
  ('Rúben Dias','DEF','Man City','🇵🇹',29,60000000,60000000),
  ('Virgil van Dijk','DEF','Liverpool','🇳🇱',35,20000000,20000000),
  ('Antonio Rüdiger','DEF','Real Madrid','🇩🇪',33,20000000,20000000),
  ('Alphonso Davies','DEF','Bayern','🇨🇦',25,60000000,60000000),
  ('Theo Hernández','DEF','Al-Hilal','🇫🇷',28,35000000,35000000),
  ('Jules Koundé','DEF','Barcelona','🇫🇷',27,60000000,60000000),
  ('Pau Cubarsí','DEF','Barcelona','🇪🇸',19,80000000,80000000),
  ('Nuno Mendes','DEF','PSG','🇵🇹',24,70000000,70000000),
  ('Trent Alexander-Arnold','DEF','Real Madrid','🏴',28,60000000,60000000),
  ('Jude Bellingham','MID','Real Madrid','🏴',23,150000000,150000000),
  ('Pedri','MID','Barcelona','🇪🇸',23,140000000,140000000),
  ('Florian Wirtz','MID','Liverpool','🇩🇪',23,130000000,130000000),
  ('Declan Rice','MID','Arsenal','🏴',27,110000000,110000000),
  ('Rodri','MID','Man City','🇪🇸',30,110000000,110000000),
  ('Gavi','MID','Barcelona','🇪🇸',22,90000000,90000000),
  ('Bruno Fernandes','MID','Man United','🇵🇹',31,50000000,50000000),
  ('Federico Valverde','MID','Real Madrid','🇺🇾',28,120000000,120000000),
  ('Enzo Fernández','MID','Chelsea','🇦🇷',25,90000000,90000000),
  ('Jamal Musiala','MID','Bayern','🇩🇪',23,140000000,140000000),
  ('Cole Palmer','MID','Chelsea','🏴',24,140000000,140000000),
  ('Vitinha','MID','PSG','🇵🇹',26,90000000,90000000),
  ('Warren Zaïre-Emery','MID','PSG','🇫🇷',20,80000000,80000000),
  ('Kevin De Bruyne','MID','Napoli','🇧🇪',35,25000000,25000000),
  ('Kylian Mbappé','FWD','Real Madrid','🇫🇷',27,180000000,180000000),
  ('Erling Haaland','FWD','Man City','🇳🇴',26,180000000,180000000),
  ('Lamine Yamal','FWD','Barcelona','🇪🇸',19,200000000,200000000),
  ('Vinícius Júnior','FWD','Real Madrid','🇧🇷',26,150000000,150000000),
  ('Bukayo Saka','FWD','Arsenal','🏴',25,140000000,140000000),
  ('Raphinha','FWD','Barcelona','🇧🇷',29,80000000,80000000),
  ('Nico Williams','FWD','Barcelona','🇪🇸',24,75000000,75000000),
  ('Rafael Leão','FWD','Milan','🇵🇹',27,80000000,80000000),
  ('Ousmane Dembélé','FWD','PSG','🇫🇷',29,90000000,90000000),
  ('Julián Álvarez','FWD','Atlético','🇦🇷',26,110000000,110000000),
  ('Victor Osimhen','FWD','Galatasaray','🇳🇬',27,75000000,75000000),
  ('Harry Kane','FWD','Bayern','🏴',33,60000000,60000000),
  ('Mohamed Salah','FWD','Liverpool','🇪🇬',34,35000000,35000000),
  ('Khvicha Kvaratskhelia','FWD','PSG','🇬🇪',25,90000000,90000000),
  ('Alexander Isak','FWD','Liverpool','🇸🇪',27,120000000,120000000),
  ('Désiré Doué','FWD','PSG','🇫🇷',21,100000000,100000000)
on conflict (name) do nothing;

-- Vérification
select position, count(*), min(current_value) as min_val, max(current_value) as max_val
from qm_players group by position order by position;