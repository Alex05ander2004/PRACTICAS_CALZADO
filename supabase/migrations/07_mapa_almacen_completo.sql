-- =============================================================================
--  MIGRACIÓN 07 — v_mapa_almacen: exponer los IDs que la UI necesita
--
--  La vista original (Fase 1) traía todo lo necesario para LEER el mapa, pero
--  nada para ACTUAR sobre él: sin position.id no hay forma de decirle a
--  asignarPosicion() cuál posición usar, y sin position_assignments.id no hay
--  forma de decirle a liberarPosicion() cuál asignación cerrar. Se descubrió
--  al construir la pantalla de "Mapa del almacén" — la vista se quedó corta
--  para lo que el CASO realmente pedía (poder actuar sobre el mapa, no solo
--  mirarlo). También se agrega el nivel (regla infantil/adulto de la
--  migración 04) y el público del producto, para poder mostrar y validar esa
--  regla directamente en el mapa.
--
--  Requiere 01-06. Idempotente.
--
--  Nota: es DROP + CREATE, no CREATE OR REPLACE. Postgres solo permite
--  REPLACE si las columnas existentes conservan su nombre y su posición —
--  como position_id se agrega AL PRINCIPIO (no al final), REPLACE lo rechaza
--  con "cannot change name of view column". Ninguna otra migración depende de
--  esta vista (no hay FKs sobre vistas), así que recrearla es seguro.
-- =============================================================================

drop view if exists public.v_mapa_almacen;

create view public.v_mapa_almacen as
select
  pos.id            as position_id,
  w.code            as almacen_code,
  w.name            as almacen,
  r.code            as rack,
  pos.code          as posicion,
  pos.level,
  pos.capacity_units,
  pa.id             as assignment_id,
  pa.status         as estado_ocupacion,   -- NULL = libre
  pa.quantity       as unidades,
  pa.item_id,
  it.sku,
  pr.name           as producto,
  it.size_label     as talla,
  pr.audience,
  pa.assigned_at
from public.positions pos
join public.racks      r on r.id = pos.rack_id
join public.warehouses w on w.id = r.warehouse_id
left join public.position_assignments pa
       on pa.position_id = pos.id
      and pa.status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
left join public.inventory_items it on it.id = pa.item_id
left join public.products        pr on pr.id = it.product_id;

alter view public.v_mapa_almacen set (security_invoker = on);

comment on view public.v_mapa_almacen is
  'Mapa completo del almacén: todas las posiciones, libres y ocupadas, con los IDs necesarios para actuar (asignar/liberar), no solo para mostrar.';
