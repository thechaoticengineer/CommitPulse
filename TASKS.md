# CommitPulse — panel statystyk contributions

Status: **zadanie 0 — naprawa otwierania panelu — zaakceptowane ręcznie przez
użytkownika i zamknięte na jego polecenie**. Zadania redesignu 1–5 pozostają zapisane na później, bez zgody
na uruchomienie. Użytkownik osobno naprawia ReviewBox; nie zakłócać tej pracy.

## Kierunek

Wzorcem jest pokazany przez użytkownika panel zużycia Codexa w Omarchy: ciemne tło,
monospace, wyraźny nagłówek, oddzielone sekcje, wyrównane liczby i poziome słupki.
Przenosimy sposób prezentacji na GitHub contributions. Technologia pozostaje
**Quickshell/QML + Go**, a wszystkie role w Forge mają używać wyłącznie Codexa.

Proponowany układ: nagłówek CommitPulse → podsumowanie Dziś / Tydzień / Miesiąc /
Rok → aktywność z ostatnich 7 dni → aktywność miesięczna bieżącego roku → dyskretny
czas aktualizacji i akcje. Licznik w pasku pozostaje wejściem do pełnego panelu;
tooltip służy jedynie krótkiej podpowiedzi.

## 0. Naprawa otwierania istniejącego panelu

Użytkownik potwierdził działanie zainstalowanego panelu i polecił opublikować oraz
zamknąć poprawkę. Automatyczne review pozostało zablokowane: compositorowy test
regresji nie przechodził stabilnie, a ostatnią próbę przerwała niedostępność usługi
Codexa. Akceptacja użytkownika nie oznacza zaliczenia tych kontroli. Szczegóły
i zachowane ograniczenia: [raport naprawy](docs/panel-opening-repair.md).

Użytkownik potwierdził, że kliknięcie licznika nie otwierało żadnego panelu — widoczny
był jedynie tooltip. Problem był niezależny od oczekiwanego redesignu. Przyczyną
była utrata obserwowanego katalogu pluginu podczas aktualizacji i zatruty adres
komponentu w długo działającym procesie powłoki; naprawa zachowuje inode katalogu,
przełącza manifest jako ostatni plik i używa nowych adresów komponentów.

- [x] Odtworzyć kliknięcie na faktycznie zainstalowanym widgetcie w sesji Omarchy.
  Porównać zainstalowane pliki z wersją w repozytorium, zanim zmieni się kod.
- [x] Prześledzić obsługę kliknięcia w BarWidget.qml, togglePanel(), panelLoader,
  inicjalizację Panel.qml, kontroler widoczności i kotwiczenie. Sprawdzić właściwy
  kontrakt panelu/IPC w zainstalowanej wersji Omarchy.
- [x] Sprawdzić błędy Quickshell/QML w chwili kliknięcia: nieudane ładowanie,
  brakujące właściwości/importy, niewidoczne okno lub nieprawidłową pozycję.
  Czytać ograniczone fragmenty logów; nie zakładać przyczyny bez dowodów.
- [x] Naprawić potwierdzoną przyczynę i dodać celowany test regresji. Sam test
  helpera Go, poprawność manifestu lub tooltip nie potwierdzają otwierania panelu.
- [x] Zweryfikować rzeczywiste otwarcie i zamknięcie panelu z paska oraz ponowne
  otwarcie, w tym bez danych GitHub. Zapisać przyczynę i dowody naprawy.

**Warunek ukończenia:** kliknięcie widgetu rzeczywiście pokazuje panel w Omarchy;
działają zamknięcie i ponowne otwarcie. Użytkownik zezwolił teraz na naprawę i niezbędną
aktualizację zainstalowanego pluginu CommitPulse. Nie restartować silnika Forge,
nie resetować konfiguracji Omarchy i nie uruchamiać przy tym redesignu.

## 1. Układ i wygląd panelu na danych demonstracyjnych

Zależność: zadanie 0 — najpierw działające otwieranie panelu.

- [ ] Obejrzeć implementację istniejącego panelu zużycia Codexa w zainstalowanym
  Omarchy jako wzorzec odstępów, szerokości, typografii i separatorów.
- [ ] Przygotować w QML pełny panel z nagłówkiem, czterema licznikami, sekcjami
  wykresów i stopką. Korzystać z motywu Omarchy, nie zakodowanej palety.
- [ ] Dopasować szerokość do wzorca (około 360–400 logicznych pikseli), z limitem
  wynikającym z dostępnego ekranu i przewijaniem przy małej wysokości.
- [ ] Użyć fikcyjnych danych wyłącznie w trybie demo. Przygotować podgląd/screenshot
  tego trybu do oceny wyglądu, bez zmieniania zainstalowanego widgetu.

**Warunek ukończenia:** podgląd przypomina panel statystyk z referencji; wartości,
etykiety i sekcje są czytelne, a panel mieści się również na mniejszym ekranie.
Nie oznaczać danych demonstracyjnych jako rzeczywistych.

## 2. Dane dzienne i miesięczne w pomocniku Go

Zależność: układ z zadania 1 określa potrzebny zakres danych.

- [ ] Rozszerzyć istniejące obliczenia kalendarza o ostatnie 7 dni, włącznie
  z dzisiaj, oraz miesiące bieżącego roku do aktualnego miesiąca.
- [ ] Wykorzystać pobierany kalendarz GitHub; uwzględnić poprzedni rok, jeśli
  zakres siedmiu dni przekracza 1 stycznia. Unikać osobnego pobierania dla sekcji.
- [ ] Określić kontrakt dat, wartości i kompletności danych. Brak danych nie jest
  zerem; bieżący dzień i miesiąc są okresami jeszcze niezakończonymi.
- [ ] Zaplanować zgodną zmianę kontraktu helper → QML oraz cache. Obecny
  ContributionState.js odrzuca dodatkowe pola i wersje inne niż schemaVersion=1;
  sam dodatek po stronie Go zepsułby aktualny widget. Przy zmianie wersji zapewnić
  obsługę poprzedniej lub kontrolowane przejście bez utraty ostatnich sum.
- [ ] Sprawdzić granice roku/miesiąca, rok przestępny, dni zerowe, brakujące dane,
  kolejność próbek i zgodność miesięcznych agregatów z licznikiem roku.

**Warunek ukończenia:** helper dostarcza deterministyczne serie wraz z czterema
dotychczasowymi sumami; istniejący działający interfejs zachowuje zgodność.

## 3. Wykresy na rzeczywistych danych

Zależności: zadania 1 i 2.

- [ ] Podłączyć nowy panel do istniejącego wspólnego DataController; otwarcie
  panelu nie może tworzyć drugiego helpera ani dodatkowego cyklu odświeżania.
- [ ] Pokazać ostatnie 7 dni jako wiersze: dzień/data, poziomy słupek, liczba.
  Wyróżnić dzisiejszy dzień podobnie jak „Today” na referencji.
- [ ] Pokazać miesiące bieżącego roku w analogicznej sekcji i zaznaczyć, że
  aktualny miesiąc jeszcze trwa. Nie przedstawiać przyszłych miesięcy jako zer.
- [ ] Skalować słupki do największej wartości we własnej sekcji. Zachować dokładne
  liczby, sensowną prezentację samych zer i wyjaśnienie skali. Nie tworzyć fikcyjnych
  limitów, procentów realizacji ani celu aktywności.
- [ ] Zachować odświeżanie co 15 minut, ręczny refresh i ochronę przed nakładającymi
  się zapytaniami. Dane prywatne nie mogą trafiać do publicznych fixture ani logów.

**Warunek ukończenia:** cztery sumy i oba wykresy przedstawiają tę samą rzeczywistą
próbkę danych; demo nadal działa bez GitHuba i bez zapisu danych użytkownika.

## 4. Obsługa panelu i stany błędów

Zależność: zadanie 3.

- [ ] Sprawdzić otwieranie kliknięciem licznika, zamykanie Escape/kliknięciem poza
  panelem, kotwiczenie przy pasku oraz brak otwierania panelu poza ekranem.
- [ ] Zachować klawiaturowy dostęp do akcji, widoczny fokus i przewijanie treści.
- [ ] Ujednolicić loading, refresh, stale, offline, brak logowania i rate limit.
  Zachowywać ostatnie poprawne sumy oraz serie; pokazać krótki stan i czas danych.
- [ ] Przy starym cache bez serii pokazać dostępne liczniki i uczciwy brak wykresu.
  Nie zastępować błędu demonstracyjnymi słupkami ani zerami.
- [ ] Sprawdzić duże liczby, same zera, dłuższe etykiety i skalowanie interfejsu.

**Warunek ukończenia:** podstawowy flow działa myszą i klawiaturą; panel pozostaje
czytelny przy błędach, a refresh przestrzega retryAt i blokady równoległych żądań.

## 5. Weryfikacja i przygotowanie aktualizacji

Zależności: zadania 1–4.

- [ ] Uruchomić wymagane testy Go, kontraktu, QML i kontrolera, w tym zgodność
  nowych serii, starego cache oraz stanów błędów.
- [ ] Sprawdzić pełny panel na fikcyjnych danych w normalnym i małym rozmiarze;
  przygotować końcowy screenshot demonstracyjny do porównania z referencją.
- [ ] Sprawdzić instalację/aktualizację/usunięcie w izolowanej konfiguracji,
  z zachowaniem istniejących zabezpieczeń i backupów.
- [ ] Uaktualnić README: wygląd, zakresy dat, skala słupków, niepełny bieżący okres,
  odświeżanie i polecenie aktualizacji już zainstalowanej wersji.
- [ ] Przygotować wynik do review i późniejszej instalacji. Instalację w działającym
  Omarchy oraz publikację wykonywać dopiero zgodnie z instrukcją użytkownika
  przy ponownym uruchomieniu prac; obecnie niczego nie uruchamiać.

**Warunek ukończenia:** sprawdzony pakiet aktualizacji i podgląd są gotowe do oceny,
a dokumentacja opisuje faktycznie działający panel.

## Przekazanie do Forge później

Po decyzji użytkownika dodać sześć zadań w powyższej kolejności, zaczynając od
diagnozy otwierania panelu (zadanie 0). Przed startem po
ewentualnym restarcie sprawdzić stan projektu i ustawienia wszystkich ról Codexa;
ustawienia procesowe Forge mogą wymagać ponownego ustawienia. Nie przywracać
wyłączonego watchera ani automatycznych napraw na podstawie samej tej listy.
