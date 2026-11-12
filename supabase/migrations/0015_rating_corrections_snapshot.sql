-- One-time rating correction, run directly against the live `players`
-- table via the SQL Editor -- NOT the Edge Functions editor, which is
-- a heavy desktop-style code editor that doesn't work properly on a
-- phone. This mirrors, as closely as SQL can, the two fixes already
-- committed to supabase/functions/sync-sportmonks-players/index.ts
-- (commits "Fix rating overhaul..." and "Add curated rating
-- overrides..."), so the live data is corrected right now even though
-- that updated Edge Function code hasn't been deployed yet.
--
-- IMPORTANT: this is a snapshot fix, not a permanent one. If the
-- sync-sportmonks-players Edge Function runs again on its old,
-- not-yet-deployed code (its own schedule, or someone triggers it by
-- hand), it will recompute ratings with the OLD formula and overwrite
-- these corrections. The real, lasting fix is deploying the updated
-- Edge Function source -- this migration just gets today's data right
-- without needing that deploy first.
--
-- Safe to run more than once: every statement is a plain, idempotent
-- UPDATE (clamping down or setting to the same curated value each
-- time), nothing is inserted or deleted.

-- ---------------------------------------------------------------------
-- 1. Non-elite ceiling: a player not at one of these clubs is capped at
--    87 (spellings verified against this project's own live data).
--    Not minutes-gated here (unlike the Edge Function version) since
--    this table doesn't store minutes played -- a reasonable snapshot
--    approximation, not an exact replay of the formula.
-- ---------------------------------------------------------------------
update public.players
set rating = 87
where active = true
  and rating > 87
  and club not in (
    'Manchester City', 'Arsenal', 'Liverpool', 'Manchester United', 'Chelsea', 'Tottenham Hotspur',
    'Real Madrid', 'FC Barcelona', 'Atlético de Madrid',
    'FC Bayern München', 'Borussia Dortmund',
    'Juventus', 'Inter', 'AC Milan', 'Napoli'
  );

-- ---------------------------------------------------------------------
-- 2. Defensive-position ceiling: Centre Back / Left Back / Right Back
--    cap at 88 regardless of club -- that's specifically where
--    Sportmonks' per-match rating over-rewards raw defensive-action
--    volume (confirmed live: a Centre Back at 93, above Van Dijk's 87).
-- ---------------------------------------------------------------------
update public.players
set rating = 88
where active = true
  and rating > 88
  and position in ('Centre Back', 'Left Back', 'Right Back');

-- ---------------------------------------------------------------------
-- 3. Curated overrides: a hand-picked rating for ~130 recognizable
--    players, matched by exact name, set to match real-world
--    reputation directly rather than derived from match stats at all.
--    Same list as CURATED_RATINGS in the Edge Function source.
-- ---------------------------------------------------------------------
update public.players as p
set rating = v.rating
from (values
  ('Kylian Mbappé', 98),
  ('Erling Haaland', 97),
  ('Vinicius Junior', 96),
  ('Jude Bellingham', 95),
  ('Lamine Yamal', 93),
  ('Rodri', 93),
  ('Pedri', 91),
  ('Florian Wirtz', 90),
  ('Harry Kane', 90),
  ('Mohamed Salah', 90),
  ('Jamal Musiala', 90),
  ('Declan Rice', 89),
  ('Bukayo Saka', 89),
  ('Kevin De Bruyne', 89),
  ('Thibaut Courtois', 89),
  ('Phil Foden', 88),
  ('Cole Palmer', 88),
  ('Martin Ødegaard', 88),
  ('Bruno Fernandes', 88),
  ('Robert Lewandowski', 88),
  ('Gianluigi Donnarumma', 88),
  ('Alisson', 88),
  ('Khvicha Kvaratskhelia', 88),
  ('Jan Oblak', 88),
  ('Lautaro Martínez', 88),
  ('Victor Osimhen', 87),
  ('Bernardo Silva', 87),
  ('Federico Valverde', 87),
  ('Toni Kroos', 87),
  ('Joshua Kimmich', 87),
  ('Virgil van Dijk', 87),
  ('Mike Maignan', 87),
  ('Julián Alvarez', 87),
  ('Nico Williams', 86),
  ('Luka Modrić', 86),
  ('Rúben Dias', 86),
  ('William Saliba', 86),
  ('Alessandro Bastoni', 86),
  ('Achraf Hakimi', 86),
  ('Trent Alexander-Arnold', 86),
  ('Nicolò Barella', 86),
  ('Son Heung-min', 86),
  ('Ousmane Dembélé', 86),
  ('Raphinha', 86),
  ('Antoine Griezmann', 86),
  ('Manuel Neuer', 86),
  ('Alexander Isak', 86),
  ('Emiliano Martínez', 86),
  ('Rafael Leão', 85),
  ('Frenkie de Jong', 85),
  ('Hakan Çalhanoğlu', 85),
  ('Marcus Thuram', 85),
  ('David Raya', 85),
  ('Dayot Upamecano', 85),
  ('Antonio Rüdiger', 85),
  ('Éder Militão', 85),
  ('Gabriel Magalhães', 85),
  ('Federico Dimarco', 85),
  ('Theo Hernández', 85),
  ('Alexis Mac Allister', 85),
  ('İlkay Gündoğan', 85),
  ('Moisés Caicedo', 84),
  ('M. Caicedo', 84),
  ('Enzo Fernández', 84),
  ('Dominik Szoboszlai', 84),
  ('Sandro Tonali', 84),
  ('Nico Schlotterbeck', 83),
  ('Michael Olise', 83),
  ('Luis Díaz', 83),
  ('Casemiro', 83),
  ('Jules Koundé', 83),
  ('Gavi', 83),
  ('Kai Havertz', 83),
  ('Mikel Oyarzabal', 83),
  ('Paulo Dybala', 83),
  ('Dušan Vlahović', 83),
  ('Yann Sommer', 83),
  ('Christian Pulisic', 83),
  ('Marcus Rashford', 83),
  ('Reece James', 83),
  ('Andrew Robertson', 83),
  ('Bruno Guimarães', 83),
  ('Arda Güler', 83),
  ('Aurélien Tchouaméni', 83),
  ('Gregor Kobel', 83),
  ('Ronald Araujo', 83),
  ('Mikel Merino', 82),
  ('Ángel Di María', 82),
  ('Federico Chiesa', 82),
  ('Tijjani Reijnders', 82),
  ('Denzel Dumfries', 82),
  ('Kalidou Koulibaly', 82),
  ('Jack Grealish', 82),
  ('James Maddison', 82),
  ('Gabriel Jesus', 82),
  ('Gabriel Martinelli', 82),
  ('Kyle Walker', 82),
  ('Ibrahima Konaté', 82),
  ('Lisandro Martínez', 82),
  ('Nick Pope', 82),
  ('Ollie Watkins', 82),
  ('João Pedro', 82),
  ('Eberechi Eze', 82),
  ('Dani Olmo', 82),
  ('Eduardo Camavinga', 82),
  ('Dani Carvajal', 82),
  ('Serhou Guirassy', 82),
  ('Granit Xhaka', 82),
  ('Min-jae Kim', 82),
  ('Cody Gakpo', 81),
  ('Ryan Gravenberch', 81),
  ('André Onana', 81),
  ('Sven Botman', 81),
  ('Matheus Cunha', 81),
  ('Marc Guéhi', 81),
  ('Jarrod Bowen', 81),
  ('Pau Cubarsí', 81),
  ('Fermín López', 81),
  ('Takefusa Kubo', 81),
  ('Jonathan Tah', 81),
  ('Wesley Fofana', 80),
  ('Darwin Núñez', 80),
  ('Kieran Trippier', 80),
  ('Bryan Mbeumo', 80),
  ('Pau Torres', 80),
  ('Jarrad Branthwaite', 80),
  ('Lucas Paquetá', 80),
  ('Mohammed Kudus', 80),
  ('Alejandro Balde', 80),
  ('Brahim Díaz', 80),
  ('Marcos Llorente', 80),
  ('Koke', 80),
  ('José María Giménez', 80),
  ('Julian Brandt', 80),
  ('Leroy Sané', 80),
  ('Patrik Schick', 80),
  ('Nicolas Jackson', 79),
  ('Levi Colwill', 79),
  ('Curtis Jones', 79),
  ('Conor Gallagher', 79),
  ('Kobbie Mainoo', 79),
  ('Anthony Gordon', 79),
  ('Morgan Rogers', 79),
  ('Youri Tielemans', 79),
  ('Amadou Onana', 79),
  ('Endrick', 79),
  ('Karim Adeyemi', 79),
  ('Waldemar Anton', 79),
  ('Victor Boniface', 79),
  ('Marcel Sabitzer', 79),
  ('Mykhaylo Mudryk', 79),
  ('Noni Madueke', 78),
  ('Rasmus Højlund', 78),
  ('Diogo Dalot', 78),
  ('Yoane Wissa', 78),
  ('James Tarkowski', 78),
  ('Timo Werner', 78),
  ('Niclas Füllkrug', 78),
  ('Dominic Calvert-Lewin', 77)
) as v(name, rating)
where p.name = v.name and p.active = true;
