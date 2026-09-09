# Análisis operativo — error humano, prevención, alertas y reversión

> **Premisa del análisis.** El sistema no falla por la base de datos: falla por las
> personas que lo operan. Un almacén real tiene operarios cansados al final del turno,
> cajas de zapatillas talla 41 y 42 que se ven idénticas, proveedores que entregan 48
> cuando anunciaron 50, y jefes que descubren el problema tres semanas después.
> Este documento cataloga **todo lo que puede salir mal** y define cómo el sistema lo
> **previene**, lo **detecta** o lo **corrige**.

Documento de dominio. Alimenta el `schema.sql` (Fase 1 bis), las políticas RLS
(Fase 2) y el diseño del dashboard (Fase 4+). Sirve además como guion de sustentación.

---

## 1. Modelo de actores

El `CASO.txt` menciona dos actores ("equipo logístico" y "trabajadores de almacén"),
pero una operación real tiene cuatro niveles de responsabilidad. La diferencia entre
ellos **no es cosmética**: define quién puede autorizar qué, y es la base de todo el
sistema de control.

| Rol | Quién es | Qué puede hacer | Qué NO puede hacer |
|---|---|---|---|
| `OPERARIO` | Trabajador de almacén | Ejecutar físicamente lo ya aprobado: recibir, ubicar, retirar. Reportar discrepancias. | Crear órdenes, aprobar, editar maestros, ver costos |
| `SUPERVISOR` | Coordinador logístico | Crear órdenes INBOUND/OUTBOUND, aprobar movimientos dentro de su límite, gestionar posiciones | Aprobar sobre su límite, eliminar maestros, revertir ejecutados |
| `JEFE` | Jefe de almacén / administrador | Aprobar acciones sensibles y escaladas, revertir movimientos ejecutados, autorizar eliminaciones, configurar umbrales | — |
| `AUDITOR` | Contabilidad / control interno | Ver absolutamente todo, incluido el histórico y la auditoría | Modificar cualquier cosa |

**Principio rector: segregación de funciones.** Quien crea una operación no puede ser
quien la aprueba. Es el control interno más básico que existe en logística y hoy el
esquema no lo impide.

---

## 2. Las tres capas de defensa

Cada modo de fallo del catálogo se trata en al menos una de estas capas. El orden
importa: prevenir es siempre más barato que corregir.

```
        ┌─────────────────────────────────────────────────────┐
        │  CAPA 1 — PREVENIR                                  │
        │  El error es imposible de cometer.                  │
        │  Constraints, índices únicos, límites por rol,      │
        │  idempotencia, confirmaciones escaladas.            │
        └─────────────────────────────────────────────────────┘
                              ↓ lo que se escapa
        ┌─────────────────────────────────────────────────────┐
        │  CAPA 2 — DETECTAR                                  │
        │  El error ocurrió pero el sistema avisa rápido.     │
        │  Alertas con severidad, semáforos, colas de         │
        │  trabajo vencidas, detección de valores atípicos.   │
        └─────────────────────────────────────────────────────┘
                              ↓ lo que ya pasó
        ┌─────────────────────────────────────────────────────┐
        │  CAPA 3 — CORREGIR                                  │
        │  El error se deshace sin destruir la evidencia.     │
        │  Reversión por contra-asiento, papelera con         │
        │  restauración, ajustes por conteo, auditoría.       │
        └─────────────────────────────────────────────────────┘
```

**Regla de oro de la Capa 3:** en logística y contabilidad **nunca se borra ni se edita
un hecho consumado**. Se emite un movimiento que lo anula. El error queda visible, y eso
es una característica, no un defecto: si el error desaparece del historial, nadie
aprende de él y nadie responde por él.

---

## 3. Catálogo de modos de fallo

40 escenarios agrupados por etapa del flujo operativo. Cada uno lleva prioridad:
**P0** = imprescindible, **P1** = alto valor y bajo costo, **P2** = documentado y
justificado, fuera del alcance de esta entrega.

### 3.1 Recepción (INBOUND)

| # | Escenario real | Impacto | Tratamiento | P |
|---|---|---|---|---|
| E-01 | El proveedor anuncia 50 pares y entrega 48 | Stock del sistema queda inflado en 2 | `expected_quantity` vs `quantity` en el movimiento; la diferencia genera fila en `discrepancies` y la orden pasa a `COMPLETADA_PARCIAL` | P0 |
| E-02 | Entrega 52 cuando anunció 50 | Stock subvaluado; mercadería sin respaldo documental | Misma discrepancia con signo inverso; el sobrante exige aprobación de `JEFE` antes de ingresar | P0 |
| E-03 | Llega un modelo distinto al de la orden | Se ingresa stock a un SKU equivocado | El operario no elige el SKU: ejecuta la línea ya creada. Recibir otro SKU obliga a abrir discrepancia, no a "corregir" la línea | P0 |
| E-04 | **Llega talla 42 cuando la orden decía 41** | Error más frecuente en calzado; dos SKU quedan mal a la vez | Confirmación explícita de talla al ejecutar + alerta si el SKU ejecutado ≠ SKU de la línea | P0 |
| E-05 | Mercadería llega dañada o con defecto de fábrica | Stock vendible inflado con producto no vendible | `quality_status` (`BUENO`/`DANADO`/`CUARENTENA`) en el movimiento; solo `BUENO` suma a `quantity`, el resto a `qty_damaged` | P1 |
| E-06 | Dos operarios ejecutan la misma recepción | **Stock duplicado** | `idempotency_key` única por operación + `executed_at IS NULL` como condición del UPDATE. La segunda ejecución falla, no duplica | P0 |
| E-07 | Llega mercadería que nadie anunció | Sin trazabilidad de origen | Se permite crear una recepción sin orden previa, pero nace `PENDIENTE` y requiere aprobación de `SUPERVISOR` | P1 |
| E-08 | Se recibe en Bodega B lo que iba a Almacén A | Stock en el edificio equivocado | El almacén se hereda de la orden, no se escribe a mano; si no hay orden, es campo obligatorio con confirmación | P0 |
| E-09 | Se recibe pero no se ubica en ningún slot | Stock fantasma: existe pero nadie lo encuentra | Alerta `STOCK_SIN_UBICAR` si un ítem tiene `quantity > 0` sin `position_assignments` activa | P1 |
| E-10 | Se ubica en una posición distinta a la reservada | El mapa del almacén miente | La reserva se libera y se crea la asignación real, dejando rastro en auditoría; alerta si ocurre seguido | P1 |

### 3.2 Almacenamiento

| # | Escenario real | Impacto | Tratamiento | P |
|---|---|---|---|---|
| E-11 | Posición marcada ocupada pero físicamente vacía | El sistema bloquea espacio útil | Conteo cíclico (`inventory_counts`) por zona; alerta si una posición lleva > N días sin verificar | P1 |
| E-12 | Se asignan 500 pares a un slot con capacidad para 50 | Imposible físicamente; el mapa deja de servir | Trigger que valida `SUM(quantity) <= positions.capacity_units`. **Hoy el campo existe y nadie lo valida** | P0 |
| E-13 | Un SKU cae bajo mínimo y nadie se entera | Quiebre de stock, venta perdida | Alerta `STOCK_BAJO_MINIMO` generada por trigger sobre `inventory`, no por consulta del frontend | P0 |
| E-14 | Stock sobre el máximo definido | Capital inmovilizado, espacio ocupado | Alerta `STOCK_SOBRE_MAXIMO`, severidad informativa | P1 |
| E-15 | Un modelo lleva 6 meses sin movimiento | Obsolescencia; en calzado, temporada perdida | Alerta `SIN_ROTACION` calculada sobre `stock_ledger` | P2 |
| E-16 | El sistema dice 70 y físicamente hay 67 | Deriva de inventario acumulada | Conteo físico que genera un `AJUSTE` con motivo obligatorio y aprobación de `JEFE` | P0 |

### 3.3 Preparación y despacho (OUTBOUND)

| # | Escenario real | Impacto | Tratamiento | P |
|---|---|---|---|---|
| E-17 | Picking del modelo o talla equivocada | Se descuenta el SKU incorrecto; dos stocks mal | Confirmación de SKU + posición al ejecutar; discrepancia si no coinciden | P0 |
| E-18 | Se retiran 12 cuando el pedido pedía 10 | Stock descuadrado | `expected_quantity` vs real, igual que en INBOUND | P0 |
| E-19 | Se aprueba una salida mayor al stock existente | Stock negativo o despacho imposible | La RPC valida contra **disponible real** (`quantity - qty_reserved`), no contra `quantity` | P0 |
| E-20 | Se despacha stock ya comprometido a otro pedido | Un pedido se queda sin mercadería | `qty_reserved` se incrementa al aprobar y se libera al ejecutar. **Hoy la RPC no lo hace** | P0 |
| E-21 | Se retira de la posición equivocada | El mapa del almacén se desincroniza | La posición viaja en la línea del movimiento; cambiarla exige justificación | P1 |
| E-22 | El pedido se cancela después de haber retirado físicamente | Mercadería fuera de su slot y sin registro | Reversión por contra-asiento + nueva asignación de posición | P0 |
| E-23 | Solo se pudo armar parte del pedido | Estado binario no representa la realidad | Estado `COMPLETADA_PARCIAL` en la orden + discrepancia | P1 |

### 3.4 Captura de datos

| # | Escenario real | Impacto | Tratamiento | P |
|---|---|---|---|---|
| E-24 | **Dedazo: se escribe 100 en vez de 10** | Movimiento con orden de magnitud equivocada | Umbral de razonabilidad: si la cantidad supera N veces el promedio histórico del SKU, se exige confirmación adicional y sube a `approval_requests` | P0 |
| E-25 | Doble clic en "Crear movimiento" | Movimiento duplicado | `idempotency_key` única generada en el cliente por intento | P0 |
| E-26 | Fecha de movimiento en el futuro o de 2019 | Kardex y reportes inservibles | `CHECK` de rango razonable sobre `occurred_at` | P1 |
| E-27 | SKU inexistente o mal tipeado | Fila huérfana o error críptico | El SKU nunca se escribe a mano: se elige de un selector con búsqueda. FK obligatoria | P0 |
| E-28 | Precio 8500 en vez de 850.00 | Valor total del inventario absurdo | Alerta de variación: si el precio cambia > X% respecto al anterior, requiere aprobación | P1 |
| E-29 | Se confunde caja con par (12 pares por caja) | Stock multiplicado por 12 | `uom` y `units_per_box` explícitos en el ítem; la UI muestra siempre la unidad | P1 |

### 3.5 Autorización y control

| # | Escenario real | Impacto | Tratamiento | P |
|---|---|---|---|---|
| E-30 | **El mismo usuario crea y aprueba su movimiento** | Se anula todo el control interno | `CHECK (approved_by <> created_by)` a nivel de base de datos | P0 |
| E-31 | Se aprueba sin verificar que haya stock | Aprobaciones imposibles de ejecutar | La RPC valida disponibilidad **al aprobar**, no solo al ejecutar | P0 |
| E-32 | **Se elimina un artículo con historial de movimientos** | Kardex roto, trazabilidad perdida | Doble defensa: `ON DELETE RESTRICT` + eliminación lógica (`deleted_at`) que además exige aprobación de `JEFE` vía `approval_requests` | P0 |
| E-33 | Se edita un movimiento ya ejecutado | Se reescribe la historia | Movimientos ejecutados son inmutables por trigger; la única vía es la reversión | P0 |
| E-34 | Un operario intenta aprobar una salida grande | Escalamiento de privilegios | Límite por rol (`max_movement_qty`) + alerta de seguridad al registrar el intento | P1 |
| E-35 | Dos supervisores editan el mismo artículo a la vez | El último pisa al primero sin aviso | Bloqueo optimista: columna `version` que se incrementa; si no coincide, el guardado falla con "alguien más modificó este registro" | P1 |
| E-36 | Movimiento aprobado que nadie ejecuta en 3 días | Stock comprometido indefinidamente | Alerta `EJECUCION_VENCIDA` sobre la cola `APROBADO + executed_at IS NULL` | P1 |
| E-37 | Movimiento pendiente que nadie aprueba | La operación se frena sin que nadie lo note | Alerta `APROBACION_VENCIDA` por SLA configurable | P1 |

### 3.6 Identidad y trazabilidad

| # | Escenario real | Impacto | Tratamiento | P |
|---|---|---|---|---|
| E-38 | No se sabe quién hizo un cambio | Sin responsabilidad ni aprendizaje | `audit_log` alimentado por **trigger de base de datos**, no por el frontend | P0 |
| E-39 | Un usuario dado de baja deja acciones huérfanas | Historial ilegible | `is_active` en vez de borrado + `ON DELETE SET NULL` ya presente | P1 |
| E-40 | Movimientos sin motivo declarado | Imposible auditar el porqué | `reason` obligatorio para `AJUSTE` y para toda reversión | P0 |

---

## 4. Sistema de alertas

Lo que el usuario final de un almacén más valora, según el propio contexto del caso.
Una alerta no es un `console.log`: es una fila con ciclo de vida y responsable.

**Ciclo de vida:** `ACTIVA` → `RECONOCIDA` (alguien la vio y se hace cargo) → `RESUELTA`
(la condición desapareció). Nunca se borra.

**Severidades:** `CRITICA` (bloquea operación), `ADVERTENCIA` (requiere acción hoy),
`INFO` (visibilidad).

| Código | Condición | Severidad | Origen |
|---|---|---|---|
| `STOCK_BAJO_MINIMO` | `quantity <= min_stock` | CRÍTICA | Trigger en `inventory` |
| `STOCK_AGOTADO` | `quantity = 0` | CRÍTICA | Trigger en `inventory` |
| `STOCK_SOBRE_MAXIMO` | `quantity > max_stock` | INFO | Trigger en `inventory` |
| `DISCREPANCIA_RECEPCION` | `expected_quantity <> quantity` al ejecutar | ADVERTENCIA | Trigger en `inventory_movements` |
| `CANTIDAD_ATIPICA` | Cantidad > N× promedio histórico del SKU | ADVERTENCIA | Validación en la RPC |
| `APROBACION_VENCIDA` | `PENDIENTE` por más de X horas | ADVERTENCIA | Consulta programada |
| `EJECUCION_VENCIDA` | `APROBADO` sin ejecutar por más de X horas | ADVERTENCIA | Consulta programada |
| `STOCK_SIN_UBICAR` | `quantity > 0` sin asignación de posición activa | ADVERTENCIA | Consulta programada |
| `POSICION_SOBRECARGADA` | Asignación supera `capacity_units` | CRÍTICA | Trigger en `position_assignments` |
| `INTENTO_NO_AUTORIZADO` | Acción rechazada por permisos | ADVERTENCIA | RPC / RLS |
| `SIN_ROTACION` | Sin movimiento en N días | INFO | Consulta programada |
| `VARIACION_PRECIO` | Cambio de precio > X% | ADVERTENCIA | Trigger en `inventory_items` |

Los umbrales viven en `alert_rules`, **no hardcodeados**: un jefe de almacén cambia el
SLA de aprobación sin tocar código.

---

## 5. Confirmaciones escaladas (maker-checker)

Lo que el usuario describió como *"que se tenga que dar una confirmación de arriba"*.
El patrón: una acción sensible **no se ejecuta directamente**; se encola como solicitud
que un rol superior resuelve.

```
  Usuario intenta acción sensible
              │
              ▼
   ¿Su rol la autoriza directamente?
        │              │
       SÍ             NO
        │              │
        ▼              ▼
   Se ejecuta    approval_requests (PENDIENTE)
                        │
              ┌─────────┴─────────┐
              ▼                   ▼
          APROBADA            RECHAZADA
              │                   │
              ▼                   ▼
     Se ejecuta la acción    No pasa nada,
     y queda auditada        queda el intento
                             registrado
```

**Acciones que exigen escalamiento:**

| Acción | Quién la pide | Quién la aprueba | Por qué |
|---|---|---|---|
| Eliminar un artículo | SUPERVISOR | JEFE | Destruye maestro con historial |
| Revertir un movimiento ejecutado | SUPERVISOR | JEFE | Reescribe el stock consumado |
| Ajuste de inventario > umbral | SUPERVISOR | JEFE | Vía típica de encubrir faltantes |
| Movimiento con cantidad atípica | OPERARIO / SUPERVISOR | JEFE | Ataca el dedazo (E-24) |
| Recepción de sobrante no anunciado | OPERARIO | SUPERVISOR | Mercadería sin respaldo |
| Cambio de precio > X% | SUPERVISOR | JEFE | Afecta la valorización |
| Reactivar un registro eliminado | SUPERVISOR | JEFE | Restauración desde papelera |

---

## 6. Reversión ("reroll")

El punto que más distingue un sistema real de una maqueta.

**Lo que NO se hace:** `UPDATE inventory SET quantity = 70` ni `DELETE FROM
inventory_movements`. Eso destruye la evidencia y hace imposible auditar.

**Lo que sí se hace — contra-asiento:**

```
  Movimiento #125   SALIDA   20 unidades   EJECUTADO   (stock 100 → 80)
         │
         │  se detecta que fue un error
         ▼
  Movimiento #126   ENTRADA  20 unidades   EJECUTADO   (stock 80 → 100)
                    is_reversal = true
                    reversal_of_id = #125
                    reason = "Reversión: picking de talla equivocada"
                    aprobado por JEFE
```

Resultado: el stock vuelve a 100, el kardex tiene **tres** asientos (el original, la
reversa, y ambos ligados), y queda registrado quién se equivocó, quién autorizó la
corrección y por qué. El movimiento #125 nunca se toca.

**Reglas:**
1. Solo un movimiento con `executed_at IS NOT NULL` es reversible.
2. Solo `JEFE` aprueba una reversión.
3. `reason` obligatorio.
4. Un movimiento solo puede revertirse una vez (`UNIQUE` sobre `reversal_of_id`).
5. Una reversión no puede revertirse (se corrige emitiendo el movimiento original de nuevo).
6. Si el movimiento tenía posición asignada, la reversión restituye la ocupación.

**Papelera para maestros:** artículos y productos no se borran, se marcan con
`deleted_at` + `deleted_by`. Quedan invisibles en el dashboard, restaurables por `JEFE`,
y su historial permanece intacto.

---

## 7. Delta al esquema (Fase 1 bis)

### 7.1 Correcciones a lo ya escrito

| Hallazgo | Corrección |
|---|---|
| `qty_reserved` / `qty_incoming` nunca se mantienen | La RPC los incrementa al aprobar y los libera al ejecutar |
| `ck_inventory_reserved` puede reventar una salida legítima | Se reordena la lógica: primero liberar reserva, luego descontar stock, dentro de la misma transacción |
| Un `AJUSTE` solo puede sumar | Nueva columna `direction` (`+1`/`-1`) para ajustes, manteniendo `quantity > 0` |
| `capacity_units` declarado pero no validado | Trigger `fn_validar_capacidad_posicion()` |
| Sin segregación de funciones | `CHECK (approved_by IS NULL OR approved_by <> created_by)` |
| RPC en `security invoker` | Pasa a `SECURITY DEFINER` con `search_path` fijo en Fase 2 |

### 7.2 Tablas nuevas

| Tabla | Propósito | P |
|---|---|---|
| `audit_log` | Quién cambió qué, valor antes/después, por trigger genérico | P0 |
| `alerts` | Alertas con severidad y ciclo de vida | P0 |
| `alert_rules` | Umbrales configurables sin tocar código | P1 |
| `approval_requests` | Confirmaciones escaladas (maker-checker) | P0 |
| `discrepancies` | Esperado vs. real en recepción y despacho | P0 |
| `inventory_counts` / `inventory_count_lines` | Conteo cíclico y ajuste por diferencia | P1 |

### 7.3 Columnas nuevas

| Tabla | Columnas | P |
|---|---|---|
| `inventory_movements` | `expected_quantity`, `idempotency_key` (UNIQUE), `reversal_of_id` (UNIQUE), `is_reversal`, `quality_status`, `direction`, `version` | P0 |
| `inventory_orders` | `document_ref` (guía de remisión), estado `COMPLETADA_PARCIAL` | P1 |
| `inventory_items` | `deleted_at`, `deleted_by`, `uom`, `units_per_box`, `version` | P0/P1 |
| `products` | `deleted_at`, `deleted_by` | P0 |
| `inventory` | `qty_damaged`, `qty_quarantine` | P1 |
| `profiles` | roles `JEFE` y `AUDITOR`, `max_movement_qty` | P0 |

---

## 8. Alcance declarado

Lo que se decide **no** implementar, con su justificación — declararlo explícitamente
demuestra criterio, ocultarlo parece descuido:

| Fuera de alcance | Por qué |
|---|---|
| Lectura de código de barras / RFID | Requiere hardware; el campo `barcode` queda listo para integrarlo |
| Multi-empresa / multi-tenant | El caso describe una sola empresa |
| Costeo PEPS / promedio ponderado | El `stock_ledger` guarda el histórico necesario para calcularlo después |
| Notificaciones por correo o WhatsApp | Las alertas viven en la BD; el canal de envío es una integración aparte |
| Lotes y fechas de vencimiento | El calzado no vence; se documenta por completitud |
| Rotación de personal / turnos | Fuera del dominio del caso |

---

## 9. Cómo se sustenta esto

Preguntas probables del evaluador y dónde está la respuesta:

- *"¿Qué pasa si el operario se equivoca de talla?"* → E-04, discrepancias + reversión (§6)
- *"¿Qué pasa si aprueban y no hay stock?"* → E-19/E-31, validación contra disponible real
- *"¿Se puede borrar un artículo con movimientos?"* → E-32, `RESTRICT` + eliminación lógica + aprobación escalada
- *"¿Cómo deshaces un error ya ejecutado?"* → §6, contra-asiento, nunca `DELETE`
- *"¿Quién puede aprobar qué?"* → §1 y §5, matriz de roles y escalamiento
- *"¿Cómo evitas stock duplicado por doble clic?"* → E-06/E-25, `idempotency_key`
- *"¿Cómo se entera el jefe de que algo está mal?"* → §4, alertas con severidad y SLA
