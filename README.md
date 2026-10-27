# Princeton Offense Trener

Gra na telefon do nauki zagrywek Princeton Offense (Low Post, Point, Chin) z rankingiem drużyny.

| Plik | Do czego |
|---|---|
| `index.html` | cała gra |
| `config.js` | adres i klucz publiczny projektu Supabase |
| `supabase.sql` | tabela graczy, widok rankingu i funkcje zapisu, uruchamiane raz w Supabase |

## Jak to działa

- Gracz zakłada konto ksywką i 4-cyfrowym PIN-em. PIN jest w bazie zahashowany.
- Przeglądarka nie ma dostępu do tabeli `players`. Czyta widok `leaderboard` (bez PIN-ów i tokenów),
  a zapisuje wyniki tylko funkcją `record_play`, która przycina wartości niemożliwe do zdobycia w grze.
- Ranking „Punkty”: suma najlepszych wyników z 15 sytuacji plus rekord z triggerów.
- Ranking „Tryhard”: liczba rozegranych gier, potem liczba odpowiedzi.

Wyniki liczy telefon, więc ktoś z umiejętnościami mógłby dopisać sobie punkty w granicach limitów.

## Obsługa

**Reset PIN-u gracza** (Supabase → SQL Editor):

```sql
update public.players
set pin_hash = extensions.crypt('1234', extensions.gen_salt('bf')), failed = 0, locked_until = null
where lower(nick) = lower('Kowal');
```

**Usunięcie gracza:**

```sql
delete from public.players where lower(nick) = lower('Kowal');
```

**Wyzerowanie sezonu** (gracze zostają, wyniki znikają):

```sql
update public.players
set best = '{}', stars = '{}', trig = 0, total = 0, games = 0, watched = 0,
    answers = 0, correct = 0, play_ms = 0, days = '{}';
```

Darmowy projekt Supabase usypia się po tygodniu bez ruchu. Wtedy wejdź na supabase.com i kliknij „Restore project”.
