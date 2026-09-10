-- =============================================================================
--  MIGRACIÓN 18 — REUBICAR REPARTIENDO, Y SIN PELEARSE CON EL ÍNDICE ÚNICO
--
--  La reubicar_asignacion() de la 17 fallaba de dos maneras distintas:
--
--    1. "duplicate key violates ux_position_assignment_activa". Buscaba el
--       destino sumando lo ya asignado a cada posición, como si varias
--       asignaciones pudieran compartir un casillero. No pueden: la migración
--       01 tiene un índice único parcial que garantiza UNA asignación viva por
--       posición — un casillero está libre o tiene un solo artículo. La
--       consulta elegía posiciones ocupadas y el índice, con razón, las
--       rechazaba.
--
--    2. "No hay ningún hueco libre en RACK-07 para 34 unidades". Ese es real y
--       no es un bug: en el nivel de adulto un casillero de RACK-07 admite 20
--       cajas, no 34. La caja de hombre (35 cm de largo) entra UNA vez en los
--       56 cm de frente del casillero; la infantil (22 cm) entra dos veces y
--       encima apila más alto, y por eso el mismo mueble guarda 110 abajo y 20
--       arriba. Lo que estaba mal era pretender mover el bulto entero a un solo
--       hueco: 34 cajas físicas no caben en un espacio de 20 y hay que
--       repartirlas, igual que se haría en el almacén de verdad.
--
--  Requiere 01-17. Idempotente.
-- =============================================================================


-- =============================================================================
--  BLOQUE A — REUBICAR PUDIENDO REPARTIR EN VARIOS CASILLEROS
-- =============================================================================
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
  v_asg      public.position_assignments;
  v_origen   public.positions;
  v_rack     text;
  v_destino  record;
  v_tope     integer := public.fn_niveles_infantiles();
  v_publico  text;
  v_restante integer;
  v_cuanto   integer;
  v_usadas   integer := 0;
  v_sitio    integer;
  v_huecos   integer;
  v_donde    text := '';
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
  -- Con el almacén delante: los códigos de rack se repiten entre almacenes
  -- (hay un RACK-01 en cada uno), así que "no cabe en RACK-07" a secas no dice
  -- a cuál de los tres ir.
  select w.code || ' · ' || r.code into v_rack
    from public.racks r
    join public.warehouses w on w.id = r.warehouse_id
   where r.id = v_origen.rack_id;

  select pr.audience into v_publico
    from public.inventory_items it
    join public.products pr on pr.id = it.product_id
   where it.id = v_asg.item_id;

  -- Se libera primero: la posición de origen sale del índice único y, si algo
  -- falla más abajo, la excepción revierte también esto. La función es una
  -- sola transacción, así que la caja nunca queda en el limbo.
  update public.position_assignments
     set status = 'LIBERADA', released_at = now(), updated_at = now()
   where id = p_assignment_id;

  v_restante := v_asg.quantity;

  -- Destino explícito: va todo ahí y que el trigger de capacidad opine.
  if p_position_id is not null then
    select * into v_destino from public.positions where id = p_position_id;
    if v_destino.id is null then
      raise exception 'La posición de destino no existe.';
    end if;
    insert into public.position_assignments (position_id, item_id, quantity, status, notes)
    values (v_destino.id, v_asg.item_id, v_restante, v_asg.status,
            'Reubicada desde ' || v_origen.code || ' (nivel ' || v_origen.level || ')');

    return jsonb_build_object(
      'estado', 'REUBICADA', 'casilleros', 1,
      'mensaje', 'Movida de ' || v_origen.code || ' a ' || v_destino.code || '.'
    );
  end if;

  -- Sin destino: se reparte entre los casilleros LIBRES del mismo rack cuyo
  -- nivel admita este público. Libres de verdad — sin ninguna asignación viva —
  -- porque el índice ux_position_assignment_activa no permite dos.
  for v_destino in
    select p.*
      from public.positions p
     where p.rack_id = v_origen.rack_id
       and p.id <> v_origen.id
       and p.is_active
       and p.capacity_units > 0
       and case when v_publico = 'NINO'   then p.level <= v_tope
                when v_publico = 'ADULTO' then p.level >  v_tope
                else true end
       and not exists (
         select 1 from public.position_assignments a
          where a.position_id = p.id
            and a.status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
       )
     order by p.capacity_units desc, p.level, p.slot
  loop
    exit when v_restante <= 0;

    v_cuanto := least(v_restante, v_destino.capacity_units);
    insert into public.position_assignments (position_id, item_id, quantity, status, notes)
    values (v_destino.id, v_asg.item_id, v_cuanto, v_asg.status,
            'Reubicada desde ' || v_origen.code || ' (nivel ' || v_origen.level || ')');

    v_restante := v_restante - v_cuanto;
    v_usadas   := v_usadas + 1;
    v_donde    := v_donde || case when v_donde = '' then '' else ', ' end
                          || v_destino.code || ' (' || v_cuanto || ')';
  end loop;

  if v_restante > 0 then
    -- Cuánto habría hecho falta, para que el mensaje diga qué resolver y no
    -- solo que no se pudo.
    select coalesce(sum(p.capacity_units), 0), count(*)
      into v_sitio, v_huecos
      from public.positions p
     where p.rack_id = v_origen.rack_id
       and p.id <> v_origen.id
       and p.is_active
       and p.capacity_units > 0
       and case when v_publico = 'NINO'   then p.level <= v_tope
                when v_publico = 'ADULTO' then p.level >  v_tope
                else true end
       and not exists (
         select 1 from public.position_assignments a
          where a.position_id = p.id
            and a.status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
       );

    if v_huecos = 0 then
      raise exception 'En % no queda ningún casillero libre donde pueda ir calzado de %. O están todos ocupados, o sus casilleros son más angostos que la caja (revisa cuántas posiciones por nivel tiene el rack: a más casilleros, más chico cada uno).',
        v_rack, lower(coalesce(v_publico, 'ese público'));
    end if;

    raise exception 'En % caben % cajas en los % casilleros libres, y hay que mover %. Faltan % — reparte el resto en otro rack o quítale casilleros a este para que cada uno sea más ancho.',
      v_rack, v_sitio, v_huecos, v_asg.quantity, v_asg.quantity - v_sitio;
  end if;

  return jsonb_build_object(
    'estado',     'REUBICADA',
    'casilleros', v_usadas,
    'desde',      v_origen.code,
    'mensaje',    case when v_usadas = 1
                    then 'Movida de ' || v_origen.code || ' a ' || v_donde || '.'
                    else v_asg.quantity || ' unidades de ' || v_origen.code ||
                         ' repartidas en ' || v_usadas || ' casilleros: ' || v_donde || '.'
                  end
  );
end;
$fn$;

grant execute on function public.reubicar_asignacion(uuid, uuid) to authenticated;

comment on function public.reubicar_asignacion is
  'Mueve una asignación al nivel que le corresponde, repartiéndola en varios casilleros si no cabe en uno. Un casillero admite una sola asignación viva (ux_position_assignment_activa), así que reparte entre los que estén libres. Se llama DESPUÉS de mover la caja de verdad.';


-- =============================================================================
--  VERIFICACIÓN
-- =============================================================================
-- Qué hay pendiente y si el rack tiene sitio para ello. Una fila con
-- faltan > 0 es un rack que no puede absorber lo suyo: hay que quitarle
-- casilleros (para que cada uno sea más ancho) o llevar el resto a otro.
with pend as (
  select rp.rack_id, rp.rack, rp.almacen_code, rp.publico,
         sum(rp.unidades) as hay_que_mover
    from public.v_reubicaciones_pendientes rp
   group by rp.rack_id, rp.rack, rp.almacen_code, rp.publico
),
sitio as (
  select p.rack_id,
         sum(p.capacity_units) filter (where p.level > public.fn_niveles_infantiles()) as cabe_arriba,
         sum(p.capacity_units) filter (where p.level <= public.fn_niveles_infantiles()) as cabe_abajo
    from public.positions p
   where p.is_active
     and not exists (
       select 1 from public.position_assignments a
        where a.position_id = p.id
          and a.status in ('RESERVADA', 'OCUPADA', 'EN_PICKING'))
   group by p.rack_id
)
select
  pend.almacen_code,
  pend.rack,
  pend.publico,
  pend.hay_que_mover,
  case when pend.publico = 'NINO' then coalesce(sitio.cabe_abajo, 0)
       else coalesce(sitio.cabe_arriba, 0) end                        as cabe_en_los_libres,
  greatest(0, pend.hay_que_mover
             - case when pend.publico = 'NINO' then coalesce(sitio.cabe_abajo, 0)
                    else coalesce(sitio.cabe_arriba, 0) end)          as faltan
from pend
left join sitio on sitio.rack_id = pend.rack_id
order by faltan desc, pend.almacen_code, pend.rack;
