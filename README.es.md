# RIMES

[![中文](.github/readme/labels/zh.svg)](README.md) [![English](.github/readme/labels/en.svg)](README.en.md) [![日本語](.github/readme/labels/ja.svg)](README.ja.md) [![한국어](.github/readme/labels/ko.svg)](README.ko.md) [![Español](.github/readme/labels/es.svg)](README.es.md)

En homenaje al espíritu del código abierto, la lógica de entrada en chino de este proyecto se basa en el [motor de método de entrada RIME](https://rime.im/).
Es un método de entrada para varios sistemas operativos. Tres superficies originales, a modo de ranuras, recogen lo que cada persona necesita: 1. un búfer explícito antes de confirmar el texto (Buffer) 2. Capsule, para el historial del portapapeles, capturas de pantalla y una base personal de conocimiento 3. Mailbox, una ventana de conversación para lo que llega de fuera.

Admite esquemas de pinyin completo, doble pinyin, Shengbi, Wubi e inglés, además de la escritura por acordes usada en estenotipia y de la importación personalizada. Para quien empieza, el paquete **incluye** librime y los diccionarios, y se puede usar al instalarlo.

> **RIMES** es el nombre de la arquitectura del proyecto. Los nombres públicos del producto son **Lingxi IME** en inglés, **灵犀输入法** en chino simplificado y **靈犀輸入法** en chino tradicional. Estos nombres ya se utilizan en la ficha de iOS en el App Store.

## Vídeos

- [Bilibili · presentación completa](https://www.bilibili.com/video/BV17XuH6SEDg/)
- [Douyin · demostración del producto](https://www.douyin.com/video/7671078195197742355)

## Qué problema resuelve

Con un solo método de entrada se cubren la traducción, la generación y la revisión del día a día, sin salir de la aplicación en la que estás. El método de entrada y sus complementos se encargan:

- **Buffer** (`⌘⇧B`): un banco de trabajo para el texto antes de confirmarlo. El chino y el inglés entran primero en el búfer. Ahí se puede traducir en tiempo real, o generar y reescribir con el conector de IA elegido. Solo después de confirmar se **entrega de forma explícita** al campo actual.
- **Capsule** (`⌘⇧V`): una barra en la parte inferior de la pantalla. El texto, los enlaces, las imágenes, los archivos y los colores recién copiados aparecen en Recientes. Lo que quieras conservar pasa a notas, imágenes, PDF, habilidades o contraseñas.
- **Mailbox** (`⌘⇧M`): las conversaciones de IA, las notas y los envíos externos pendientes de revisión se quedan en esta ventana. Puedes abrir una conversación y elegir un conector ya configurado.

## Sobre las funciones principales

> Tras la instalación y al entrar en una sesión gráfica, una tarea de fondo de una sola vez arranca el mismo proceso de RIMES con `open -g`. Por eso los atajos globales de Buffer, Clipboard History, Mailbox y Capsule funcionan con cualquier método de entrada.
>
> Antes de sustituir el payload del sistema, el paquete de publicación revisa todas las cuentas ordinarias del equipo. Falla de inmediato si encuentra una app o una tarea de desarrollo con el mismo ID, salvo la instalación de desarrollo del usuario de la sesión gráfica actual, que postinstall puede retirar, o si no puede comprobar un home con seguridad. Postinstall retira esa instalación de desarrollo, vuelve a revisar y solo entonces actualiza la tarea del sistema como una transacción que se puede revertir. La guarda de inicio de sesión solo corta, de forma defensiva, los rastros de desarrollo que aparezcan después. Ninguna de las dos tareas define `KeepAlive`, ni arranca un segundo servicio de UI/IME.
>
> Mailbox y Capsule son ventanas normales que toman el foco del teclado. Si se abren desde otro método de entrada, con el atajo o con un aviso de Mailbox, RIMES se activa primero para que la función esté completa. Al cerrarlas no vuelve al método anterior, y un cambio posterior que hagas tú se respeta. En ese caso la función queda limitada como se describe abajo.
>
> Estas funciones no acceden al cliente IMK de otro método de entrada, ni leen, confirman o cancelan su composición. La única tecla que pueden inyectar es un `⌘V` opcional al activar Capsule (véase la barra de Capsule más abajo). El atajo de Ajustes también funciona con cualquier método de entrada. Sus páginas de Mailbox y Capsule solo muestran configuración y estado. Las conversaciones y el contenido siguen en sus propias ventanas.

| Función | Atajo | Contenido | Acción | Dónde se guarda | Límite |
|---|---|---|---|---|---|
| Esquemas | — | Pinyin completo Rime Ice, Natural Code, Xiaohe, Wubi 86, inglés | — | — | — |
| Búfer | `⌘⇧B` | Texto antes de confirmarlo | Cambia a RIMES y luego captura y entrega por bloques | — | Si cambias de método, solo se usa el portapapeles del sistema, no IMK |
| Barra Capsule | `⌘⇧V` | Copias recientes; notas, imágenes, PDF, habilidades, contraseñas | Clic para elegir, doble clic o Retorno para pegar. `⌘S` guarda | Solo en este Mac | Pegar exige Accesibilidad; si no hay permiso, solo llega al portapapeles |
| Mailbox | `⌘⇧M` | Conversaciones de IA, notas, envíos por revisar | Conversación nueva; el primer Retorno inicia la generación | El modelo queda ligado a esa conversación | Los CLI usan su modelo predeterminado |
| Gestión de Capsule | Engranaje o pincel | Cinco tipos de entradas, con vista previa y copia | Cuatro acordes muestran una contraseña, como máximo 15 segundos | iCloud opcional; contraseñas y claves se quedan en este Mac | La frase de acceso solo se guarda como un resumen local |
| Ajustes | `⌘⇧S` | Atajos, estado, sincronización y seguridad | Solo se abre si RIMES es el método de entrada actual | — | No incrusta las ventanas de Mailbox ni de Capsule |

La traducción en vivo, la generación con IA y la entrada en flujo son complementos del búfer. Los acordes son una extensión integrada. Las versiones y los ID están en las listas de abajo.

| Nombre | Tipo | Notas | Predeterminado |
|---|---|---|---|
| Traducción en vivo | Complemento del búfer | Traducción local de Apple, o IA | Activada, macOS 15+ |
| Generación con IA | Complemento del búfer | Codex, Claude Code o una API compatible con OpenAI. Plain / Markdown / JSON permanece en Buffer hasta que tú lo confirmas | Activada |
| Entrada en flujo | Complemento del búfer | El pinyin o los acordes pasan a la IA elegida, que devuelve como máximo 5 conjeturas excluyentes | Activada; solo se entrega lo elegido |
| Acordes | Extensión integrada | Pulsación combinada y pulsación izquierda y luego derecha, con mapas de teclas propios | Desactivada |

## Complementos de búfer incluidos

La tabla se genera desde [`Catalog/buffer-plugins.json`](Catalog/buffer-plugins.json). Al actualizar un complemento hay que actualizar también su versión y ejecutar `python3 scripts/sync-buffer-plugin-catalog.py --check`.

| Complemento | ID | Versión | Instalación predeterminada | Estado predeterminado |
|---|---|---:|---|---|
| ChatGPT | `builtin.codex-cli` | 1.1 | Incluido con RIMES | Activado |
| Claude | `builtin.claude-code-cli` | 1.1 | Incluido con RIMES | Activado |
| AI API | `builtin.openai-compatible` | 1.0 | Incluido con RIMES | Activado |
| Reference | `builtin.scholay` | 0.1 | Incluido con RIMES | Activado |
| Polisher | `builtin.polisher` | 0.1 | Incluido con RIMES | Activado |
| LaTeX | `builtin.latex` | 0.1 | Incluido con RIMES | Activado |
| Traducción en vivo | `builtin.apple-translation` | 2.2 | Incluido con RIMES | Activado |
| Entrada en flujo | `builtin.stream-input` | 1.4 | Incluido con RIMES | Activado |
| Música electrónica | `builtin.music` | 0.2.3 | Incluido con RIMES | Activado |
| Código Morse | `builtin.morse` | 0.1.0 | Incluido con RIMES | Activado |

Todos los complementos de la tabla vienen con RIMES y quedan activados en una instalación nueva.

## Extensiones integradas

| Extensión | ID estable | Versión | Estado predeterminado |
|---|---|---:|---|
| Estadísticas | `builtin.statistics` | 2.0 | Activada |
| Velocidad de escritura | `builtin.typing-speed` | 2.0 | Activada |
| Acordes | `builtin.fly-chord-learning` | 2.0 | Desactivada |

## Instalación

Versiones públicas: [macOS 1.1.0](https://github.com/scholay/rimes/releases/tag/v1.1.0), [Android 1.1.0](https://github.com/scholay/rimes/releases/tag/android-v1.1.0), [Windows 1.1.1](https://github.com/scholay/rimes/releases/tag/windows-v1.1.1) e [iOS App Store 1.1.0](https://apps.apple.com/us/app/lingxi-ime/id6814620242). El paquete de macOS está firmado y notarizado; Android usa la clave de firma de larga duración; el EXE de Windows no está firmado. iOS también ofrece una [invitación pública de TestFlight](https://testflight.apple.com/join/Kdj9RB4q); allí se muestran los builds disponibles. Linux ofrece actualmente una vista previa de los datos de esquemas. Consulta la [auditoría de paquetes](validation/release-audit-20261007.md) para conocer las diferencias con el código actual. También puedes compilar el código localmente:

```bash
git clone --recurse-submodules https://github.com/scholay/rimes.git
cd rimes
```

| Plataforma | Avance | Compilación |
|---|---|---|
| macOS | Método de entrada, además de Buffer, Capsule y Mailbox | `./build_install.sh` |
| iOS | Teclado y app principal (iOS 17+): pinyin, Natural Code, Wubi e inglés sin conexión, y Buffer | Abre [`platforms/ios/RIMES.xcodeproj`](platforms/ios/README.md) en Xcode |
| Windows | Método de entrada TSF nativo, Buffer, acordes y ajustes de plugins oficiales; x64 / x86 | Véase [`platforms/windows/native/README.md`](platforms/windows/native/README.md) |
| Android | Teclado InputConnection nativo, Buffer, seis plugins oficiales y servicios de IA configurables | Véase [`platforms/android/README.md`](platforms/android/README.md) |
| Linux | Método de entrada Fcitx5, Buffer y Capsule. Aún no hay Mailbox | Véase [`platforms/linux/ime/README.md`](platforms/linux/ime/README.md) |

## Documentación

| Documento | Contenido |
|---|---|
| [SYSTEM-ARCHITECTURE.md](SYSTEM-ARCHITECTURE.md) | Arquitectura global vigente. Léela primero si retomas el desarrollo |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Contratos históricos de P1/P2 y problemas encontrados |
| [PLUGIN-CONFIGURATION.md](PLUGIN-CONFIGURATION.md) | Configuración declarativa de complementos |
| [UNSIGNED-PREVIEW.md](UNSIGNED-PREVIEW.md) | Descarga, verificación e instalación segura de la vista previa sin firmar |
| [CROSS-PLATFORM-PREVIEW.md](CROSS-PLATFORM-PREVIEW.md) | Límites y comprobaciones de la vista previa de esquemas para Windows / Linux |
| [platforms/ios/README.md](platforms/ios/README.md) | Teclado y app principal de iOS |
| [platforms/windows/native/README.md](platforms/windows/native/README.md) | Método de entrada TSF nativo de Windows |
| [platforms/linux/ime/README.md](platforms/linux/ime/README.md) | Método de entrada Fcitx5 de Linux, Buffer y Capsule |
| [RELEASE.md](RELEASE.md) | Proceso de publicación: canales, un comando, ritmo y reglas de versión |
| [RELEASE-REFERENCE.md](RELEASE-REFERENCE.md) | Referencia técnica: firma, instalador, actualización dentro de la app, CI |
| [RELEASE-HISTORY.md](RELEASE-HISTORY.md) | Canales de publicación cerrados, la migración del repositorio antiguo y el cambio de nombre |
| [CHANGELOG.md](CHANGELOG.md) | Cambios por versión, generados a partir de los GitHub Releases públicos y de los mensajes de commit |

## Actualización automática

Una copia de RIMES instalada y firmada de forma oficial consulta los GitHub Releases de [`scholay/rimes`](https://github.com/scholay/rimes). Las compilaciones sin firmar `vX.Y.Z-preview.N` no entran en ese canal.

Hay una sola entrada de publicación, y el número de versión sale solo de la etiqueta. El proceso está en [RELEASE.md](RELEASE.md) y los cambios en [CHANGELOG.md](CHANGELOG.md):

```bash
./scripts/release.sh --dry-run preview  # anticipa el plan, las puertas de CI y las notas
./scripts/release.sh preview            # vista previa de macOS sin firmar vX.Y.Z-preview.N
./scripts/release.sh stable             # convierte la línea de vista previa en vX.Y.Z (hace falta Developer ID)
./scripts/release.sh platform minor     # vista previa de datos de Windows/Linux para mantenimiento (no bloquea macOS)
```

Todas las publicaciones salen en `scholay/rimes`. En macOS, `vX.Y.Z` es la versión estable. `vX.Y.Z-preview.N` es una prepublicación sin firmar y no se actualiza sola. `platform-preview-vX.Y.Z` de Windows/Linux es siempre una prepublicación.

## Enlaces

- [Motor de método de entrada RIME](https://rime.im/) — la entrada en chino de este proyecto se basa en RIME.
- [Linux.do](https://linux.do/u/leowangling/preferences/account) — gracias a Linux.do, una comunidad sincera, amable, unida y profesional, y a quienes forman parte de ella.
- [iRime](https://github.com/jimmy54/iRime) — gracias al autor de iRime por la orientación y por ayudar a dar a conocer RIMES.

## Colaboradores

La lista completa está en [CONTRIBUTORS.md](CONTRIBUTORS.md).

Quien mantiene el proyecto en el centro es gerente de producto para usuarios finales, no programador de formación, y agradece la época del vibe coding.

**Asistentes de programación con IA**: Claude, Cursor, Codex y Grok participaron en el diseño, la implementación y la revisión.

## Problemas conocidos

- **Linux: salir de Fcitx5 antes de que termine un despliegue puede dejar el proceso varios minutos.** Un despliegue de librime inicial o en segundo plano no se puede cancelar a medias, y se nota más con un diccionario grande. Véase [#43](https://github.com/scholay/rimes/issues/43).
- **Linux: hacer clic en otro campo justo después de arrastrar la barra de Buffer puede dejar la captura activa.** Solo se ha reproducido en Firefox sobre X11, si el clic cae en otro campo de la misma ventana en unos 10 ms tras soltar. Otro clic o Esc lo recupera. Véase [#44](https://github.com/scholay/rimes/issues/44).

## Licencia y terceros

El código propio de RIMES usa [Apache License 2.0](LICENSE). El alcance y las autorizaciones MIT anteriores se explican en [LICENSING.md](LICENSING.md). El mantenimiento principal está a cargo de [学术海](https://pm.scholay.com).

La entrada de chino se basa en el [motor Rime (librime)](https://github.com/rime/librime). Véanse [NOTICE](NOTICE) para las atribuciones y [ATTRIBUTION.md](ATTRIBUTION.md) para ejemplos de reconocimiento voluntario. Estas recomendaciones no añaden condiciones a la licencia.

Los componentes de terceros, esquemas, diccionarios y datos de Lua/OpenCC conservan sus propias licencias y atribuciones; véanse [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), [LICENSES](LICENSES/) y `rime-data/licenses/`. Los plugins oficiales gratuitos se mantienen en [rimes-plugins](https://github.com/scholay/rimes-plugins).
