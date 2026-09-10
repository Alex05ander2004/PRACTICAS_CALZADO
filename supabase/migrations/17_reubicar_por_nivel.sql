-- =============================================================================
--  MIGRACIÓN 17 — REUBICAR LO QUE QUEDÓ EN EL NIVEL EQUIVOCADO
--
--  La migración 15 amplió lo infantil a dos niveles y dejó a propósito donde
--  estaban las 68 asignaciones de calzado de adulto del nivel 2: cambiarlas de
--  fila no las baja del estante, y un WMS que dice que la caja está arriba
--  cuando sigue abajo es peor que uno que admite el pendiente.
--
--  Lo que falta es la otra mitad: la herramienta para saldarlas a medida que
--  alguien las mueve de verdad. Son dos cosas —
--
--    - v_reubicaciones_pendientes: qué está fuera de sitio y adónde debería ir.
--    - reubicar_asignacion(): liberar la posición vieja y ocupar la nueva en un
--      solo paso. Hacerlo desde el cliente con dos llamadas deja la mercadería
--      en el aire si la segunda falla: liberada de donde estaba y sin ubicar en
--      ninguna parte, que es exactamente cómo se pierde stock en un sistema.
--
--  Requiere 01-16. Idempotente.
-- =============================================================================


-- =============================================================================
--  BLOQUE A — QUÉ ESTÁ FUERA DE SITIO
-- =============================================================================
-- Sirve para las dos direcciones: adulto que quedó abajo (el caso de la 15) e
-- infantil que quedó arriba. La columna nivel_sugerido dice adónde tendría que
-- ir, que es lo que la pantalla ofrece con un clic.
create or replace view public.v_reubicaciones_pendientes as
select
  pa.id                       as assignment_id,
  pa.quantity                 as unidades,
  pa.status,
  it.id                       as item_id,
  it.sku,
  pr.name                     as producto,
  it.size_label               as talla,
  pr.audience                 as publico,
  w.code                      as almacen_code,
  w.name                      as almacen,
  r.id                        as rack_id,
  r.code                      as rack,
  pos.id                      as position_id,
  pos.code                    as posicion,
  pos.level                   as nivel,
  case when pr.audience = 'NINO' then 1 else public.fn_niveles_infantiles() + 1 end
                              as nivel_sugerido
from public.position_assignments pa
join public.positions       pos on pos.id = pa.position_id
join public.racks           r   on r.id   = pos.rack_id
join public.warehouses      w   on w.id   = r.warehouse_id
join public.inventory_items it  on it.id  = pa.item_id
join public.products        pr  on pr.id  = it.product_id
where pa.status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
  and (
    (pr.audience = 'NINO'   and pos.level >  public.fn_niveles_infantiles())
 or (pr.audience = 'ADULTO' and pos.level <= public.fn_niveles_infantiles())
  );

alter view public.v_reubicaciones_pendientes set (security_invoker = on);

comment on view public.v_reubicaciones_pendientes is
  'Mercadería ubicada en un nivel que la regla de público ya no admite. Es una lista de trabajo físico pendiente, no un error del sistema: se salda moviendo la caja y confirmando con reubicar_asignacion().';


-- =============================================================================
--  BLOQUE B — MOVER UNA ASIGNACIÓN DE UNA POSICIÓN A OTRA
-- =============================================================================
-- p_position_id opcional: si no viene, se busca el primer hueco válido del
-- MISMO rack. Que sea el mismo mueble no es un detalle — quien sube una caja
-- del estante 2 al 4 la deja donde estaba parado, y proponerle un rack al otro
-- lado del almacén sería inventarle trabajo.
create or replace function public.reubicar_asignacion(
  p_assignment_id uuid,
  p_position_id   uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_asg     public.position_assignments;
  v_origen  public.positions;
  v_destino public.positions;
  v_tope    integer := public.fn_niveles_infantiles();
  v_publico text;
  v_nueva   uuid;
begin
  perform public.fn_exigir_rol('OPERARIO', 'SUPERVISOR', 'JEFE');

  select * into v_asg from public.position_assignments where id = p_assignment_id;
  if v_asg.id is null then
    raise exception 'Esa ubicación ya no existe.';
  end if;
  if v_asg.status = 'LIBERADA' then
    raise exception 'Esa ubicación ya fue liberada: no hay nada que mover.';
  end if;

  select * into v_origen from public.positions where id = v_asg.position_id;

  select pr.audience into v_publico
    from public.inventory_items it
    join public.products pr on pr.id = it.product_id
   where it.id = v_asg.item_id;

  if p_position_id is not null then
    select * into v_destino from public.positions where id = p_position_id;
    if v_destino.id is null then
      raise exception 'La posición de destino no existe.';
    end if;
  else
    -- Primer hueco libre del mismo rack en un nivel que sí admita este público,
    -- y con sitio declarado para las unidades que se mueven.
    select p.* into v_destino
      from public.positions p
     where p.rack_id = v_origen.rack_id
       and p.id <> v_origen.id
       and p.is_active
       and case when v_publico = 'NINO' then p.level <= v_tope
                when v_publico = 'ADULTO' then p.level > v_tope
                else true end
       and p.capacity_units >= v_asg.quantity
                            + coalesce((select sum(a.quantity)
                                          from public.position_assignments a
                                         where a.position_id = p.id
                                           and a.status in ('RESERVADA','OCUPADA','EN_PICKING')), 0)
     order by p.level, p.slot
     limit 1;

    if v_destino.id is null then
      raise exception 'No hay ningún hueco libre en % para % unidades de %. Amplía el rack o libera espacio.',
        (select code from public.racks where id = v_origen.rack_id),
        v_asg.quantity,
        (select sku from public.inventory_items where id = v_asg.item_id);
    end if;
  end if;

  -- Las dos escrituras van juntas: la función es una sola transacción, así que
  -- o la caja termina ubicada en el destino o se queda donde estaba. Nunca en
  -- el limbo.
  update public.position_assignments
     set status = 'LIBERADA', released_at = now(), updated_at = now()
   where id = p_assignment_id;

  -- El trigger trg_assign_publico_nivel valida acá que el nivel de destino
  -- admita este público, y el de capacidad que quepa. Si algo no cuadra, la
  -- excepción revierte también el LIBERADA de arriba.
  insert into public.position_assignments (position_id, item_id, quantity, status, notes)
  values (v_destino.id, v_asg.item_id, v_asg.quantity, v_asg.status,
          'Reubicada desde ' || v_origen.code || ' (nivel ' || v_origen.level || ')')
  returning id into v_nueva;

  return jsonb_build_object(
    'estado',         'REUBICADA',
    'assignment_id',  v_nueva,
    'desde',          v_origen.code,
    'hasta',          v_destino.code,
    'nivel_anterior', v_origen.level,
    'nivel_nuevo',    v_destino.level,
    'mensaje',        'Movida de ' || v_origen.code || ' (nivel ' || v_origen.level ||
                      ') a ' || v_destino.code || ' (nivel ' || v_destino.level || ').'
  );
end;
$fn$;

grant execute on function public.reubicar_asignacion(uuid, uuid) to authenticated;

comment on function public.reubicar_asignacion is
  'Mueve una asignación a otra posición en una sola transacción. Sin destino explícito, busca el primer hueco válido del mismo rack. Se llama DESPUÉS de mover la caja de verdad: registra un movimiento físico, no lo ordena.';


-- =============================================================================
--  VERIFICACIÓN
-- =============================================================================
-- Cuánto queda por reubicar y adónde iría. Si el nivel sugerido no tiene huecos
-- en ese rack, reubicar_asignacion lo dirá al intentarlo.
select
  almacen_code,
  rack,
  publico,
  nivel          as nivel_actual,
  nivel_sugerido,
  count(*)       as asignaciones,
  sum(unidades)  as unidades
from public.v_reubicaciones_pendientes
group by almacen_code, rack, publico, nivel, nivel_sugerido
order by almacen_code, rack;
