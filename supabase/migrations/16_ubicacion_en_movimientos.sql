-- =============================================================================
--  MIGRACIÓN 16 — LOS MOVIMIENTOS DICEN DÓNDE OCURRIERON
--
--  inventory_movements guarda position_id desde la migración 01, pero
--  v_movimientos_detalle nunca lo expuso: la pantalla de movimientos podía
--  decir qué entró y cuánto, no a qué rack. Para un almacén con seis racks por
--  edificio, "entraron 40 pares" sin decir dónde obliga a ir a buscarlos.
--
--  Ojo con lo que este dato significa, porque el mismo campo cambia de sentido
--  según el tipo de movimiento (así está comentado en la tabla original):
--      ENTRADA -> la posición es el DESTINO (dónde se guardó)
--      SALIDA  -> la posición es el ORIGEN  (de dónde se sacó)
--      AJUSTE  -> puede no tener ninguna: un ajuste contable no tiene sitio
--
--  Por eso la vista devuelve también `ubicacion_rol`, que dice cuál de las dos
--  cosas es. Un traslado de un rack a otro NO se puede representar: haría falta
--  un par origen/destino y la tabla solo tiene una columna. Hoy eso se registra
--  como una SALIDA y una ENTRADA sueltas, sin nada que las vincule.
--
--  Requiere 01-15. Idempotente.
-- =============================================================================


-- =============================================================================
--  BLOQUE A — LA VISTA EXPONE LA UBICACIÓN
-- =============================================================================
-- Las columnas nuevas van al final: create or replace view exige que las que ya
-- existen conserven nombre, tipo y orden.
create or replace view public.v_movimientos_detalle as
select
  m.id, m.created_at, m.approved_at, m.executed_at,
  it.sku, p.name as producto, it.size_label as talla,
  m.movement_type, m.direction, m.quantity, m.expected_quantity,
  m.quality_status, m.status,
  case
    when m.reversal_of_id is not null           then 'REVERSION'
    when r.id is not null                       then 'REVERTIDO'
    when m.executed_at is not null              then 'EJECUTADO'
    when m.status = 'APROBADO'                  then 'APROBADO_SIN_EJECUTAR'
    else m.status
  end                                as situacion,
  m.reversal_of_id,
  r.id                               as revertido_por,
  m.reason, m.notes,
  cb.full_name                       as creado_por,
  ab.full_name                       as aprobado_por,
  eb.full_name                       as ejecutado_por,
  -- Dónde ocurrió.
  w.code                             as almacen_code,
  w.name                             as almacen,
  rk.code                            as rack,
  pos.code                           as posicion,
  pos.level                          as nivel,
  case
    when pos.id is null              then null
    when m.movement_type = 'ENTRADA' then 'DESTINO'
    when m.movement_type = 'SALIDA'  then 'ORIGEN'
    else                                  'AFECTADA'
  end                                as ubicacion_rol
from public.inventory_movements m
join public.inventory_items it on it.id = m.item_id
join public.products        p  on p.id  = it.product_id
left join public.inventory_movements r on r.reversal_of_id = m.id
left join public.profiles  cb on cb.id = m.created_by
left join public.profiles  ab on ab.id = m.approved_by
left join public.profiles  eb on eb.id = m.executed_by
left join public.positions  pos on pos.id = m.position_id
left join public.racks      rk  on rk.id  = pos.rack_id
left join public.warehouses w   on w.id   = rk.warehouse_id;

-- La vista lee tablas con RLS: sin security_invoker correría con los permisos
-- del dueño y se saltaría las políticas. create or replace view no garantiza
-- conservar la opción, así que se reafirma.
alter view public.v_movimientos_detalle set (security_invoker = on);

comment on view public.v_movimientos_detalle is
  'Movimientos con su artículo, su situación real y dónde ocurrieron. ubicacion_rol dice si la posición es el origen o el destino: la columna position_id significa una cosa u otra según el tipo de movimiento.';


-- =============================================================================
--  VERIFICACIÓN
-- =============================================================================
-- Cuántos movimientos tienen coordenada física y cuántos no. Los AJUSTE sin
-- posición son normales (un ajuste contable no ocurre en ningún estante); una
-- ENTRADA o SALIDA sin posición significa que se ejecutó sin ubicar, que es
-- justo lo que esta columna deja ver.
select
  movement_type,
  coalesce(ubicacion_rol, 'SIN UBICACION') as ubicacion,
  count(*)                                 as movimientos
from public.v_movimientos_detalle
group by movement_type, ubicacion_rol
order by movement_type, ubicacion;
