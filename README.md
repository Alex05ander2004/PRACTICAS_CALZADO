# WMS Calzado — Sistema de gestión de inventario

Aplicación web de gestión de inventario para un almacén de calzado, construida
sobre **Supabase** (PostgreSQL) con un frontend en **HTML + CSS + JavaScript sin
frameworks**.

**Repositorio:** https://github.com/Alex05ander2004/PRACTICAS_CALZADO
**Puesta en marcha:** [`INSTALACION.md`](INSTALACION.md) — cuatro pasos, unos veinte minutos.

El punto de partida fue el enunciado de tres tablas (`inventory`,
`inventory_items`, `inventory_movements`). El resultado es un almacén que se
puede operar de verdad: sabe **cuánto** hay, **dónde** está cada caja, **quién**
autorizó cada movimiento y **por qué** el stock de hoy no es el de ayer.

---

## Índice

1. [Cómo ejecutarlo](#1-cómo-ejecutarlo)
2. [Arquitectura](#2-arquitectura)
3. [Base de datos: tablas y relaciones](#3-base-de-datos-tablas-y-relaciones)
4. [Cómo funciona](#4-cómo-funciona)
5. [Seguridad](#5-seguridad)
6. [Validaciones y manejo de errores](#6-validaciones-y-manejo-de-errores)
7. [Funcionalidades](#7-funcionalidades)
8. [Extras sobre lo pedido](#8-extras-sobre-lo-pedido)
9. [Lo que quedó fuera](#9-lo-que-quedó-fuera)
10. [Mapa del repositorio](#10-mapa-del-repositorio)

---

## 1. Cómo ejecutarlo

No hay build ni dependencias que instalar: son archivos estáticos.

```bash
cp js/config.example.js js/config.js   # y pon ahí la URL y la anon key
python -m http.server 5173
```

Abre `http://localhost:5173`. Necesitas un servidor (aunque sea este): abrir el
`index.html` con doble clic falla, porque el navegador bloquea las peticiones
desde `file://`.

**La base de datos** se levanta corriendo en orden los archivos de
`supabase/migrations/` en el SQL Editor de Supabase, del `01` al `34`. Cada uno
es idempotente: volver a pasarlo no rompe nada.

No existe el `25`: era un rediseño que ponía el almacén en el movimiento y no en
el alta del artículo, y se descartó al releer el enunciado, que pide un artículo
→ un registro de inventario. Se dejó el hueco en vez de renumerar, porque
renumerar migraciones ya aplicadas es una forma segura de aplicarlas dos veces.

`js/config.js` está en `.gitignore`. La `anon key` que contiene **no es un
secreto** —está pensada para viajar en el frontend— y lo que protege los datos
es RLS, no esconderla; se deja fuera del repositorio simplemente para que cada
quien apunte a su propio proyecto.

Las cuentas de prueba y sus roles están en
[`docs/USUARIOS-Y-ROLES.md`](docs/USUARIOS-Y-ROLES.md). **Hacen falta al menos
dos** para ver el workflow completo, por el motivo que se explica en
[Seguridad](#5-seguridad).

---

## 2. Arquitectura

```
   Navegador                        Supabase
┌──────────────┐            ┌─────────────────────┐
│  index.html  │            │       Auth          │  sesión y JWT
│   css/  js/  │◄──JWT──────┤                     │
│              │            ├─────────────────────┤
│  js/api/*    │───REST────►│      PostgREST      │  tablas, vistas y RPC
│  (5 módulos) │            ├─────────────────────┤
│              │            │   PostgreSQL        │
│  js/*.js     │            │   · RLS por rol     │  ← la autorización vive aquí
│  (UI)        │            │   · triggers        │  ← y las reglas de negocio
└──────────────┘            │   · funciones       │
                            └─────────────────────┘
```

**No hay servidor propio.** El navegador habla directamente con PostgREST, y
quien decide qué puede hacer cada quien es la propia base de datos.

Eso obliga a una decisión que atraviesa todo el proyecto: **la lógica de negocio
vive en la base, no en el JavaScript.** Un `fetch` a mano desde la consola del
navegador tiene exactamente los mismos permisos que la aplicación, así que
cualquier regla que estuviera solo en el cliente sería decorativa. El JavaScript
esconde botones y valida formularios para no hacer perder el tiempo a nadie; lo
que de verdad impide una operación es una política RLS, un `CHECK` o un trigger.

El frontend se divide en dos capas:

| Capa | Archivos | Responsabilidad |
|---|---|---|
| Acceso a datos | `js/api/*.js` | Hablar con Supabase. Una función por operación, sin tocar el DOM |
| Interfaz | `js/*.js` | Pintar y reaccionar. No conocen tablas ni SQL |

Los archivos se cargan con `<script>` clásicos, sin bundler, en orden de
dependencia. No hay módulos ES ni imports: es deliberado, para que el proyecto
se pueda abrir y entender sin herramientas.

---

## 3. Base de datos: tablas y relaciones

**23 tablas, 10 vistas y 74 funciones**, repartidas en 33 migraciones numeradas.

### Las tres del enunciado

| Enunciado | Aquí | Por qué |
|---|---|---|
| `inventory_items` | `products` + `inventory_items` | Un modelo de zapatilla tiene muchas tallas. Nombre, marca y categoría son del **modelo**; SKU, precio y medidas son de la **talla** |
| `inventory` | `inventory` | Una fila por artículo y almacén |
| `inventory_movements` | `inventory_movements` | Con `status`, `approved_by` y `executed_at` para el workflow |

La separación `products` / `inventory_items` es la decisión de modelado más
importante. El CSV de partida repetía "Nike Pegasus" en once filas, una por
talla, con el nombre escrito de once formas. Separarlo permite corregir el
nombre en un sitio y que valga para todas las tallas.

### Estructura completa

```
profiles ─────────── quién es cada usuario y su rol
    │
brands ┐
categories ┼───► products ───► inventory_items ───► inventory
suppliers ┘         (modelo)      (modelo+talla)     (stock por almacén)
                                        │                 │
                                        │                 └──► inventory_movements
                                        │                            │
                                        │                            └──► stock_ledger
                                        │                                 (kardex, inmutable)
                                        └──► position_assignments
                                                    │
warehouses ───► racks ───► positions ───────────────┘
 (almacén)     (estante)   (casillero)
```

- **`warehouses` → `racks` → `positions`**: la geometría física. Un almacén es
  una cuadrícula en metros, un rack ocupa un rectángulo, y un casillero es un
  hueco concreto con su nivel y su capacidad en cajas.
- **`position_assignments`**: qué caja hay en qué casillero. Es lo que convierte
  "hay 85 pares" en "hay 25 en A-01-05, 25 en A-01-190…".
- **`stock_ledger`**: el kardex. Un asiento por movimiento ejecutado, con el
  saldo antes y después. **No tiene política de escritura**: solo lo escribe la
  función que ejecuta movimientos, así que el histórico no se puede falsear
  desde la aplicación.

El resto (`alerts`, `alert_rules`, `approval_requests`, `audit_log`,
`discrepancies`, `inventory_counts`, `inventory_orders`, `warehouse_nodes`,
`warehouse_edges`) sostiene alertas, aprobaciones, auditoría, conteos cíclicos y
el ruteo del plano.

### Las relaciones, en una frase

Un **producto** tiene muchos **artículos** (uno por talla). Un artículo tiene un
registro de **inventario** por almacén, y ese registro acumula muchos
**movimientos**. Cada movimiento ejecutado deja un asiento en el **kardex**. En
paralelo, un artículo ocupa una o varias **posiciones** físicas.

---

## 4. Cómo funciona

### El stock no se edita

`inventory.quantity` **no tiene política de UPDATE y ni siquiera tiene el
permiso de columna**. Es la decisión de diseño de la que cuelga todo lo demás:
un `UPDATE` directo sobre el saldo es indistinguible de un fraude. Toda
variación pasa por un movimiento, y todo movimiento deja rastro.

### El ciclo de un movimiento

```
        crear (SUPERVISOR+)
              │
              ▼
         PENDIENTE ──────────► RECHAZADO      el stock no se toca
              │                               (o RETIRADO por quien lo creó)
              │ aprobar (otra persona)
              ▼
         APROBADO                             sube qty_reserved / qty_incoming
              │                               el saldo sigue igual
              │ ejecutar (OPERARIO+)
              ▼
     stock actualizado                        + asiento en stock_ledger
```

Tres pasos y no dos, porque **autorizar y hacer son cosas distintas**: el
supervisor decide que salgan 20 pares, y el operario confirma que los sacó de
verdad. Entre medias, `qty_reserved` deja esos 20 comprometidos para que nadie
más los prometa.

Una **reversión** (solo JEFE) no borra nada: emite un movimiento contrario que
se ejecuta al momento y deja su propio asiento. El error queda a la vista, que
es lo que se espera de un inventario auditable.

### El casillero sigue al movimiento

Cada casillero tiene un estado, y **lo pone el movimiento, no una persona**:

| Estado | Significa | Quién lo pone |
|---|---|---|
| `OCUPADA` | Las cajas están ahí | Ubicar, o ejecutar una entrada |
| `RESERVADA` | Sitio apartado, la mercadería no ha llegado | Crear una ENTRADA con casillero |
| `EN_PICKING` | Las cajas están, pero comprometidas | Crear una SALIDA con casillero |

Los tres ocupan capacidad. Al ejecutar o rechazar el movimiento, la marca se
deshace sola. Ubicar a mano solo registra `OCUPADA`: apartar o comprometer se
hace creando el movimiento correspondiente, porque una marca sin movimiento
detrás no la limpiaría nadie después.

### Dónde va cada caja

El sistema no acepta cualquier caja en cualquier hueco:

- **Un casillero, un modelo.** Mezclar modelos es lo que hace que el operario
  saque la talla equivocada.
- **Infantil abajo, adulto arriba.** Los dos primeros niveles son para calzado
  de niño; el resto, de adulto. Lo comprueba un trigger en cada asignación.
- **La capacidad es real.** Se calcula con las medidas de la caja (22×15×9 cm
  infantil, 35×25×13 adulto), las dos orientaciones posibles, 45 cm de altura
  libre por estante y un 15% de holgura.
- **El casillero se dimensiona solo.** `fn_casilleros_para` parte cada nivel en
  tantos huecos como haga falta para que uno guarde aproximadamente un modelo
  completo (la mediana del stock por modelo, acotada entre 20 y 80 cajas). Ni un
  casillero de 14 metros ni doscientos huecos de tres cajas.

---

## 5. Seguridad

### RLS en todas las tablas

Cada tabla tiene sus políticas, y el rol sale de `profiles.role` a través de
`fn_rol_actual()`, que es `security definer` para poder leer el perfil sin caer
en una recursión de políticas.

```sql
revoke all    on all tables    in schema public from anon;          -- sin sesión, nada
revoke delete on all tables    in schema public from authenticated; -- aquí no se borra
revoke execute on all functions in schema public from authenticated;-- y luego se concede
                                                                    -- una por una
```

El `revoke execute` masivo es importante: las funciones internas `fn_*` aceptan
un `p_user_id`, y si el cliente pudiera llamarlas suplantaría a cualquiera. Solo
se concede la versión pública de cada una, que deriva el actor de `auth.uid()`.

### Los cuatro roles

| Rol | Puede |
|---|---|
| **OPERARIO** | Ejecutar movimientos aprobados, ubicar y reubicar mercadería |
| **SUPERVISOR** | Lo anterior + crear movimientos, aprobarlos o rechazarlos, y mantener catálogo y almacenes |
| **JEFE** | Todo + revertir movimientos ejecutados + administrar al equipo |
| **AUDITOR** | Solo lectura |

### Segregación de funciones

**Quien crea un movimiento no puede aprobarlo.** No es una comprobación del
JavaScript: es un `CHECK` de la tabla.

```sql
constraint ck_mov_segregacion check (
  reversal_of_id is not null
  or approved_by is null or created_by is null or approved_by <> created_by
)
```

Es el control interno más básico contra el fraude de inventario, y tiene una
consecuencia práctica: **con una sola cuenta no se puede demostrar el sistema**.
Sí puede uno retirar su propia petición mientras siga pendiente — eso no salta
ningún control, porque todavía no había obtenido autorización de nadie.

### Otras medidas

- **Tope de aprobación por persona** (`max_movement_qty`): por encima de su
  techo, un supervisor no autoriza, escala a un jefe.
- **Nadie se asciende a sí mismo**: un trigger impide cambiarse el rol, el tope
  o el correo; solo un jefe los toca.
- **El registro público siempre crea OPERARIOS.** El primer jefe se nombra a
  mano desde el SQL Editor: si el enlace de alta pudiera crear jefes, sería la
  puerta de atrás del almacén.
- **Nada se borra**: baja lógica con `deleted_at` en artículos y productos, y
  `LIBERADA` en las asignaciones. Un usuario dado de baja deja de pasar RLS pero
  su firma sigue en lo que aprobó.
- **`audit_log`** guarda quién cambió qué, con la fila antes y después, sobre
  las cinco tablas que mueven stock, dinero o autorizaciones:
  `inventory_items`, `inventory`, `inventory_movements`, `inventory_orders` y
  `position_assignments`.

---

## 6. Validaciones y manejo de errores

En tres capas, y a propósito:

**En el formulario.** `required`, `pattern`, `min`, `max` y `maxlength` en el
HTML, traducidos a un mensaje en español por `js/formularios.js`. Los códigos se
pasan a mayúsculas mientras se escriben y se les quitan los caracteres que la
base no admite, en vez de rechazarlos al guardar. Lo que el HTML no sabe
declarar —que el costo no supere al precio, que el stock máximo no sea menor que
el mínimo, que la talla caiga en el rango de su público— se comprueba antes de
enviar. Repetir una talla que el modelo ya tiene se avisa **mientras se escribe**.

**En la base.** `CHECK` de formato y de rango, `UNIQUE` sobre lo que no puede
repetirse, y triggers para lo que depende de otras filas (capacidad, público por
nivel, un modelo por casillero, geometría de los racks).

**Al mostrar el error.** Los errores crudos de Postgres se traducen:
`duplicate key value violates unique constraint "uq_racks_warehouse_code"` se
convierte en *"Ya existe un rack con ese código en este almacén"*, y el
`Cannot coerce the result to a single JSON object` que devuelve PostgREST cuando
RLS filtra las filas de un `UPDATE`, en *"o el registro ya no existe, o tu rol no
permite modificarlo"*. Lo que no se previó pasa tal cual: inventar un mensaje
para un error desconocido esconde el problema.

---

## 7. Funcionalidades

### Lo que pedía el enunciado

- **Dashboard** con total de artículos, stock total, artículos bajo mínimo,
  valor del inventario y movimientos recientes.
- **Tabla de inventario** con SKU, artículo, categoría, stock, costo, precio,
  proveedor, estado y acciones.
- **Búsqueda** por artículo y SKU, y **filtros** por categoría, proveedor,
  público y estado de stock.
- **CRUD de artículos** completo, con el formulario de edición del enunciado.
- **Gestión de inventario**: crear registros y editar umbrales.
- **Movimientos**: entrada, salida y ajuste, con fecha, SKU, artículo, tipo,
  cantidad, motivo, ubicación y estado.
- **Workflow de aprobación** (bonus), **actualización automática del stock**
  (bonus) y **RLS** (bonus).

### Cómo se usa el alta de artículos

Al crear un artículo se elige entre **producto existente** —se le añade una talla
a un modelo que ya está, con sus datos precargados y bloqueados— o **producto
nuevo**, donde el código de modelo se propone solo con el primer `ZAP-` libre. El
SKU no se escribe: se arma con el modelo y la talla. Y se elige el público, que
decide el rango de tallas válido y el tamaño de la caja.

---

## 8. Extras sobre lo pedido

Nada de esto estaba en el enunciado. Salió de preguntarse cómo se opera un
almacén de verdad (el razonamiento completo está en
[`docs/ANALISIS-OPERATIVO.md`](docs/ANALISIS-OPERATIVO.md)).

### Mapa del almacén

Un plano en planta, a escala, con los racks dibujados sobre una cuadrícula en
metros. Se puede **medir el local**, **mover racks arrastrándolos** —el trigger
rechaza que se salgan o se pisen—, **colocar la puerta** y **abrir un rack** para
ver, casillero por casillero, qué guarda cada hueco y en qué estado.

Sobre el plano se calcula además la **ruta de picking**: dado un conjunto de
artículos, en qué orden recorrerlos y por dónde, con A\* sobre los pasillos —que
son, literalmente, las celdas que ningún rack ocupa—.

### Existencias por ubicación

La misma información que el mapa, pero en lista y sin gráficos: almacén → rack →
modelo, con sus tallas y cantidades. Con búsqueda **por ámbito**, porque buscar
"40" sin acotar mezclaba la talla 40 con el modelo ZAP-040 y con todo SKU
terminado en `-40`. Filtra también por estado del casillero, que es la forma de
ver de un vistazo qué hay reservado o comprometido.

### Revisión de ubicaciones

Un panel que compara lo que dice el stock con lo que hay en los estantes y
clasifica las diferencias: calzado en un nivel que no le toca, casilleros por
encima de su capacidad, mercadería sin ubicar y **cajas fantasma** (más en el
estante que en el sistema). Cada tipo se puede resolver desde ahí.

### Sección Equipo

Para el jefe: quién trabaja en el almacén, con qué rol y qué tope de aprobación,
y la posibilidad de cambiarlo o dar de baja. Con una salvaguarda: la fila del
**último jefe activo** no ofrece ni cambiar el rol ni darse de baja, porque el
almacén se quedaría sin nadie que pueda administrarlo.

### Y además

- **Alertas** de stock bajo, sobre-capacidad y movimientos que llevan demasiado
  tiempo sin ejecutarse.
- **Multi-almacén** con creación y borrado, que se niega si queda algo dentro.
- **Kardex** consultable con el saldo antes y después de cada movimiento.

---

## 9. Lo que quedó fuera

Cosas identificadas y no hechas por tiempo, no porque no hicieran falta:

- **Conteos cíclicos.** Las tablas (`inventory_counts`,
  `inventory_count_lines`, `discrepancies`) están y el flujo está pensado, pero
  no hay pantalla: hoy un recuento físico se registra como ajuste.
- **Órdenes de compra y venta.** `inventory_orders` existe y los movimientos
  pueden colgar de una orden, pero no hay forma de gestionarlas desde la
  interfaz.
- **Ejecución parcial guiada.** La función acepta una cantidad real distinta de
  la pedida —llegaron 48 de 50—, pero el modal no la ofrece todavía.
- **La ruta de picking no se puede imprimir** ni pasar a un dispositivo: se ve
  en pantalla y ahí se queda.
- **Historial por artículo.** El kardex está completo, pero falta la vista de
  "todo lo que le pasó a este SKU" en una línea de tiempo.
- **Reserva de stock por pedido.** Hoy `qty_reserved` es un total; no se sabe
  para qué pedido está comprometido cada par.
- **Pruebas automatizadas.** Hay scripts de verificación en `supabase/tests/`
  que se corren a mano, pero no una suite que se ejecute sola.

---

## 10. Mapa del repositorio

```
index.html                  una sola página; todas las secciones y modales
css/dashboard.css           estilos, con variables de tema

js/config.js                URL y anon key (fuera del repositorio)
js/supabaseClient.js        cliente único + paginación (PostgREST corta en 1000 filas)
js/api/auth.js              sesión, perfil y equipo
js/api/catalogo.js          productos, artículos, marcas, categorías, proveedores
js/api/inventario.js        stock, almacenes, racks, casilleros, revisión
js/api/movimientos.js       crear, aprobar, ejecutar, rechazar, revertir
js/api/alertas.js           alertas activas

js/dashboard.js             login, carga, KPIs, tablas, filtros y permisos de la interfaz
js/formularios.js           validación compartida y traducción de errores
js/articulo-modal.js        alta y edición de artículos
js/movimiento-modal.js      alta de movimientos y acciones del workflow
js/mapa-modal.js            modal de ubicar y panel de revisión
js/plano-editor.js          plano en planta, edición de racks y ruta de picking
js/existencias.js           existencias por ubicación
js/equipo.js                administración del equipo
js/custom-select.js         desplegable propio, accesible

supabase/migrations/        01 → 34, en orden, idempotentes
supabase/tests/             verificaciones de integridad
docs/ANALISIS-OPERATIVO.md  qué puede salir mal en un almacén y cómo se ataja
docs/USUARIOS-Y-ROLES.md    roles, permisos y cuentas de prueba
```

Las migraciones están numeradas y comentadas una por una: cada archivo explica
**qué problema resuelve** y **por qué se resolvió así**, que suele ser más útil
que leer el SQL.
