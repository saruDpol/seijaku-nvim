<!-- seijaku:metadata:start -->

> Type: `general`
> Created: `2026-09-25T18:33:32+0200`
> Updated: `2026-09-25T19:26:26+0200`
> Target: `/home/sarudpol/main/seijaku`
> Pinned: `true`

<!-- seijaku:metadata:end -->

# plan-seijaku

Farem un refacto del codi a la branca dev, ja creada, per canviar seijaku a un estil com inkdrop de takuya matsuyama

1.  en relacio al sidebar, les notes no seran una fila, seran una instancia, amb metadata., es a dir ocuparan les files que siguin necessaries, i la nota seleccionada, tindra el color de la instancia al sidebar del color del hover de la terminal.

2.  el nom de la nota ocupar tot l'espai necssari

3.  la metadata sera la data de creacio, si estan associats a un file, si estan associades a un notebook, i els tags.

4.  la targeta de la nota permetre visulitzar aquests elements adequadament

5.  ara no tindrem tipos de notes, per tant totes les notes seran iguals., ara les notes simplement tindran tags, i podran estar agrupades per projectes, que direm notebooks

6.  la nova implementacio seran notebooks, aixo seran projectes, grups que agruparan notes. un projecte podra tindre un path associat, una carpeta de treball.

7.  el mode dir desapareixera

8.  el espai que el sidebar necessitara, ara sera mes petit

9.  la nota no heredara res del file/folder/path al que aniran associades, en el setntit de que no tindrem noms per defecte.

10. integrarem a seijaku la info obtinguda amb ninja, per mostrar al mode calendari, una seccio, contigua a la part infoerior del calendari, que representara el fitxage, tant del dia seleccionat, com de la setmana on tenim el cursor

11. valorar la possiblitat d'integrar una bbdd dedicada per al plugin, potser un mongodb necessitarem..

12. seijaku no tindra mes la visualitzacio de la nota a dins del sidebar, sino que nomes tindrem una view per visualitzar les notes que sera com el full layout de ara, sempre hi haura un buffer associat al preview de les notes, si aquest render es tanca, es tancara seijaku.

13. mantindrem la funcionalitat de navegacio de seijaku actual, moviment seguint configuracio de nvim per moures entre panells, al sidebar, podrem filtrar i ordenar seguint tambe el sistema actual, i la naveagacio amb el calendari es mantindra

14. al crear una nota, en comptes d'escollir el tipo de nota (com fem ara) s'escollira una plantilla, projecte, i tag

15. els todos tambe desapareixeran, i s'introduiran dins de notes dedicades

16. a les notes, al modo insert de nvim, i amb la tecla '/', es sugeriran afegir items, com taules, o llistes de todos., aixo sembla que ja es funcional, pero ho revisarem 14. mantindrem icones minimalistes pero millorats

17. totes les notes tindran els mateixos colors, i els colors especifics seran per projecte, i per etiqueta, que quedaran com iconos al sidebar, o com blocs header a dins del document com tenim ara

18. les notes es podran posar pinned

19. mantindrem dins del sidebar el fucnionament de telescope per buscar notes

a partir d'aquestes especificacions, crea un pla de desenvolupament de com hauriem d'atacar el codi, fases necessaries, buscant estabilitazar el plugin a una nova versio, sense mantindre dead code, i fent el sistema mes funcinal en la direccio que es descriu
