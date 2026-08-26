# Reconstruir la app de Driver para la demo

Convierte un commit en el `.app` **configurado** que se demuestra, empezando desde un
directorio vacío y sin preguntarle a nadie. Verificada en clon limpio el 26-ago-2026
(Xcode 26.6). Reconstruye la build **Debug/Dev**, que apunta al middleware de dev por
Tailscale (`100.94.115.58`).

> ⚠️ **La demo se hace SOLO con la build Debug/Dev corrida desde Xcode. NUNCA con Release/JAMF.**
> Release apunta a `wms-api.dinascorp.com` = **producción real** (SAP, pool de licencias con
> Attain). Una demo en Release escribiría en el sistema real de la empresa y se vería idéntica
> — el peor fallo, el que no se ve.

## Coordenadas del congelamiento
- **Rama:** `feat/app-payments`
- **Commit de congelamiento:** el tip de esa rama en el congelamiento; su hash está en la
  lista de congelamiento. Un hash es un dato que cambia; esta receta es el método.
- **Contratos (submódulo `contracts/`):** v0.99.5.
- **Proyecto Xcode:** ⚠️ **NO está en git — se GENERA.** Un clon limpio no trae el `.xcodeproj`;
  hay que crearlo con el generador (paso 3) **antes** de compilar. Este es el único de los tres
  repos que genera el proyecto.

## Requisitos
- macOS con Xcode 26.x + herramientas de línea de comandos (`xcodebuild`, `plutil`, `git`).
- **Ruby** con la gema **`xcodeproj`** (la usa `Scripts/generate_project.rb`).
  Instálala si falta:  `gem install xcodeproj`
- Un simulador de iOS instalado (la verificación va sobre simulador; **no necesita firma**).
- Acceso de lectura al repo y a su submódulo de contratos.

## Receta
```bash
# 1 · Clonar en un directorio VACÍO, con submódulos
git clone --recurse-submodules git@github.com:camilosystem/dinas-wms-app-driver.git
cd dinas-wms-app-driver

# 2 · Ir al commit EXACTO del congelamiento (de la lista de congelamiento)
git checkout feat/app-payments             # el tip = el commit de congelamiento
# (si la rama avanzó después del congelamiento, usa el hash de la lista:
#   git checkout <HASH-DE-LA-LISTA> )
git submodule update --init --recursive    # deja contracts/ en v0.99.5

# 3 · GENERAR el .xcodeproj (está gitignorado; sin esto no hay proyecto que compilar)
ruby Scripts/generate_project.rb

# 4 · Compilar la build Debug/Dev para simulador (no requiere firma)
xcodebuild -project DinasDriver.xcodeproj -scheme DinasDriver -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath ./dd build
```

## Verificar que el producto quedó apuntando a la IP correcta
El chequeo va sobre el **producto compilado**, no sobre el fuente: que el valor esté en el
`.xcconfig` **no prueba** que llegó al binario.
```bash
APP="./dd/Build/Products/Debug-iphonesimulator/DinasDriver.app"

# URL del middleware, leída del Info.plist DEL PRODUCTO:
plutil -extract MIDDLEWARE_BASE_URL raw "$APP/Info.plist"
#   → debe imprimir EXACTAMENTE:  http://100.94.115.58:5257/v1

# Excepción ATS que permite el HTTP a esa IP (Tailscale es CGNAT, no red local):
plutil -extract NSAppTransportSecurity xml1 -o - "$APP/Info.plist"
#   → debe contener  NSAllowsArbitraryLoads = true
```
Si la URL no es `100.94.115.58`, la app abriría bien y no conectaría con nada: estás en el
commit equivocado, o el `Dev.xcconfig` no llegó al binario. Corrige antes de seguir.

## Instalarla en el iPad/iPhone de la demo (build de dispositivo)
La verificación de arriba (simulador) prueba la CONFIGURACIÓN sin firmar. Para instalar en el
dispositivo físico hace falta, además:
- `DEVELOPMENT_TEAM` ya está en `Config/Base.xcconfig` (`LJ2FLQU46D`).
- La cuenta de Apple de ese Team iniciada en Xcode (la hace una persona; pide segundo factor).
- El dispositivo conectado por cable y registrado en el Team (Xcode lo registra al primer build
  a dispositivo). No debe estar administrado por Jamf (bloquearía el Modo Desarrollador / el
  emparejamiento).
- El bundle id de dev lleva sufijo: **`com.dinas.driver.dev`**.

Genera el proyecto (paso 3), ábrelo en Xcode, elige el esquema **DinasDriver** (Debug/Dev) y el
dispositivo como destino, y corre. En el dispositivo, verifica que **login + sync conectan** —
no solo que la app abre.
