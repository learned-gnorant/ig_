# IG sin Reels

Cliente iOS personal que envuelve `instagram.com` en un `WKWebView` y quita Reels,
Explorar y el scroll infinito de vídeo corto. Se conservan DMs, feed de seguidos,
perfiles y publicación.

- iOS 17+, SwiftUI, Swift. Sin dependencias (solo WebKit + SwiftUI). Sin backend.
- La sesión vive en el dispositivo (`WKWebsiteDataStore.default()`).
- Las reglas están en [`ReelsBlocker/Resources/rules.json`](ReelsBlocker/Resources/rules.json):
  se editan sin tocar Swift.
- Uso privado, sideload con Xcode a dos teléfonos. No va a App Store.

## Estructura

```
ReelsBlocker.xcodeproj
ReelsBlocker/
  ReelsBlockerApp.swift     @main, escena única
  ContentView.swift         contenedor + barra inferior mínima
  WebViewContainer.swift    UIViewRepresentable sobre WKWebView (sesión persistente, UA, inspector)
  WebViewCoordinator.swift  WKNavigationDelegate: bloqueo de rutas, enlaces externos, bridge JS
  BrowserModel.swift        estado compartido (URL, contadores) y acciones de navegación
  RuleStore.swift           carga rules.json + ajustes del panel (UserDefaults)
  ScriptBuilder.swift       genera los WKUserScript a partir de las reglas
  DebugPanel.swift          panel oculto: URL, toggles, recarga, probar selectores
  Resources/rules.json      selectores y rutas
  Resources/blocker.js      el JS inyectado (CSS, guardia SPA, MutationObserver, lock de reel)
tools/js-tests/             tests de blocker.js con jsdom (solo desarrollo)
```

## Cómo funciona

1. La app carga `https://www.instagram.com/`.
2. **`.atDocumentStart`**: se inyecta una hoja de estilo (`adoptedStyleSheets`, no le
   afecta la CSP) que oculta los selectores de `hideSelectors`. Sin flash de Reels.
   En el mismo momento se parchean `history.pushState`/`replaceState` y se escucha
   `popstate`: Instagram es una SPA y no recarga al cambiar de sección.
3. **`.atDocumentEnd`**: `MutationObserver` sobre el documento. Como mucho una pasada
   cada 100 ms, que oculta además los ancestros (`hideAncestorLevels`) y la publicidad.
4. **Swift, `decidePolicyFor`**: cancela cualquier navegación a una ruta prohibida y
   vuelve a `/`. Además se observa `webView.url` (cambia también con `pushState`):
   aunque el JS dejara de funcionar tras un cambio de Meta, las rutas siguen bloqueadas.
5. Enlaces a otros dominios → Safari. Enlaces `instagram://` o a App Store → ignorados.
   Los enlaces universales de instagram.com no abren la app oficial.

### Reel enviado por DM

Un reel individual (`/reel/ID/` o `/reels/ID/`, ver `singleReelPathPattern`) **se
permite** aunque `/reel/` y `/reels/` estén en `blockedPathPrefixes`, pero con el
scroll bloqueado:

- `overflow: hidden` en `<html>`/`<body>` y en los contenedores con scroll que
  envuelven al `<video>`.
- `preventDefault()` en `touchmove` y `wheel` fuera de scrolls "libres" (p. ej. la
  hoja de comentarios sigue funcionando).
- Si Instagram intenta pasar a **otro** reel con `pushState`, se cancela.
- Se ocultan los botones de `reelViewHideSelectors` (siguiente/anterior).

Si se apaga `lockScrollOnReelView`, los reels individuales pasan a estar bloqueados
también.

## rules.json

| Campo | Qué hace |
|---|---|
| `blockedPathPrefixes` | Rutas prohibidas. `"/reels/"` también cubre `"/reels"`. |
| `allowedPathPrefixes` | Excepciones. Por defecto `/explore/search/` para poder buscar perfiles. |
| `singleReelPathPattern` | Regex de un reel individual (se permite con scroll bloqueado). |
| `hideSelectors` | Strings, u objetos `{ "selector": "...", "ancestors": 4 }` para sobrescribir los niveles. |
| `hideAncestorLevels` | Cuántos padres subir antes de ocultar (por defecto). |
| `neverHideInside` | Nunca se oculta nada dentro de estos (p. ej. un reel compartido en un DM). |
| `lockScrollOnReelView` | Activa el reel individual sin scroll. |
| `reelViewHideSelectors` | Se ocultan solo mientras se ve un reel individual. |
| `hideSponsored` / `sponsoredLabels` | Oculta `article` con la etiqueta "Publicidad"/"Sponsored"/… |

Al subir por los ancestros el JS **nunca** oculta `html`, `body`, `main`, `nav`,
`article`, diálogos ni un elemento que contenga más de un enlace/botón. Por eso un
`ancestors` alto es seguro: se para en el ítem de la barra, no se come la barra entera.

### Sobre los selectores

Las clases CSS de Meta están ofuscadas y rotan. **Nunca usar clases.** En orden:

1. `href` — `a[href='/reels/']` es lo más estable.
2. `aria-label` / `alt` — depende del idioma: `Explore` vs `Explorar`. Poner ambos.
3. `role` + estructura — último recurso.

Cambios respecto a la especificación inicial:

- `a[href^='/explore/']` → `a[href='/explore/']`: con `^=` se ocultaban también los
  hashtags de los pies de foto (`/explore/tags/...`). La ruta `/explore/...` sigue
  bloqueada entera salvo la búsqueda.
- Explorar también es la entrada al buscador en la web móvil, así que la barra inferior
  de la app tiene un botón de búsqueda (`/explore/search/`) y otro de mensajes.

## Fase 0 — Primera instalación

Necesitas un Mac con Xcode 15 o posterior y el iPhone con cable.

1. Abre `ReelsBlocker.xcodeproj`.
2. Target **ReelsBlocker → Signing & Capabilities**:
   - **Team**: tu Apple ID (Xcode → Settings → Accounts si no aparece).
   - **Bundle Identifier**: cambia `com.CAMBIAME.reelsblocker` por algo tuyo, p. ej.
     `com.tunombre.reelsblocker`. Tiene que ser único.
3. En el iPhone: Ajustes → Privacidad y seguridad → **Modo de desarrollador** = ON
   (pide reiniciar).
4. Selecciona el iPhone arriba en Xcode y pulsa ▶︎ (⌘R).
5. La primera vez: Ajustes → General → VPN y gestión de dispositivos → confía en tu
   certificado de desarrollador.

### Firma: gratis vs. de pago

| | Apple ID gratuito | Apple Developer Program (99 USD/año) |
|---|---|---|
| Caducidad | **7 días** | **1 año** |
| Reinstalar | Con el iPhone conectado al Mac | Una vez al año |
| Límite | 3 apps por dispositivo | 100 dispositivos |

Para el prototipo vale el gratuito. Para dos teléfonos de uso diario, la cuenta de pago.

## Fase 1 — Comprobar la sesión

1. Inicia sesión en Instagram dentro de la app.
2. Cierra la app desde el multitarea y vuelve a abrirla: tienes que seguir dentro.
   Si no, el data store está mal (debe ser `WKWebsiteDataStore.default()`).
3. Criterio: leer y responder DMs sin volver a iniciar sesión.

Consejo: inicia sesión **una vez** y no cierres sesión. Muchos logins seguidos desde un
"navegador nuevo" hacen que Instagram lo marque como sospechoso.

## Panel de depuración

**Pulsación larga de 2 s en la esquina inferior derecha** (a la derecha del avión de
papel, no hay icono). Incluye:

- URL actual, elementos ocultos, si el reel está fijado, última ruta bloqueada.
- Interruptor general, fijar reel, ocultar publicidad.
- Toggle por cada selector y por cada ruta bloqueada.
- **Probar selector en caliente**: "Resaltar" pinta en rojo 3 s lo que casa y dice
  cuántos hay. "Ocultar y guardar" lo añade a tus reglas (se guarda en el teléfono).
- Recarga normal y forzada (sin caché).
- **Copiar reglas como JSON**: para pasar lo que has arreglado en el teléfono a
  `rules.json` en el repo.

Los ajustes del panel se guardan encima de `rules.json`; "Restablecer" vuelve al JSON
tal cual. No toca la sesión de Instagram.

## Encontrar selectores con Safari Web Inspector

1. iPhone: Ajustes → Apps → Safari → Avanzado → **Inspector web** = ON.
2. Mac: Safari → Ajustes → Avanzado → **Mostrar funciones para desarrolladores web**.
3. Con la app abierta y el cable conectado: Safari → Desarrollo → [tu iPhone] → la
   página de instagram.com.

Desde ahí se inspecciona el DOM real. En la consola:

```js
document.querySelectorAll("a[href='/reels/']")   // ¿casa algo?
__rb.test("svg[aria-label='Reels']")             // lo resalta en rojo en el iPhone
__rb.stats()                                      // ocultos, lock, ruta
__rb.isBlockedPath('/explore/')                   // true
```

La app ya pone `webView.isInspectable = true`.

## Cuando Meta cambie algo

1. Abre el panel → mira "Elementos ocultos". Si es 0 donde antes no lo era, los
   selectores han dejado de casar.
2. Busca el selector nuevo (Web Inspector o probando en el panel).
3. "Ocultar y guardar" → arreglado en ese teléfono sin recompilar.
4. Cuando puedas: "Copiar reglas como JSON", pégalo en `rules.json`, commit y reinstala
   en ambos teléfonos.

Las rutas (`/reels/`, `/explore/`) siguen bloqueadas desde Swift aunque fallen todos los
selectores.

## Fase 7 — Segundo dispositivo

1. Conecta el segundo iPhone al Mac y activa el Modo de desarrollador (Fase 0, paso 3).
2. **Cuenta de pago**: añade el iPhone en Xcode (Window → Devices and Simulators, o
   simplemente selecciónalo y ▶︎; Xcode lo registra solo). Instala con ▶︎.
3. **Apple ID gratuito**: dos opciones:
   - Usar tu Apple ID en Xcode para instalar también en ese teléfono (cuenta para el
     límite de 3 apps de ese dispositivo), o
   - Que la otra persona añada su propio Apple ID en Xcode y use un bundle id distinto.
4. Confía en el certificado (Fase 0, paso 5) e inicia sesión con su cuenta.

### Reinstalar cuando caduca el perfil

Síntoma: la app no abre ("ya no está disponible").

1. Conecta el iPhone al Mac, abre el proyecto, `git pull` si hay reglas nuevas.
2. Selecciona el iPhone y pulsa ▶︎. **No borres la app antes**: instalando encima se
   conservan los datos, así que la sesión de Instagram sigue iniciada.
3. Con Apple ID gratuito, cada 7 días. Pon un recordatorio a los 6.

## Tests

```sh
cd tools/js-tests
npm install    # solo jsdom, para testear; la app no lo lleva
npm test
```

El CI de GitHub (`.github/workflows/ci.yml`) pasa esos tests y compila la app para el
simulador en macOS sin firmar.

## Límites conocidos

- La web tiene menos funciones que la app nativa (cámara, algunas partes de los DMs).
- Si Instagram cambia la estructura del DOM, puede reaparecer algo hasta que se ajuste
  un selector (ver "Cuando Meta cambie algo").
- No se modifica la app de Instagram ni se eluden protecciones: la app usa la web
  pública con la sesión legítima y filtra la presentación, como un bloqueador de
  contenido.

Ideas para más adelante en [IDEAS.md](IDEAS.md).
