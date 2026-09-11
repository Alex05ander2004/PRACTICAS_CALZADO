-- =============================================================================
--  MIGRACIÓN 20 — CASILLEROS POR MODELO, ESTANTES SINCRONIZADOS CON EL STOCK
--                 Y RACKS CON FORMA DE ESTANTERÍA
--
--  Una revisión de cómo se ubica la mercadería encontró que el stock y los
--  estantes podían contar historias distintas, y que el casillero desperdiciaba
--  espacio por una regla que el propio sistema contradecía:
--
--    1. Ejecutar una SALIDA restaba de inventory.quantity pero no tocaba
--       position_assignments: el mapa seguía mostrando las cajas que se habían
--       ido, y con el tiempo los estantes "tenían" más pares que el stock.
--    2. Los movimientos nunca decían de qué casillero salían ni a cuál entraban
--       (position_id llegaba siempre NULL), así que el punto 1 ni siquiera
--       tenía de dónde descontar.
--    3. v_stock_sin_ubicar era de todo o nada: 100 pares con 1 caja ubicada
--       figuraban como ubicados.
--    4. La capacidad se recalculaba con greatest(calculado, ocupado): un
--       casillero con más cajas de las que caben veía su capacidad inflada
--       hasta cuadrar, en vez de quedar marcado como sobrecargado. Y
--       capacity_units = 0 significaba "sin límite", así que el casillero
--       demasiado angosto para una sola caja admitía cualquier cantidad.
--    5. Un casillero admitía un solo artículo (índice único de la 01): una caja
--       de un modelo inmovilizaba un casillero de 200. Pero el trigger de
--       capacidad de la 02 ya sumaba varias asignaciones: la mitad del modelo
--       compartido existía y la otra mitad lo prohibía.
--    6. Un rack podía medir de 1x1 a 60x60 m. Una estantería real es larga y
--       angosta: el fondo se alcanza con el brazo desde el pasillo.
--
--  Decisiones del jefe de almacén:
--    - Un casillero guarda UN modelo con todas sus tallas juntas, hasta llenar
--      su capacidad en cajas. Es como se ordena un almacén de calzado: se va al
--      casillero del modelo y se elige la talla, sin confundir un modelo con
--      otro.
--    - Un rack tiene 1 m de fondo (una cara) o 2 m (dos espalda con espalda), y
--      su frente mide al menos el doble que su fondo.
--
--  "En estantes" cuenta lo OCUPADA y EN_PICKING. Lo RESERVADA es sitio apartado
--  para mercadería que todavía no llegó: ocupa lugar en el casillero, pero no
--  son pares que existan.
--
--  Requiere 01-19. Idempotente.
-- =============================================================================


-- =============================================================================
--  BLOQUE A — LA CAPACIDAD DICE LO QUE CABE, NO LO QUE HAY
-- =============================================================================
-- Sin el greatest(calculado, ocupado): un casillero pasado de cajas queda con
-- su capacidad física y se ve sobrecargado. Esconderlo inflando el número era
-- la forma más segura de que nadie lo arreglara nunca.
create or replace function public.fn_recalcular_capacidades(p_rack_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_frente numeric;
  v_fondo  numeric;
begin
  select greatest(grid_ancho, grid_alto), least(grid_ancho, grid_alto)
    into v_frente, v_fondo
    from public.racks where id = p_rack_id;

  update public.positions p
     set capacity_units = public.fn_cajas_en_slot(v_frente / n.slots, v_fondo, p.level),
         updated_at     = now()
    from (
      select pp.id, count(*) over (partition by pp.level) as slots
        from public.positions pp
       where pp.rack_id = p_rack_id
    ) n
   where n.id = p.id;
end;
$fn$;


-- =============================================================================
--  BLOQUE B — EL TRIGGER DE CAPACIDAD, SIN "0 = SIN LÍMITE" Y SIN TRABAR SALIDAS
-- =============================================================================
create or replace function public.fn_validar_capacidad_posicion()
returns trigger
language plpgsql
set search_path = public
as $fn$
declare
  v_capacidad integer;
  v_ocupado   integer;
  v_codigo    text;
begin
  if new.status = 'LIBERADA' then
    return new;
  end if;

  -- Sacar cajas nunca se bloquea, ni siquiera de un casillero sobrecargado: es
  -- justamente como se lo descarga.
  if tg_op = 'UPDATE' and old.status <> 'LIBERADA' and new.quantity <= old.quantity then
    return new;
  end if;

  -- Dos operarios ubicando en el mismo casillero a la vez sumarían cada uno
  -- sobre lo que vio antes que el otro. El candado serializa por casillero y
  -- cubre también el trigger de modelo, que corre después de este.
  perform pg_advisory_xact_lock(hashtext(new.position_id::text));

  select capacity_units, code into v_capacidad, v_codigo
    from public.positions where id = new.position_id;

  select coalesce(sum(quantity), 0) into v_ocupado
    from public.position_assignments
   where position_id = new.position_id
     and status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
     and id <> coalesce(new.id, '00000000-0000-0000-0000-000000000000'::uuid);

  -- Toda capacidad sale ahora de fn_cajas_en_slot: 0 no es "sin límite
  -- declarado" sino un casillero donde no entra ni una caja.
  if v_ocupado + new.quantity > coalesce(v_capacidad, 0) then
    raise exception 'El casillero % no tiene espacio: caben %, ya hay %, se intenta dejar %.',
      v_codigo, coalesce(v_capacidad, 0), v_ocupado, new.quantity
      using errcode = 'check_violation';
  end if;

  return new;
end;
$fn$;


-- =============================================================================
--  BLOQUE C — UN CASILLERO, UN MODELO (CON TODAS SUS TALLAS)
-- =============================================================================
-- El índice de la 01 decía "una asignación viva por casillero". Ahora es una
-- por talla y casillero: la misma talla dos veces en el mismo sitio sería la
-- misma caja contada dos veces, así que se suma a su fila en vez de duplicarla.
drop index if exists public.ux_position_assignment_activa;
create unique index if not exists ux_position_item_activa
  on public.position_assignments (position_id, item_id)
  where status in ('RESERVADA', 'OCUPADA', 'EN_PICKING');

create or replace function public.fn_validar_un_modelo_por_casillero()
returns trigger
language plpgsql
set search_path = public
as $fn$
declare
  v_modelo uuid;
  v_otro   text;
  v_codigo text;
begin
  if new.status = 'LIBERADA' then
    return new;
  end if;

  select product_id into v_modelo from public.inventory_items where id = new.item_id;

  select pr.model_code || ' ' || pr.name into v_otro
    from public.position_assignments pa
    join public.inventory_items it on it.id = pa.item_id
    join public.products        pr on pr.id = it.product_id
   where pa.position_id = new.position_id
     and pa.status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
     and pa.id <> coalesce(new.id, '00000000-0000-0000-0000-000000000000'::uuid)
     and it.product_id <> v_modelo
   limit 1;

  if v_otro is not null then
    select code into v_codigo from public.positions where id = new.position_id;
    raise exception 'El casillero % ya guarda %: un casillero admite un solo modelo, con todas sus tallas juntas. Usa otro casillero.',
      v_codigo, v_otro
      using errcode = 'check_violation';
  end if;

  return new;
end;
$fn$;

drop trigger if exists trg_assign_un_modelo on public.position_assignments;
create trigger trg_assign_un_modelo
  before insert or update on public.position_assignments
  for each row execute function public.fn_validar_un_modelo_por_casillero();

comment on trigger trg_assign_un_modelo on public.position_assignments is
  'Un casillero guarda un solo modelo, con cualquier combinación de sus tallas. Es lo que evita confundir un modelo con otro al hacer picking sin inmovilizar un casillero entero por una caja.';


-- =============================================================================
--  BLOQUE D — LA REGLA DE NIVEL NO TRABA SACAR CAJAS
-- =============================================================================
-- Con las salidas descontando del casillero (bloque F), una SALIDA de las
-- cajas de adulto que quedaron en el nivel 2 tras la migración 15 reescribe su
-- fila, y el trigger de público la rechazaba por estar en un nivel infantil.
-- Sacar cajas de donde ya están no ubica nada nuevo: se valida solo cuando se
-- ubica o se agrega.
create or replace function public.fn_validar_publico_por_nivel()
returns trigger
language plpgsql
set search_path = public
as $fn$
declare
  v_audience text;
  v_level    smallint;
  v_tope     integer := public.fn_niveles_infantiles();
begin
  if new.status = 'LIBERADA' then
    return new;
  end if;

  if tg_op = 'UPDATE'
     and new.position_id = old.position_id
     and new.item_id     = old.item_id
     and new.quantity   <= old.quantity then
    return new;
  end if;

  select p.audience into v_audience
    from public.inventory_items it
    join public.products        p  on p.id = it.product_id
   where it.id = new.item_id;

  select level into v_level from public.positions where id = new.position_id;

  if v_level is null then
    raise exception 'La posición % no tiene nivel definido.', new.position_id;
  end if;

  if v_audience = 'NINO' and v_level > v_tope then
    raise exception
      'Calzado infantil solo puede ubicarse hasta el nivel % (los de abajo). La posición elegida está en el nivel %.',
      v_tope, v_level
      using errcode = 'check_violation';
  end if;

  if v_audience = 'ADULTO' and v_level <= v_tope then
    raise exception
      'Calzado de adulto no puede ubicarse en el nivel %: los niveles 1 a % están reservados para calzado infantil.',
      v_level, v_tope
      using errcode = 'check_violation';
  end if;

  return new;
end;
$fn$;


-- =============================================================================
--  BLOQUE E — LAS VISTAS, AL DÍA CON LOS CASILLEROS COMPARTIDOS
-- =============================================================================
-- v_mapa_almacen ya devolvía una fila por asignación viva: con varias tallas en
-- un casillero, devuelve una por talla. Se agrega el modelo al final (create or
-- replace view solo permite sumar columnas detrás) para que la pantalla sepa
-- dónde puede ir cada artículo.
create or replace view public.v_mapa_almacen as
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
  pa.assigned_at,
  it.product_id,
  pr.model_code
from public.positions pos
join public.racks      r on r.id = pos.rack_id
join public.warehouses w on w.id = r.warehouse_id
left join public.position_assignments pa
       on pa.position_id = pos.id
      and pa.status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
left join public.inventory_items it on it.id = pa.item_id
left join public.products        pr on pr.id = it.product_id;

alter view public.v_mapa_almacen set (security_invoker = on);

-- Parcial y por almacén: lo que falta ubicar es el stock menos lo que ya está
-- en estantes de ESE almacén, no "¿tiene alguna caja en algún lado?".
create or replace view public.v_stock_sin_ubicar as
with en_estantes as (
  select pa.item_id, r.warehouse_id, sum(pa.quantity) as ubicado
    from public.position_assignments pa
    join public.positions pos on pos.id = pa.position_id
    join public.racks     r   on r.id   = pos.rack_id
   where pa.status in ('OCUPADA', 'EN_PICKING')
   group by pa.item_id, r.warehouse_id
)
select
  inv.id                               as inventory_id,
  it.sku,
  p.name                               as producto,
  it.size_label                        as talla,
  w.name                               as almacen,
  inv.quantity,
  coalesce(e.ubicado, 0)               as ubicado,
  inv.quantity - coalesce(e.ubicado, 0) as sin_ubicar
from public.inventory inv
join public.inventory_items it on it.id = inv.item_id
join public.products        p  on p.id  = it.product_id
join public.warehouses      w  on w.id  = inv.warehouse_id
left join en_estantes e on e.item_id = inv.item_id and e.warehouse_id = inv.warehouse_id
where inv.quantity > coalesce(e.ubicado, 0);

alter view public.v_stock_sin_ubicar set (security_invoker = on);


-- =============================================================================
--  BLOQUE F — LOS MOVIMIENTOS MUEVEN CAJAS EN LOS ESTANTES
-- =============================================================================
-- F.1 El casillero de un movimiento tiene que estar en el almacén de su stock.
-- Es lo único que no cambia entre crear y ejecutar, así que se revisa al crear;
-- cuántas cajas hay en el casillero se revisa al ejecutar, que es cuando importa.
create or replace function public.fn_validar_casillero_del_movimiento()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_wh_pos uuid;
  v_wh_inv uuid;
  v_codigo text;
begin
  if new.position_id is null or new.inventory_id is null then
    return new;
  end if;

  select r.warehouse_id, pos.code into v_wh_pos, v_codigo
    from public.positions pos
    join public.racks r on r.id = pos.rack_id
   where pos.id = new.position_id;

  select warehouse_id into v_wh_inv from public.inventory where id = new.inventory_id;

  if v_wh_pos is distinct from v_wh_inv then
    raise exception 'El casillero % está en otro almacén que el stock de este artículo.', v_codigo
      using errcode = 'check_violation';
  end if;

  return new;
end;
$fn$;

drop trigger if exists trg_mov_casillero on public.inventory_movements;
create trigger trg_mov_casillero
  before insert on public.inventory_movements
  for each row execute function public.fn_validar_casillero_del_movimiento();

-- F.2 Ejecutar: igual que en la 02, más el bloque "los estantes siguen al
-- stock". Como la reversión (fn_revertir_movimiento) inserta un contra-asiento
-- con el mismo position_id y lo ejecuta por acá, revertir también devuelve o
-- retira las cajas del casillero sin código adicional.
create or replace function public.fn_ejecutar_movimiento(
  p_movement_id   uuid,
  p_user_id       uuid    default null,
  p_cantidad_real integer default null,   -- NULL = llegó/salió exactamente lo aprobado
  p_quality       text    default 'BUENO'
)
returns public.inventory_movements
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_mov     public.inventory_movements;
  v_inv     public.inventory;
  v_real    integer;
  v_delta   integer;
  v_before  integer;
  v_pos     public.positions;
  v_pos_wh  uuid;
  v_asg     public.position_assignments;
  v_ubicado integer;
  v_donde   text;
begin
  select * into v_mov from public.inventory_movements where id = p_movement_id for update;
  if not found then
    raise exception 'El movimiento no existe.';
  end if;
  if v_mov.status <> 'APROBADO' then
    raise exception 'Solo se puede ejecutar un movimiento aprobado (este está %).', lower(v_mov.status);
  end if;
  -- DOBLE EJECUCIÓN (E-06): dos operarios recibiendo la misma orden.
  if v_mov.executed_at is not null then
    raise exception 'Este movimiento ya fue ejecutado el % y no puede volver a ejecutarse.', v_mov.executed_at;
  end if;

  v_real := coalesce(p_cantidad_real, v_mov.quantity);
  if v_real <= 0 then
    raise exception 'La cantidad ejecutada debe ser mayor que cero.';
  end if;

  select * into v_inv from public.inventory where id = v_mov.inventory_id for update;
  if not found then
    raise exception 'El movimiento no tiene registro de inventario asociado.';
  end if;

  v_before := v_inv.quantity;

  if v_mov.movement_type = 'ENTRADA' then
    if p_quality = 'BUENO' then
      update public.inventory
         set qty_incoming = greatest(qty_incoming - v_mov.quantity, 0),
             quantity     = quantity + v_real
       where id = v_inv.id;
      v_delta := v_real;
    else
      -- Dañada o en cuarentena: entra al almacén pero NO al stock vendible
      -- (E-05), y por lo mismo tampoco a un estante de venta.
      update public.inventory
         set qty_incoming    = greatest(qty_incoming - v_mov.quantity, 0),
             qty_damaged     = qty_damaged    + case when p_quality = 'DANADO'     then v_real else 0 end,
             qty_quarantine  = qty_quarantine + case when p_quality = 'CUARENTENA' then v_real else 0 end
       where id = v_inv.id;
      v_delta := 0;
    end if;

  elsif v_mov.movement_type = 'SALIDA' then
    if v_inv.quantity < v_real then
      raise exception 'No se puede retirar %: solo hay % en stock.', v_real, v_inv.quantity;
    end if;
    -- Reserva y stock en la MISMA sentencia: evita que qty_reserved <= quantity
    -- reviente a mitad.
    update public.inventory
       set qty_reserved = greatest(qty_reserved - v_mov.quantity, 0),
           quantity     = quantity - v_real
     where id = v_inv.id;
    v_delta := -v_real;

  else  -- AJUSTE: el signo lo da direction (permite corregir a la baja)
    v_delta := v_real * v_mov.direction;
    if v_inv.quantity + v_delta < 0 then
      raise exception 'El ajuste dejaría el stock en negativo (hay %, se ajusta %).', v_inv.quantity, v_delta;
    end if;
    update public.inventory set quantity = quantity + v_delta where id = v_inv.id;
  end if;

  -- ---------------------------------------------------------------------------
  -- LOS ESTANTES SIGUEN AL STOCK. v_delta ya es exactamente cuántas cajas
  -- entran (+) o salen (-) de circulación. Con casillero, se suman o restan
  -- ahí. Sin casillero, entrar deja las cajas en recepción; salir solo puede
  -- tomar de lo que no está en ningún estante, porque si no los estantes
  -- terminarían mostrando pares que ya no existen.
  -- ---------------------------------------------------------------------------
  if v_delta <> 0 and v_mov.position_id is not null then
    select * into v_pos from public.positions where id = v_mov.position_id;
    select warehouse_id into v_pos_wh from public.racks where id = v_pos.rack_id;
    if v_pos_wh is distinct from v_inv.warehouse_id then
      raise exception 'El casillero % está en otro almacén que el stock de este artículo.', v_pos.code;
    end if;

    select * into v_asg
      from public.position_assignments
     where position_id = v_mov.position_id
       and item_id     = v_mov.item_id
       and status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
     for update;

    if v_delta > 0 then
      -- Los triggers de capacidad, modelo y nivel opinan acá: si el casillero
      -- no admite estas cajas, la ejecución entera se revierte con el motivo.
      if v_asg.id is null then
        insert into public.position_assignments (position_id, item_id, quantity, status, assigned_by, notes)
        values (v_mov.position_id, v_mov.item_id, v_delta, 'OCUPADA', p_user_id,
                'Ubicada al ejecutar el movimiento ' || v_mov.id::text);
      else
        update public.position_assignments
           set quantity = quantity + v_delta, updated_at = now()
         where id = v_asg.id;
      end if;
    else
      if v_asg.id is null or v_asg.quantity < -v_delta then
        raise exception 'En el casillero % hay % de este artículo y se quieren sacar %.',
          v_pos.code, coalesce(v_asg.quantity, 0), -v_delta;
      end if;
      if v_asg.quantity = -v_delta then
        update public.position_assignments
           set quantity = 0, status = 'LIBERADA', released_at = now(), updated_at = now()
         where id = v_asg.id;
      else
        update public.position_assignments
           set quantity = quantity + v_delta, updated_at = now()
         where id = v_asg.id;
      end if;
    end if;

  elsif v_delta < 0 then
    select coalesce(sum(pa.quantity), 0) into v_ubicado
      from public.position_assignments pa
      join public.positions pos on pos.id = pa.position_id
      join public.racks     r   on r.id   = pos.rack_id
     where pa.item_id = v_mov.item_id
       and r.warehouse_id = v_inv.warehouse_id
       and pa.status in ('OCUPADA', 'EN_PICKING');

    if v_before - v_ubicado < -v_delta then
      select string_agg(pos.code || ' (' || pa.quantity || ')', ', ' order by pos.code)
        into v_donde
        from public.position_assignments pa
        join public.positions pos on pos.id = pa.position_id
        join public.racks     r   on r.id   = pos.rack_id
       where pa.item_id = v_mov.item_id
         and r.warehouse_id = v_inv.warehouse_id
         and pa.status in ('OCUPADA', 'EN_PICKING');

      raise exception 'Solo % de estos pares están fuera de los estantes y se quieren sacar % sin decir de qué casillero. Indica el casillero de origen: %.',
        greatest(v_before - v_ubicado, 0), -v_delta, coalesce(v_donde, 'ninguno');
    end if;
  end if;

  if v_delta <> 0 then
    insert into public.stock_ledger (movement_id, item_id, warehouse_id, position_id,
                                     qty_delta, qty_before, qty_after, executed_by)
    values (v_mov.id, v_mov.item_id, v_inv.warehouse_id, v_mov.position_id,
            v_delta, v_before, v_before + v_delta, p_user_id);
  end if;

  -- DISCREPANCIA (E-01/E-02/E-18): lo esperado no fue lo que pasó.
  if v_real <> v_mov.quantity then
    insert into public.discrepancies (movement_id, order_id, item_id, discrepancy_type,
                                      expected_qty, actual_qty, qty_diff, detail, reported_by)
    values (v_mov.id, v_mov.order_id, v_mov.item_id,
            case when v_real < v_mov.quantity then 'FALTANTE' else 'SOBRANTE' end,
            v_mov.quantity, v_real, v_real - v_mov.quantity,
            'Diferencia detectada al ejecutar el movimiento.', p_user_id);

    perform public.fn_emitir_alerta('DISCREPANCIA_RECEPCION', 'inventory_movements', v_mov.id,
      'Diferencia entre lo esperado y lo ejecutado',
      format('Esperado %s, real %s.', v_mov.quantity, v_real));
  end if;

  if p_quality <> 'BUENO' then
    insert into public.discrepancies (movement_id, order_id, item_id, discrepancy_type,
                                      expected_qty, actual_qty, qty_diff, detail, reported_by)
    values (v_mov.id, v_mov.order_id, v_mov.item_id, 'DANADO',
            v_mov.quantity, v_real, 0,
            format('Mercadería recibida con estado %s.', p_quality), p_user_id);
  end if;

  update public.inventory_movements
     set executed_at = now(), executed_by = p_user_id,
         expected_quantity = v_mov.quantity,
         quality_status = p_quality
   where id = v_mov.id
  returning * into v_mov;

  return v_mov;
end;
$fn$;


-- =============================================================================
--  BLOQUE G — UBICAR Y REUBICAR, CON CASILLEROS COMPARTIDOS
-- =============================================================================
-- G.1 Ubicar: por RPC y no con un INSERT desde el cliente. Si el casillero ya
-- guarda esta talla se suma a su fila (el índice admite una por talla), y no se
-- puede poner en un estante más pares de los que el almacén tiene: ese era el
-- otro camino por el que los estantes terminaban teniendo más que el stock.
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
  v_status  text := coalesce(p_status, 'OCUPADA');
begin
  perform public.fn_exigir_rol('OPERARIO', 'SUPERVISOR', 'JEFE');

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

  -- RESERVADA aparta sitio para un INBOUND que todavía no llegó: ahí no tiene
  -- sentido pedir stock. Lo demás son cajas físicas.
  if v_status <> 'RESERVADA' then
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
  end if;

  select * into v_asg
    from public.position_assignments
   where position_id = p_position_id
     and item_id     = p_item_id
     and status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
   for update;

  if v_asg.id is null then
    insert into public.position_assignments (position_id, item_id, quantity, status, assigned_by, notes)
    values (p_position_id, p_item_id, p_quantity, v_status, public.actor_actual(), p_notes)
    returning * into v_asg;
  else
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

-- G.2 Reubicar: ahora también a casilleros que ya guardan el mismo modelo y
-- tienen sitio, empezando por los que ya tienen esa misma talla (se suma a su
-- fila) y después los del mismo modelo, para juntar las tallas antes de
-- estrenar un casillero vacío.
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
  v_modelo   uuid;
  v_restante integer;
  v_cuanto   integer;
  v_usadas   integer := 0;
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
  -- Con el almacén delante: los códigos de rack se repiten entre almacenes.
  select w.code || ' · ' || r.code into v_rack
    from public.racks r
    join public.warehouses w on w.id = r.warehouse_id
   where r.id = v_origen.rack_id;

  select pr.audience, pr.id into v_publico, v_modelo
    from public.inventory_items it
    join public.products pr on pr.id = it.product_id
   where it.id = v_asg.item_id;

  -- Se libera primero; si algo falla más abajo, la excepción revierte también
  -- esto. La caja nunca queda en el limbo.
  update public.position_assignments
     set status = 'LIBERADA', released_at = now(), updated_at = now()
   where id = p_assignment_id;

  v_restante := v_asg.quantity;

  for v_destino in
    select p.id, p.code, p.level, p.slot,
           p.capacity_units - coalesce(oc.ocupado, 0) as libre,
           coalesce(oc.misma_talla, false)            as misma_talla,
           oc.ocupado is not null                     as mismo_modelo
      from public.positions p
      left join lateral (
        select sum(a.quantity)                    as ocupado,
               bool_or(a.item_id = v_asg.item_id) as misma_talla,
               bool_or(it.product_id <> v_modelo) as otro_modelo
          from public.position_assignments a
          join public.inventory_items it on it.id = a.item_id
         where a.position_id = p.id
           and a.status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
      ) oc on true
     where (p_position_id is null or p.id = p_position_id)
       and (p_position_id is not null or p.rack_id = v_origen.rack_id)
       and p.id <> v_origen.id
       and p.is_active
       and case when v_publico = 'NINO'   then p.level <= v_tope
                when v_publico = 'ADULTO' then p.level >  v_tope
                else true end
       and not coalesce(oc.otro_modelo, false)
       and p.capacity_units - coalesce(oc.ocupado, 0) > 0
     order by misma_talla desc, mismo_modelo desc, libre desc, p.level, p.slot
  loop
    exit when v_restante <= 0;

    v_cuanto := least(v_restante, v_destino.libre);

    update public.position_assignments
       set quantity = quantity + v_cuanto, updated_at = now()
     where position_id = v_destino.id
       and item_id     = v_asg.item_id
       and status in ('RESERVADA', 'OCUPADA', 'EN_PICKING');
    if not found then
      insert into public.position_assignments (position_id, item_id, quantity, status, notes)
      values (v_destino.id, v_asg.item_id, v_cuanto, v_asg.status,
              'Reubicada desde ' || v_origen.code || ' (nivel ' || v_origen.level || ')');
    end if;

    v_restante := v_restante - v_cuanto;
    v_usadas   := v_usadas + 1;
    v_donde    := v_donde || case when v_donde = '' then '' else ', ' end
                          || v_destino.code || ' (' || v_cuanto || ')';
  end loop;

  if v_restante > 0 then
    if v_usadas = 0 then
      raise exception 'En % no queda ningún casillero donde pueda ir este modelo de %: están ocupados por otros modelos, llenos, o son más angostos que la caja.',
        v_rack, lower(coalesce(v_publico, 'ese público'));
    end if;
    raise exception 'En % caben % de las % cajas en los % casilleros con sitio para este modelo. Faltan % — reparte el resto en otro rack.',
      v_rack, v_asg.quantity - v_restante, v_asg.quantity, v_usadas, v_restante;
  end if;

  return jsonb_build_object(
    'estado',     'REUBICADA',
    'casilleros', v_usadas,
    'desde',      v_origen.code,
    'mensaje',    case when v_usadas = 1
                    then 'Movida de ' || v_origen.code || ' a ' || v_donde || '.'
                    else v_asg.quantity || ' cajas de ' || v_origen.code ||
                         ' repartidas en ' || v_usadas || ' casilleros: ' || v_donde || '.'
                  end
  );
end;
$fn$;

grant execute on function public.reubicar_asignacion(uuid, uuid) to authenticated;


-- =============================================================================
--  BLOQUE H — UN RACK TIENE FORMA DE ESTANTERÍA
-- =============================================================================
-- H.1 La regla va en el trigger de geometría (con su porqué) además del CHECK:
-- los BEFORE triggers corren antes que los CHECK, así que quien arrastra un
-- rack en el editor lee esta explicación y no "violates ck_racks_geometria".
create or replace function public.fn_validar_geometria_rack()
returns trigger
language plpgsql
set search_path = public
as $fn$
declare
  v_alm       public.warehouses;
  v_conflicto text;
begin
  select * into v_alm from public.warehouses where id = new.warehouse_id;

  if least(new.grid_ancho, new.grid_alto) > 2 then
    raise exception 'El rack % tendría % m de fondo. Una estantería se usa desde el pasillo y el brazo no llega tan adentro: el fondo va de 1 m (una cara) a 2 m (dos estanterías espalda con espalda).',
      new.code, least(new.grid_ancho, new.grid_alto)
      using errcode = 'check_violation';
  end if;

  if greatest(new.grid_ancho, new.grid_alto) < 2 * least(new.grid_ancho, new.grid_alto) then
    raise exception 'El rack % sería de % x % m: una estantería es larga y angosta, y su frente tiene que medir al menos el doble que su fondo.',
      new.code, new.grid_ancho, new.grid_alto
      using errcode = 'check_violation';
  end if;

  if new.grid_x + new.grid_ancho > v_alm.grid_ancho
     or new.grid_y + new.grid_alto > v_alm.grid_alto then
    raise exception 'El rack % no cabe: se sale del plano del almacén (% x % celdas).',
      new.code, v_alm.grid_ancho, v_alm.grid_alto
      using errcode = 'check_violation';
  end if;

  -- Dos rectángulos se pisan solo si se solapan en LOS DOS ejes a la vez.
  select code into v_conflicto
    from public.racks
   where warehouse_id = new.warehouse_id
     and id <> new.id
     and new.grid_x < grid_x + grid_ancho
     and grid_x     < new.grid_x + new.grid_ancho
     and new.grid_y < grid_y + grid_alto
     and grid_y     < new.grid_y + new.grid_alto
   limit 1;

  if v_conflicto is not null then
    raise exception 'El rack % se superpone con el rack %. Muévelo a un espacio libre.',
      new.code, v_conflicto
      using errcode = 'check_violation';
  end if;

  if v_alm.entrada_x >= new.grid_x and v_alm.entrada_x < new.grid_x + new.grid_ancho
     and v_alm.entrada_y >= new.grid_y and v_alm.entrada_y < new.grid_y + new.grid_alto then
    raise exception 'El rack % taparía la entrada del almacén (celda %, %). Deja la puerta despejada.',
      new.code, v_alm.entrada_x, v_alm.entrada_y
      using errcode = 'check_violation';
  end if;

  return new;
end;
$fn$;

-- H.2 Los racks que no tienen forma de estantería se ACHICAN por el fondo.
-- Achicar nunca pisa otro rack ni tapa la puerta; agrandar podría, y decidir
-- hacia dónde crece un mueble es decidir por el usuario. Hoy son dos:
-- ALM-A · RACK-03 (12 x 3 -> 12 x 2) y ALM-04 · RACK-01 (2 x 2 -> 1 x 2).
-- El trigger trg_racks_capacidad recalcula la capacidad con la versión honesta
-- del bloque A: si quedan casilleros pasados de cajas, se verán.
update public.racks r
   set grid_ancho = case when r.grid_ancho <= r.grid_alto then s.fondo else r.grid_ancho end,
       grid_alto  = case when r.grid_ancho >  r.grid_alto then s.fondo else r.grid_alto  end
  from (
    select id,
           greatest(1, least(least(grid_ancho, grid_alto), 2, greatest(grid_ancho, grid_alto) / 2)) as fondo
      from public.racks
  ) s
 where s.id = r.id
   and (least(r.grid_ancho, r.grid_alto) > 2
        or greatest(r.grid_ancho, r.grid_alto) < 2 * least(r.grid_ancho, r.grid_alto));

-- H.3 Si alguno no se pudo arreglar achicándolo (un 1 x 1, por ejemplo), se
-- nombra acá en vez de dejar que el ALTER de abajo falle sin decir cuál.
do $bloque$
declare
  v_mal text;
begin
  select string_agg(w.code || ' · ' || r.code || ' (' || r.grid_ancho || ' x ' || r.grid_alto || ')', ', ')
    into v_mal
    from public.racks r
    join public.warehouses w on w.id = r.warehouse_id
   where least(r.grid_ancho, r.grid_alto) > 2
      or greatest(r.grid_ancho, r.grid_alto) < 2 * least(r.grid_ancho, r.grid_alto);

  if v_mal is not null then
    raise exception 'Estos racks no se pudieron llevar a forma de estantería achicándolos: %. Agrándalos a mano en el editor (el frente tiene que medir al menos el doble que el fondo) y vuelve a correr la migración.', v_mal;
  end if;
end;
$bloque$;

alter table public.racks drop constraint if exists ck_racks_geometria;
alter table public.racks
  add constraint ck_racks_geometria check (
    grid_x >= 0 and grid_y >= 0
    and least(grid_ancho, grid_alto) between 1 and 2
    and greatest(grid_ancho, grid_alto) between 2 and 60
    and greatest(grid_ancho, grid_alto) >= 2 * least(grid_ancho, grid_alto)
  );


-- =============================================================================
--  BLOQUE I — RECALCULAR TODO CON LA CAPACIDAD HONESTA
-- =============================================================================
do $bloque$
declare
  r record;
begin
  for r in select id from public.racks loop
    perform public.fn_recalcular_capacidades(r.id);
  end loop;
end;
$bloque$;


-- =============================================================================
--  VERIFICACIÓN
-- =============================================================================
-- 1. Casilleros con más cajas de las que caben. Antes la capacidad se inflaba
--    para taparlos; ahora quedan a la vista. Se descargan con una SALIDA desde
--    ese casillero o reubicando.
select w.code as almacen, r.code as rack, pos.code as casillero, pos.level as nivel,
       pos.capacity_units as caben, sum(pa.quantity) as hay
  from public.positions pos
  join public.racks      r on r.id = pos.rack_id
  join public.warehouses w on w.id = r.warehouse_id
  join public.position_assignments pa
    on pa.position_id = pos.id and pa.status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
 group by w.code, r.code, pos.code, pos.level, pos.capacity_units
having sum(pa.quantity) > pos.capacity_units
 order by 1, 2, 3;

-- 2. Artículos con más pares en estantes que en stock: el rastro que dejaron
--    las SALIDAS que no descontaban del casillero. Son cajas fantasma: se
--    corrigen liberando en el mapa lo que ya no está físicamente.
select w.code as almacen, it.sku, inv.quantity as stock, u.ubicado as en_estantes,
       u.ubicado - inv.quantity as sobran
  from public.inventory inv
  join public.inventory_items it on it.id = inv.item_id
  join public.warehouses      w  on w.id  = inv.warehouse_id
  join (
    select pa.item_id, r.warehouse_id, sum(pa.quantity) as ubicado
      from public.position_assignments pa
      join public.positions pos on pos.id = pa.position_id
      join public.racks     r   on r.id   = pos.rack_id
     where pa.status in ('OCUPADA', 'EN_PICKING')
     group by pa.item_id, r.warehouse_id
  ) u on u.item_id = inv.item_id and u.warehouse_id = inv.warehouse_id
 where u.ubicado > inv.quantity
 order by sobran desc;

-- 3. Todos los racks con forma de estantería.
select w.code as almacen, r.code as rack, r.grid_ancho || ' x ' || r.grid_alto as medida
  from public.racks r
  join public.warehouses w on w.id = r.warehouse_id
 order by 1, 2;
