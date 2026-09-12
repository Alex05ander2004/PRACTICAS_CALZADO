-- =============================================================================
--  MIGRACIÓN 34 — UBICAR A MANO YA NO ELIGE EL ESTADO
--
--  Hasta la migración 29, RESERVADA y EN_PICKING solo se conseguían a mano
--  desde el modal de ubicar: eran las únicas dos formas de marcar un casillero.
--  Desde la 29 los pone el movimiento, y quedan atados a él por movement_id.
--
--  Eso convierte la opción manual en una trampa: una marca sin movement_id no
--  la puede deshacer nadie automáticamente. fn_ejecutar_movimiento y
--  fn_rechazar_movimiento solo devuelven a OCUPADA lo que tiene movimiento
--  detrás —y a propósito, para no pisar una decisión de una persona—, así que
--  un RESERVADA puesto a mano se queda ocupando capacidad para siempre, y un
--  EN_PICKING manual deja cajas marcadas como comprometidas sin que ningún
--  pedido las libere.
--
--  A partir de aquí ubicar_en_casillero solo acepta OCUPADA: "estas cajas
--  están físicamente aquí". Apartar sitio se hace creando la ENTRADA, y
--  comprometer mercadería, creando la SALIDA.
--
--  Las funciones internas que mueven asignaciones (reubicar_asignacion,
--  fn_colocar) NO se tocan: conservan el estado que la asignación ya tenía,
--  que es justamente lo que debe pasar al mover de sitio algo comprometido.
--
--  Requiere 01-33. Idempotente.
-- =============================================================================

create or replace function public.ubicar_en_casillero(
  p_position_id uuid,
  p_item_id     uuid,
  p_quantity    integer,
  p_status      text default 'OCUPADA',
  p_notes       text default null
)
returns public.position_assignments
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_asg     public.position_assignments;
  v_wh      uuid;
  v_codigo  text;
  v_stock   integer;
  v_ubicado integer;
begin
  perform public.fn_exigir_rol('OPERARIO', 'SUPERVISOR', 'JEFE');

  -- El estado ya no se elige. Se sigue aceptando el parámetro para no romper
  -- a quien llame con la firma vieja, pero solo si pide OCUPADA.
  if coalesce(p_status, 'OCUPADA') <> 'OCUPADA' then
    raise exception
      'Ubicar a mano solo registra mercadería que ya está en el estante. Para apartar sitio crea una ENTRADA, y para comprometer cajas, una SALIDA: el casillero se marca solo.'
      using errcode = 'check_violation';
  end if;

  if p_quantity is null or p_quantity <= 0 then
    raise exception 'La cantidad debe ser mayor que cero.';
  end if;

  select r.warehouse_id, pos.code into v_wh, v_codigo
    from public.positions pos
    join public.racks r on r.id = pos.rack_id
   where pos.id = p_position_id;
  if v_wh is null then
    raise exception 'Ese casillero no existe.';
  end if;

  -- Siempre son cajas físicas, así que siempre se mide contra el stock.
  select quantity into v_stock
    from public.inventory
   where item_id = p_item_id and warehouse_id = v_wh;
  if v_stock is null then
    raise exception 'Este artículo no tiene stock registrado en el almacén del casillero %.', v_codigo;
  end if;

  select coalesce(sum(pa.quantity), 0) into v_ubicado
    from public.position_assignments pa
    join public.positions pos on pos.id = pa.position_id
    join public.racks     r   on r.id   = pos.rack_id
   where pa.item_id = p_item_id
     and r.warehouse_id = v_wh
     and pa.status in ('OCUPADA', 'EN_PICKING');

  if v_ubicado + p_quantity > v_stock then
    raise exception 'Hay % pares en stock y % ya están en estantes: quedan % por ubicar y se intenta ubicar %.',
      v_stock, v_ubicado, greatest(v_stock - v_ubicado, 0), p_quantity;
  end if;

  select * into v_asg
    from public.position_assignments
   where position_id = p_position_id
     and item_id     = p_item_id
     and status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
   for update;

  if v_asg.id is null then
    insert into public.position_assignments (position_id, item_id, quantity, status, assigned_by, notes)
    values (p_position_id, p_item_id, p_quantity, 'OCUPADA', public.actor_actual(), p_notes)
    returning * into v_asg;
  else
    -- Si el casillero estaba reservado o comprometido por un movimiento, las
    -- cajas se suman sin tocar esa marca: quien la puso la resolverá.
    update public.position_assignments
       set quantity = quantity + p_quantity,
           updated_at = now(),
           notes = coalesce(p_notes, notes)
     where id = v_asg.id
    returning * into v_asg;
  end if;

  return v_asg;
end;
$fn$;

grant execute on function public.ubicar_en_casillero(uuid, uuid, integer, text, text) to authenticated;

comment on function public.ubicar_en_casillero is
  'Registra cajas que ya están físicamente en un casillero (siempre OCUPADA). Reservar o comprometer no se hace aquí: lo marca el movimiento.';
