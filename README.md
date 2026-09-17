# SnipBatch

Recorte por lotes estilo "Herramienta de Recortes": defines una región **una sola vez** y se
aplica a **todas las imágenes de una carpeta**. Opcionalmente convierte el negro en transparente,
como el "definir color transparente" de Office.

## Uso

Doble clic en **`SnipBatch.bat`**.

1. **Carpeta con las imágenes** → Examinar.
2. **Carpeta donde guardar los recortes** → por defecto una subcarpeta `recortadas` dentro del
   origen; con *Examinar* la pones donde quieras y con *Predeterminada* vuelves a la de por
   defecto. Los originales no se tocan nunca.
3. **Seleccionar región** → se abre la primera imagen a pantalla completa.
4. **Procesar todas.**

## La selección

Arrastra para dibujar el rectángulo. **Al soltar el ratón no se confirma**: la selección queda
viva para ajustarla.

| Acción | Cómo |
|---|---|
| Redimensionar | arrastra cualquiera de los 8 tiradores |
| Mover entera | arrastra desde dentro del rectángulo |
| Afinar 1 píxel | flechas |
| Afinar 10 píxeles | Ctrl + flechas |
| Estirar el borde derecho/inferior | Shift + flechas |
| Confirmar | **Enter** (o doble clic dentro) |
| Empezar de cero | arrastra fuera del rectángulo |
| Cancelar | Esc |

El contador muestra siempre el tamaño en **píxeles reales de la imagen**, no de pantalla: si la
captura es más grande que el monitor se ve reducida, pero una flecha sigue moviendo exactamente
un píxel del recorte.

## Detalles

- **No requiere instalar nada.** Usa PowerShell 5.1, .NET Framework y GDI+, todos incluidos en
  Windows. El `.bat` ya lanza el script con `-ExecutionPolicy Bypass`, así que tampoco hay que
  cambiar la política del sistema.
- **Formatos de entrada:** png, jpg, jpeg, bmp, gif, tif, tiff.
- **Formato de salida:** elegible entre **PNG, JPG y BMP**.
  - *PNG* es el predeterminado y el único que conserva transparencia.
  - *JPG* se guarda a calidad 90 (GDI+ usa 75 por defecto, que ensucia el texto).
  - *JPG y BMP* se aplanan sobre blanco a 24 bits. Al elegirlos, la casilla de transparencia
    se deshabilita sola: así no puedes perder la transparencia sin enterarte. Si vuelves a PNG,
    recupera la marca que tenías.
- **Región definida sobre la primera imagen** (por orden alfabético), no sobre la pantalla en
  vivo. Así las coordenadas son exactas píxel a píxel y ves lo que vas a recortar.
- **Imágenes de distinto tamaño:** si una imagen no mide lo mismo que la de referencia, la región
  se reescala proporcionalmente y el log lo indica. Si aun así queda fuera, esa imagen se salta.
- **Nombres repetidos:** si la carpeta tiene `foto.png` y `foto.jpg`, el segundo recorte se guarda
  como `foto (2).png` en vez de pisar al primero.
- **Tolerancia:** un píxel se vuelve transparente cuando sus canales R, G y B están *todos* por
  debajo del umbral. Con `0` sólo afecta al negro puro; súbela (12-40) si quedan halos oscuros
  alrededor de texto o bordes suavizados.
- **Cerrar durante el proceso** detiene el lote de forma limpia; los recortes ya hechos se quedan.

## Si no se abre

El lanzador oculta la consola, así que un fallo de arranque se avisa con un cuadro de diálogo.
Si ni eso aparece, abre PowerShell en esta carpeta y ejecuta lo siguiente para ver el error:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\SnipBatch.ps1
```

## Archivos

| Archivo | Para qué |
|---|---|
| `SnipBatch.bat` | Lanzador. Es el que se ejecuta. |
| `SnipBatch.ps1` | La herramienta completa: interfaz, selección y procesado. |
| `tests/run-tests.bat` | Ejecuta las 123 pruebas automáticas. |

## Pruebas

Doble clic en `tests/run-tests.bat`. Cubren la geometría de la selección (recortes al borde,
tiradores cruzados, conversión pantalla↔imagen), el recorte, los formatos y la transparencia
(tolerancia, aplanado sobre blanco, calidad JPEG, tamaños distintos, nombres repetidos, archivos
sin bloquear) y la ventana principal (carpeta vacía, unidad inexistente, salida manual, formato
frente a transparencia, cierre a mitad de proceso).

Ninguna abre diálogos ni toca el ratón o el teclado, así que se pueden dejar corriendo.
