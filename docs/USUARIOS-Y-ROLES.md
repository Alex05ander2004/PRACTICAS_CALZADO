# Usuarios, roles y credenciales de prueba

Este archivo tiene dos cosas: **cómo se reparten las responsabilidades** en el
sistema y **las cuentas de prueba** para poder demostrarlo.

> Las contraseñas de aquí son de cuentas ficticias creadas para la evaluación,
> sobre una base de datos de prueba. Ninguna es una credencial personal real.

---

## 1. Por qué hacen falta varias cuentas

No es un adorno: **el sistema impide que quien crea un movimiento lo apruebe**.

```sql
-- 02_mejoras_operativas.sql
constraint ck_mov_segregacion check (
  reversal_of_id is not null
  or approved_by is null or created_by is null or approved_by <> created_by
)
```

Es segregación de funciones, el control interno más básico contra el fraude de
inventario: quien pide sacar mercadería no puede autorizarse a sí mismo. La
única excepción es una reversión, que un jefe emite y autoriza a la vez porque
el error ya ocurrió en el mundo físico y queda auditado.

**Consecuencia práctica: con una sola cuenta no se puede demostrar el workflow
de aprobación.** Hacen falta al menos dos.

---

## 2. Los cuatro roles

El rol vive en `profiles.role` y lo aplica la base de datos, no la interfaz:
cada función comprueba `fn_exigir_rol(...)` y cada tabla tiene sus políticas de
RLS. Ocultar un botón es solo comodidad; aunque alguien llame a la API a mano,
el servidor lo rechaza igual.

| Rol | Qué hace | Funciones que puede llamar |
|---|---|---|
| **OPERARIO** | Ejecuta el trabajo físico | `ejecutar_movimiento`, `ubicar_en_casillero`, `reubicar_asignacion`, `ubicar_recepcion`, `repartir_sobrecarga`, `resolver_revision`, `solicitar_aprobacion`, `reconocer_alerta`. **No crea movimientos**: la política `p_mov_insert` exige supervisor |
| **SUPERVISOR** | Decide y autoriza | Todo lo del operario **+** crear movimientos **+** `aprobar_movimiento`, `rechazar_movimiento`, `eliminar_articulo`, `crear_almacen`, `eliminar_almacen`, `redimensionar_almacen`, `mover_entrada_almacen`, `crear_rack`, `configurar_rack`, `eliminar_rack`, `crear_registro_inventario`, `resolver_aprobacion`, `resolver_fantasma` |
| **JEFE** | Responde de todo | Todo lo anterior **+** `revertir_movimiento` (lo único exclusivamente suyo) **+** administrar el equipo (`profiles`) |
| **AUDITOR** | Solo lectura | Ninguna función de escritura: ve el stock, los movimientos y el kardex, y no puede cambiar nada |

Dos detalles que conviene saber explicar:

- **`max_movement_qty`** es el techo de **aprobación**, no de ejecución: lo
  comprueba `fn_aprobar_movimiento`, y por encima de él la operación tiene que
  escalar a un jefe. Solo tiene sentido en un SUPERVISOR — a un operario, que
  nunca aprueba, no le afecta. Se edita en la sección **Equipo**.
- **Dar de baja no borra.** `fn_rol_actual()` solo devuelve el rol de un perfil
  activo, así que un usuario inactivo deja de pasar RLS y no puede hacer nada,
  pero su firma sigue en los movimientos que aprobó. El historial no se falsea.

---

## 3. Cuentas de prueba

Créalas en **Supabase → Authentication → Users → Add user**, marcando
**Auto Confirm User** (si no, quedan esperando un correo de confirmación).

Al crearse, el trigger `trg_auth_user_creado` les hace un perfil
automáticamente **con rol OPERARIO** — el mínimo, siempre. Los roles reales se
asignan en el paso 4.

| Nombre | Correo | Contraseña | Rol a asignar |
|---|---|---|---|
| Ana Quispe | `jefe@wmscalzado.com` | `Jefe.Almacen#2026` | JEFE |
| Luis Mamani | `supervisor@wmscalzado.com` | `Supervisor.Turno#2026` | SUPERVISOR |
| Rosa Choque | `operario1@wmscalzado.com` | `Operario.Uno#2026` | OPERARIO |
| Marco Flores | `operario2@wmscalzado.com` | `Operario.Dos#2026` | OPERARIO |
| Carla Núñez | `auditor@wmscalzado.com` | `Auditor.Lectura#2026` | AUDITOR |

El ciclo completo necesita **tres**: Luis crea, Ana aprueba y Rosa ejecuta.
Marco sirve para enseñar que un segundo operario tampoco puede aprobar, y Carla
para el rol de solo lectura.

---

## 4. Asignar los roles

Una vez creadas las cinco cuentas, en el **SQL Editor**:

```sql
update public.profiles set full_name = 'Ana Quispe',  role = 'JEFE'       where email = 'jefe@wmscalzado.com';
update public.profiles set full_name = 'Luis Mamani', role = 'SUPERVISOR' where email = 'supervisor@wmscalzado.com';
update public.profiles set full_name = 'Rosa Choque', role = 'OPERARIO'   where email = 'operario1@wmscalzado.com';
update public.profiles set full_name = 'Marco Flores', role = 'OPERARIO'  where email = 'operario2@wmscalzado.com';
update public.profiles set full_name = 'Carla Núñez', role = 'AUDITOR'    where email = 'auditor@wmscalzado.com';

-- Un tope de ejemplo: Luis autoriza hasta 50 pares; por encima, lo escala a un
-- jefe. Va en el supervisor porque es un límite de APROBACIÓN.
update public.profiles set max_movement_qty = 50 where email = 'supervisor@wmscalzado.com';
update public.profiles set max_movement_qty = null where email = 'operario1@wmscalzado.com';

select full_name, email, role, is_active, max_movement_qty
  from public.profiles order by role, full_name;
```

Hace falta el SQL Editor y no la sección Equipo **solo para el primer jefe**:
el registro público siempre crea OPERARIOS, a propósito. Si cualquiera pudiera
registrarse como jefe, el enlace de alta sería la puerta de atrás del almacén.
De ahí en adelante los roles se cambian desde **Equipo**.

---

## 5. Sacar la cuenta personal de en medio

La cuenta con la que se desarrolló (`whuisa@unsa.edu.pe`) es una credencial
personal real y no debería quedar como administradora del sistema entregado.
El orden importa, porque la app no deja quedarse sin jefes:

1. Crea las cuentas y asigna los roles (pasos 3 y 4).
2. Entra con `jefe@wmscalzado.com`.
3. En **Equipo**, da de baja a `whuisa`. Ahora se puede: con dos jefes activos
   deja de ser el último, y la fila del último jefe no ofrece ni el selector de
   rol ni el botón de baja, justamente para no dejar el almacén sin nadie que
   pueda administrarlo.

Si prefieres borrarla del todo, también hay que quitarla de
**Authentication → Users**; dar de baja el perfil solo le impide operar.

---

## 6. Guion de demostración

Con las cuentas listas, el workflow completo se enseña así:

Cada paso lo hace una persona distinta, y eso es justamente lo que se quiere
enseñar: **ninguna cuenta puede hacer el ciclo entera**.

1. **Luis (SUPERVISOR)** crea una SALIDA de 5 pares eligiendo casillero. Queda
   **PENDIENTE** y el casillero pasa a **EN_PICKING** (color propio en el mapa,
   y filtrable en Existencias). El stock no se ha movido.
2. Luis intenta aprobarla: **no puede**. `fn_aprobar_movimiento` responde "No
   puedes aprobar un movimiento que tú mismo creaste", y por debajo el
   constraint `ck_mov_segregacion` lo impediría igual.
3. **Ana (JEFE)** la aprueba. El stock sigue igual, pero sube `qty_reserved`:
   la mercadería queda comprometida.
4. **Rosa (OPERARIA)** la **ejecuta** — es su trabajo, el físico. Ahora sí baja
   el stock, el casillero vuelve a **OCUPADA** con el saldo y queda el asiento
   en `stock_ledger`.
5. Con una ENTRADA es al revés: al crearla el casillero queda **RESERVADA**
   (sitio apartado, aún sin cajas) y al ejecutarla pasa a **OCUPADA**.
6. Si en el paso 3 se **rechaza**, la marca se deshace sola y el stock nunca se
   tocó.
7. **Carla (AUDITORA)** entra y comprueba que lo ve todo y no puede cambiar nada.

Comprobado en las pruebas, con la sesión de Rosa abierta:

| Intento | Respuesta del sistema |
|---|---|
| Crear un movimiento | `new row violates row-level security policy` |
| Aprobar / rechazar | "Tu rol (OPERARIO) no autoriza esta operación." |
| Dar de alta un proveedor | RLS lo rechaza |
| Ver la pestaña Equipo | no aparece |
| Leer stock y movimientos | 80 y 83 filas |
