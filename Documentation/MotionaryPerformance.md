# Motionary-Performance

## Messung

Release-Build mit Xcode 27.2 auf einem Apple M4. Der Vorher-nachher-Vergleich lief auf dem iPhone-17-Simulator mit iOS 26.3.1. Der Referenzstand ist `cb23e1af` auf `codex/motionary-pre-performance`. Er enthält den vorherigen Arbeitsstand einschließlich der zehn lokalen Änderungen.

| Messung | Vorher | Nachher |
| --- | ---: | ---: |
| Playhead im Editor-Modell bei 2.400 Cuts, Median / p95 | 2,098 / 2,790 ms | 0,00042 / 0,00046 ms |
| Effektregler im Editor-Modell bei 2.400 Cuts, Median / p95 | 2,791 / 3,249 ms | 0,060 / 0,067 ms |
| Descriptor-Refresh bei 2.400 versetzten generierten Clips, Median / p95 | 29,34 / 33,10 ms | 8,89 / 10,73 ms |
| AVFoundation-Instruktionen im Projekt mit 2.400 generierten Clips | 2.391 | 1 |
| Exakter Seek mit 14 Ebenen, Median / p95 | 50,68 / 55,16 ms | 44,18 / 48,20 ms |
| Live-Edit bis zum fertigen Pixelbuffer, Median / p95 | 38,08 / 41,82 ms | 33,95 / 37,32 ms |
| H.264-Export des 3-Sekunden-Effektprojekts | 4,82 s | 3,72 s |
| Playback, per AVPlayerItemVideoOutput beobachtete Frames | 90 / 90 | 90 / 90 |

Die Editor-Messung umfasst 580 Playhead- und 780 Regleraufrufe nach dem Aufwärmen. Sie misst den synchronen Teil auf dem Main Thread. Das Renderprojekt hat 144 Formclips auf zwölf Ebenen und zwei Adjustment-Layer. Wave Warp, Displacement Map und Motion Blur mit zwölf Shutter-Samples laufen gleichzeitig bei 960 × 540 und 30 fps. Seek und Live-Edit wurden je 30-mal gemessen. Der Descriptor-Refresh wurde zehnmal nach dem Aufwärmen gemessen. Seek-, Live- und Exportzeiten variierten zwischen Läufen. Der Effektgewinn liegt deutlich unter dem Gewinn im Editor-Modell.

Ein zweites Renderprojekt ergänzt drei gleichzeitig sichtbare H.264-Spuren mit je zwölf Schnitten. Die Preview braucht dort sieben statt 37 AVFoundation-Videospuren einschließlich der Clock. In der Baseline blieb bei einem Sprung länger als zwei Sekunden ein älteres Bild stehen. Drei optimierte Läufe lieferten jeweils 28 von 28 Zielen. Im jüngsten Lauf brauchte die synchrone Eingabeverarbeitung 0,057 ms im Median. Das gerenderte Bild lag nach 44,15 ms im Median und 48,24 ms bei p95 vor. Der Scrub wurde abschließend am exakten Ziel beendet.

## Änderungen

- Der Editor liest die Projektdauer aus einem invalidierbaren Cache. Interaktive Änderungen an bestehenden Clips verwenden den Clip-Index. Der Commit der Geste gleicht die Medienbibliothek ab und schreibt einen Undo-Schritt.
- Generierte Cuts werden weiterhin pro Frame aus dem Zeitindex ausgewertet. AVFoundation erhält eine neue Instruktion, wenn sich die Decoder-Abhängigkeiten ändern. Nicht überlappende Preview-Cuts mit 1×-Tempo derselben Quelle können sich bei ausreichendem zeitlichem Abstand eine Videospur teilen.
- Das CPU-Sampling hat den größten Anteil der Compositor-Arbeit im Motion-Blur-Shutter-Loop gezeigt. Ebenen teilen sich die Szenenplatzierung je Shutter-Zeit. Aufeinanderfolgende kompatible Verzerrungen können eine lineare FP16-Textur direkt weiterreichen. Der Displacement-Pass speichert seine beiden tatsächlich gelesenen FP16-Kanäle und verwendet identische Maps innerhalb des Shutter-Loops erneut. [Apple Metal Feature Set Tables](https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf)
- Beim ersten Decoder-Seek einer Geste wartet AVPlayer auf die Komposition, falls noch kein Frame vorliegt. Der Main Thread nimmt währenddessen weitere Eingaben entgegen.
- Das Timeout-Budget des Preview-Compositors wird pro Instruktionsvorlage berechnet. Zuvor zählte jeder Preview-Frame die Clips und Effekte des gesamten Projekts.

## Bildgleichheit und ältere Laufzeit

Die RGBA-Pixel stimmen in den verglichenen 30 Preview-Frames, 30 Live-Frames und sieben dekodierten Exportframes exakt überein. Im H.264-Projekt stimmen zwölf Preview-Frames mit und ohne Spurwiederverwendung ebenfalls bytegenau überein. Die Samples enthalten Zeitpunkte beiderseits von Schnittgrenzen. Ein zusätzlicher Test vergleicht direkt verkettete Verzerrungen mit separater Rasterisierung bei voller und teilweiser Effektstärke.

Der Wiederholungslauf auf einem iPhone-SE-Simulator der dritten Generation mit iOS 18.6 lieferte im generierten Effektprojekt 90 von 90 Playback-Frames und dieselben drei Pixel-Hashes. Der AVAssetImageGenerator meldete für exakte Seek-Proben mit dekodierten Videoquellen auf dieser Laufzeit `-12815`. Ein bestehender Test reproduzierte diesen Fehler am Sicherungspunkt. Ein erster älterer Exportlauf scheiterte am freien Speicherplatz und lief nach dem Aufräumen erfolgreich durch.

Der erste H.264-Sprung der Geste erreichte auf iOS 18.6 zunächst die Zielzeit ohne neuen Frame. Nach der Korrektur lieferte der AVPlayer-Test alle 28 Ziele. Die Zeit bis zum gerenderten Pixelbuffer betrug 47,35 ms im Median und 51,53 ms bei p95. Der Test für den AVPlayer-Pfad läuft auch auf dieser Version. Die separate Referenzprobe mit dem Bildgenerator läuft auf unterstützten Simulator-Laufzeiten.

Die Messungen nutzen den M4 des Hosts. Sie belegen keine Bildrate auf einem physischen älteren iPhone. Die Scrub-Zeit endet am gerenderten Framebuffer. Die Zeit bis zur tatsächlichen Bildschirmausgabe wurde nicht gemessen.

## Regressionstests

Der finale Release-Lauf auf iOS 26.3.1 bestand alle sieben ausgewählten Tests. Dazu gehören die Performance-Suite, der direkte Texturvergleich und Regressionstests für Decoder-Toleranz und Seek-Koaleszierung. Der anschließende Lauf der PreviewRebuild-Suite bestand alle 53 Tests. Alle 13 UI-Tests für Timeline- und Effektgesten bestanden mit aktivierten Test-Szenen. Der breite Unit-Lauf ergab 379 bestandene und drei fehlgeschlagene Tests. Am Sicherungspunkt traten dieselben Fehler auf.

- `EffectDomainTests.unknownParameterKeyframesSurviveSplitAndTrim`
- `LayerManagementTests.adjustmentSplitAndTrimPreserveLocalKeyframeContinuity`
- `TimelineCornerRadiusTests.backgroundUsesOneRadiusWhenAnObjectApproachesEitherEdge`

## Render-Größe an die Anzeigefläche binden

Die Vorschau rendert höchstens 960 px, selbst auf Geräten, deren
Vorschaufläche nur 750 px breit ist (iPhone 8/SE). Die Fläche wird aus
`GeometryReader` × `displayScale` in `CorePreviewSection` an das
`EditorViewModel` gemeldet und an `CompositionRenderService.preparePreview`
weitergegeben. Das effektive Kap ist `min(960, Anzeige-Maximum)` — die
Ausgabeauflösung steigt nirgends über den bisherigen Stand, und wo die
Fläche kleiner ist, wird exakt in Flächenmaß gerendert statt aus dem
960er-Format hochskaliert. `vectorRenderScale` wird zusätzlich an die
Flächen-Skala begrenzt, sodass Text/Formen nie über die Anzeige hinaus
supergesampelt werden. Ohne Flächenmaß (Tests, Hintergrundbilder) gilt
umgekehrt das vorherige 960er-Verhalten. Export nutzt einen freien Pfad
und ist unverändert.

## Umsetzung auf `perf/preview-performance-optimizations`

Umgesetzt (pixelgleich im Export, per Hash-Tests geprüft):

- Main-Thread: `CMSampleBuffer`-Erstellung in `LivePreviewSampleView` auf
  eigene serielle Queue verlagert (Unary `enqueue` bleibt Main);
  `LivePreviewPresentation.frameTime` wird nur noch bei Zeitwechsel
  publiziert; `TimelineView` in `PreviewTransformCanvas` auf 60 Hz
  gedeckelt; Zeit-Beobachter veröffentlicht nur noch pro Projekt-Frame.
- Redundante CPU: `PreviewFrameMemo` errechnet `previewFrame` und
  `textAnimationSample` pro Pass-Generation einmal statt 3–5-mal; exakter
  Cache-Treffer in `issueLivePreviewFrameRefresh` ersetzt den
  `mutableCopy`-Plus-Seek in vielen Fällen.
- Render-Größe: Anzeigeflächenbindung wie oben; `vectorRenderScale` an die
  Fläche begrenzt.
- Cache & Prefetch: `PreviewFrameCache.frameNear` (±1 Frame, alle
  Revisionen, als reiner Halte-Frame beim Scrub), thermische
  `effectiveLimits` (serious→64 MB/60, fair→96 MB/90), retainte
  Pre-Edit-Frames nach `invalidateComposedFrames` (Revisions-Bump statt
  Löschen); Richtungssensibler `prefetchScrubNeighbors` (2 Frames im
  Leerlauf-After-Traffic über `renderPausedFrame`, thermisch gesperrt);
  One-Generator-Pool für Timeline-Thumbnails (statt `AVURLAsset` +
  Generator je Tile, plus Fallback- dedupliziert); Proxy-Vorwärmen im
  Hintergrund beim Import (`MediaImportService`).
- GPU: Single-Pass-Effektketten teilen eine lineare FP16-Textur
  (statt Rasterize-then-Kernel pro Effekt); verbundene `NonNormal`-Bends
  teilen die Hintergrund-Textur; `EffectTemporalFrameStore` mit Locks pro
  URL und Quali-basierten Budgets (interactive 1 s, balanced 2 s, export
  8 s); `GeneratedRasterPolicy`-Pixelbudget (16M px) vor der Allokation.

Bewusst nicht umgesetzt (mit Begründung):

- `mutableCopy` in `issueLivePreviewFrameRefresh` ganz entfernen: Der
  Aufruf zwingt AVPlayer, das Bild zur selben Zeit neu anzufordern. Der
  Cache-Pfad greift in den häufigsten Interaktionen bereits; der Copy ist
  hier deshalb das letzte Sprungbrett, nicht der Regelfall. Die
  `copy(with:) -> self`-Optimierung macht den Copy billiger als das
  Analyse-Profil annimmt.
- `objectWillChange`-Weiterleitungen in `EditorViewModel` entfernen:
  `SelectionState`/`TimelineState`/`PreviewState` werden von Views, die
  nur das `EditorViewModel` beobachten (Busy-Overlay, Workspace-Control),
  benötigt. Entfernen bricht UI-Aktualisierungen; sauber wäre
  View-Level-Observation, ein Refactoring außerhalb dieses Auftrags.
- 350-ms-Watchdog verlangsamen: würde Stall-Erkennung um bis zu 0,5 s
  verzögern (erkennbare Hänget-Zeit). Scrub-Observer auf 10 Hz senken:
  Playhead würde sichtbar springen; löst stattdessen Frame-Quantisierung.
- Single-CAMetalLayer-Fläche (Phase 3 #12), Decode-Queue-Ringpuffer (#13):
  ersetzt AVPlayer (Playback/Scrub/Export-Synchronisation) durch eine neue
  DisplayLink-Pipeline — außerhalb dieses Auftrags, bei 80 % des Gewinns
  über die Main-Thread-Verlagerung (docht abgedeckt) mit 20 % des Risikos.
  Voller GOP-Prefetch für komprimiertes Video benötigt Decoder-Seeks und
  würde laufende Seeks entreißen (Jitter); die vorhandenen Proxy-/Thumbnail-
  Prefetches decken den gangbaren Teil ab.
- Text/Shape auf GPU via SDF (#14) und YUV-direkt Sampling im Shader (#15):
  würde die Text-Pixel im Vergleich zum Export verrutschen und die
  Farb-Mathematik neu ableiten. Der Text-Raster ist bereits gecached
  (64 Einträge/64 MB), Shapes laufen schon im `motionaryShapeKernel`; die
  Ketten-Fusion (s. o.) fängt den größten Rasterize-x-Umweg ab.
- YUV→RGB Scratch-Pool: bereits gepoolt (`makeScratchTexture`); nichts zu
  tun.
- `rasterizationLock` schärfen: Für den seriellen Render-Queue-
  Architektur-Stand praktisch unkontaktiert (eine Frame-Enkodierung
  gleichzeitig); Schärfen würde `TextLayerRenderer` fadenfest machen ohne
  Gewinn.
- Effekt-Temporal-Timeout auf 16 ms setzen: würde Echo-Trails auf echten
  Geräten praktisch dauernd ausfallen lassen (Decode von 720p-Proxy ≈
  hundert ms); löst das Problem nicht im Ergebnis, nur im Fortschritt.

## Wiederholen

```sh
xcodebuild -project Motionary.xcodeproj -scheme Motionary -configuration Release \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -parallel-testing-enabled NO ENABLE_TESTABILITY=YES \
  -only-testing:MotionaryTests/PerformanceBenchmarkTests test
```

Die Suite schreibt Messwerte und Pixel-Hashes mit dem Präfix `PERF` ins Testlog. Für den Vorher-nachher-Vergleich sollte auf beiden Ständen derselbe Simulator, dieselbe Laufzeit und dasselbe isolierte Testverfahren verwendet werden.

## Rücknahme

Im ursprünglichen Motionary-Arbeitsordner kehrt dieser Befehl nur den Performance-Patch um. Die vorherigen lokalen Änderungen liegen außerhalb dieses Patches.

```sh
git diff --binary codex/motionary-pre-performance codex/motionary-performance | git apply -R
```
