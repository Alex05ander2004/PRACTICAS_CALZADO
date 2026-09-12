# Guía de pruebas — ocho casos

Ocho recorridos para comprobar el sistema sin tener que explorarlo a ciegas.
Cada uno dice **con qué cuenta** entrar, **qué hacer** y **qué debe pasar**.

Las credenciales están en [`USUARIOS-Y-ROLES.md`](USUARIOS-Y-ROLES.md). Conviene
tenerlo a mano porque **varios casos exigen cambiar de usuario**: el sistema
impide que una misma persona haga el ciclo completo, y eso es justamente lo que
se quiere enseñar.

Los datos de ejemplo son reales y están cargados: 80 artículos, 65 modelos,
3 almacenes, 16 racks y unos 3 200 casilleros.

Si el sistema todavía no está levantado, [`INSTALACION.md`](../INSTALACION.md)
lo explica. Código y historial: https://github.com/Alex05ander2004/PRACTICAS_CALZADO

---

## 1 · El dashboard y sus filtros

**Cuenta:** cualquiera · **Pestaña:** Inventario

1. Mira los cinco indicadores de arriba: total de artículos, stock total,
   artículos bajo mínimo, valor del inventario y movimientos recientes.
2. Escribe `pegasus` en el buscador. Prueba también `ZAP-019` y `botin`
   —sin tilde: debe encontrar "botín" igual—.
3. Combina los filtros de categoría, proveedor, público y estado de stock.
4. Pon el filtro de stock en **Bajo mínimo**: debe aparecer `ZAP-019-41`, con
   8 pares y un mínimo de 10.
5. Pulsa **Limpiar**.

**Qué demuestra:** el dashboard del enunciado, con búsqueda por artículo y SKU y
los cuatro filtros. El contador de abajo dice siempre cuántos de cuántos se están
viendo.

---

## 2 · Dar de alta una talla nueva

**Cuenta:** Luis (supervisor) · **Botón:** + Nuevo artículo

1. Deja marcado **Producto existente** y elige `ZAP-002 — Adidas Runfalcon 3`.
   Fíjate en que el nombre, la marca, la categoría y el proveedor se rellenan
   solos y quedan bloqueados: son del modelo, no de la talla.
2. Escribe la talla `42`. **El SKU se arma solo**: `ZAP-002-42`.
3. Prueba ahora a escribir la talla `40`. El modelo ya la tiene, y sale el aviso
   en rojo: *"Ese modelo ya tiene la talla 40 (ZAP-002-40)"*. Guardar tampoco
   deja.
4. Vuelve a `42` y prueba a romper el formulario:
   - Cambia el público a **Niño**: la talla 42 pasa a estar fuera de rango.
   - Pon el precio en `0`, o un costo mayor que el precio.
   - Deja el stock mínimo en `0`, o el máximo por debajo del mínimo.
5. Corrige y guarda. Luego búscalo en la tabla y **edítalo**; al final,
   **elimínalo**.

**Qué demuestra:** el CRUD completo de artículos y las validaciones. El SKU no se
escribe a mano porque escribirlo mal es el error más caro: es la clave por la que
se busca todo lo demás.

> Si eliges **Producto nuevo**, el código de modelo se propone solo con el primer
> `ZAP-` libre, y el proveedor se puede elegir o dar de alta ahí mismo.

---

## 3 · El workflow completo (el caso principal)

**Tres cuentas.** Ninguna puede hacerlo sola: ese es el punto.

### Paso 1 — Luis (supervisor) crea la salida

Pestaña **Movimientos** → *+ Nuevo movimiento*. Elige un artículo, tipo
**SALIDA**, cantidad 5, y un casillero de los que ofrece.

- El movimiento queda **Pendiente**.
- **El stock no se mueve.**
- En **Mapa del almacén**, ese casillero pasa a **En picking** (color propio).
  También se puede ver en Existencias filtrando por *Solo en picking*.

### Paso 2 — Luis intenta aprobar su propia salida

No puede. El sistema responde: *"No puedes aprobar un movimiento que tú mismo
creaste. Debe autorizarlo otra persona."*

### Paso 3 — Ana (jefa) la aprueba

- Pasa a **Aprobado**.
- **El stock sigue igual**, pero `qty_reserved` sube 5: la mercadería queda
  comprometida para que nadie más la prometa.

### Paso 4 — Rosa (operaria) la ejecuta

- Ahora sí **baja el stock** en 5.
- El casillero vuelve a **Ocupada**, con 5 cajas menos.
- Queda un asiento en el kardex con el saldo antes y después.

**Qué demuestra:** el workflow de aprobación y la actualización automática del
stock (los dos bonus), y la segregación de funciones. Son tres pasos y no dos
porque **autorizar y hacer son cosas distintas**: el supervisor decide, el
operario confirma que lo hizo.

---

## 4 · Rechazar, y retirar lo propio

**Cuenta:** Ana (jefa)

1. Crea una **ENTRADA** con casillero. El casillero queda **Reservada**: sitio
   apartado para mercadería que todavía no ha llegado.
2. **Retírala tú misma** desde *Rechazar*. Se permite, porque todavía no la
   había autorizado nadie: la nota queda como *"Retirado por quien lo creó"* y
   el casillero se libera.
3. Ahora pide a Luis que cree otro movimiento y **recházalo tú**. También vale,
   y ahí sí queda tu firma como quien lo rechazó.

**Qué demuestra:** que rechazar no toca el stock, que las marcas del casillero se
deshacen solas, y la diferencia entre *retirar lo tuyo* (no había autorización de
por medio) y *rechazar lo de otro* (que sí es una decisión de autorización).

---

## 5 · Revertir lo ya ejecutado

**Cuenta:** Ana (jefa) — es la única que puede

En **Movimientos**, busca uno **Ejecutado** y pulsa *Revertir*. Pide motivo, y es
obligatorio.

- El stock vuelve a su valor anterior.
- El movimiento original **no se borra ni se edita**: se crea un contra-asiento
  que apunta a él.
- En el kardex quedan los dos.

**Qué demuestra:** que el histórico es inmutable. El error se corrige a la vista
de todos, que es lo que se espera de un inventario auditable. Un operario o un
supervisor no ven siquiera el botón.

---

## 6 · Seguridad: cada rol ve y puede lo suyo

Entra con las cuatro cuentas, una tras otra, y mira la diferencia:

| Cuenta | Qué debe ver |
|---|---|
| **Rosa** (operaria) | Solo *Ubicar* y *Ejecutar*. Sin *Nuevo movimiento* ni *Nuevo artículo* |
| **Luis** (supervisor) | Todo salvo *Revertir*. Sin pestaña Equipo |
| **Ana** (jefa) | Todo, y la pestaña **Equipo** |
| **Carla** (auditora) | Lo ve todo y **no tiene ni un botón**: las acciones salen como "—" |

Con Ana, entra en **Equipo**: cambia el rol de Marco, ponle un tope de
aprobación a Luis, da de baja a alguien y vuelve a activarlo. Fíjate en que **la
fila del último jefe activo no se puede tocar** — dejar el almacén sin jefe
obligaría a entrar por el SQL Editor a arreglarlo.

**Qué demuestra:** RLS por rol (el tercer bonus). Esconder botones es solo
comodidad: la barrera está en la base de datos, y si alguien llamara a la API a
mano recibiría el mismo rechazo.

---

## 7 · El mapa del almacén

**Cuenta:** Rosa o superior · **Pestaña:** Mapa del almacén

1. Mira el plano: está **a escala**, en metros, con los racks donde están de
   verdad y la puerta en su pared.
2. **Pulsa un rack**: se abre su panel con la capacidad y, casillero por
   casillero, qué modelo guarda cada hueco, con qué tallas y en qué estado.
3. **Arrastra un rack** a otro sitio. Intenta sacarlo del plano o encima de
   otro: la base lo rechaza y vuelve a su sitio.
4. Abajo, elige dos o tres racks como paradas y pulsa **calcular ruta**: dibuja
   el recorrido más corto por los pasillos.
5. Vuelve a Inventario y pulsa **Ubicar** en cualquier artículo. Arriba dice
   cuántos pares quedan por ubicar; el desplegable solo ofrece casilleros que
   admiten ese artículo, y lo que un movimiento tiene comprometido no se puede
   liberar.

**Qué demuestra:** que el sistema sabe *dónde* está cada caja y no solo cuántas
hay. Nada de esto lo pedía el enunciado.

---

## 8 · Existencias y revisión de ubicaciones

**Pestaña:** Existencias

1. Recorre el árbol almacén → rack → modelo, con las tallas y sus cantidades.
2. Busca `40` con el ámbito en **Todo**, y luego en **Solo talla**. Sin acotar,
   "40" trae también el modelo ZAP-040 y todo SKU acabado en `-40`.
3. Filtra por **Reservados y en picking**: ahí está, en una lista, lo que en el
   plano solo se veía por color.

Después, en **Mapa del almacén**, baja al panel de **Revisión de ubicaciones**.
Compara lo que dice el stock con lo que hay en los estantes y clasifica las
diferencias: calzado en un nivel que no le toca, casilleros por encima de su
capacidad, mercadería sin ubicar y cajas fantasma. **Ahora mismo debe estar en
cero**: 2 376 pares en stock y 2 376 en estantes.

**Qué demuestra:** que el sistema se audita a sí mismo. Si alguna vez el stock y
los estantes dejan de cuadrar, lo dice y ofrece corregirlo.

---

## Si algo no funciona

- **"Tu rol no autoriza esta operación"** no es un fallo: es el sistema haciendo
  su trabajo. Comprueba con qué cuenta estás.
- **La sesión caduca** y vuelve al login. Es lo esperado.
- Algunos movimientos antiguos de la carga inicial pueden fallar al ejecutarse
  si el casillero que traían ya no admite ese artículo. El error lo explica.
