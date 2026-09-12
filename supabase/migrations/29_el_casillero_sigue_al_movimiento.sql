-- =============================================================================
--  MIGRACIÓN 29 — EL CASILLERO SIGUE EL CICLO DEL MOVIMIENTO
--
--  position_assignments tenía tres estados (RESERVADA, OCUPADA, EN_PICKING)
--  pero ningún proceso ponía dos de ellos: solo se conseguían a mano desde el
--  modal de ubicar. El ciclo del movimiento y el del casillero corrían por
--  separado, y había que acordarse de reflejar uno en el otro.
--
--  A partir de aquí, si el movimiento lleva casillero:
--
--    ENTRADA  crear   -> RESERVADA   (el hueco queda apartado; aún no hay cajas)
--             ejecutar-> OCUPADA     (llegaron: la reserva se convierte)
--             rechazar-> se libera   (el hueco vuelve a estar disponible)
--
--    SALIDA   crear   -> EN_PICKING  (las cajas están, pero comprometidas)
--             ejecutar-> se descuenta; vuelve a OCUPADA si queda saldo
--             rechazar-> vuelve a OCUPADA
--
--  Tres decisiones que conviene tener presentes:
--
--  1. La marca es del CASILLERO entero, no de un número de cajas. El índice
--     ux_position_item_activa admite una sola fila viva por casillero y
--     artículo, así que no se puede partir en "15 ocupadas + 10 en picking".
--     EN_PICKING significa "este casillero tiene un pedido encima"; cuántas
--     cajas salen lo dice el movimiento.
--
--  2. Si el casillero YA guarda ese artículo, una entrada no crea reserva: el
--     sitio ya es suyo y la fila viva es la misma. La capacidad se comprueba
--     igual al ejecutar.
--
--  3. Reservar ocupa capacidad de verdad. Es lo que se quiere —apartar sitio
--     es apartarlo— pero significa que una entrada a un casillero sin hueco
--     se rechaza al crearla, no al ejecutarla.
--
--  movement_id dice qué movimiento dejó la marca. Sirve para distinguir la que
--  puso un movimiento de la que puso una persona a mano, y para no deshacer la
--  de otro.
--
--  Requiere 01-28. Idempotente.
-- =============================================================================

alter table public.position_assignments
  add column if not exists movement_id uuid references public.inventory_movements (id) on delete set null;

comment on column public.position_assignments.movement_id is
  'Movimiento que dejó esta marca (RESERVADA o EN_PICKING). Se limpia al ejecutarlo o rechazarlo. NULL en las asignaciones puestas a mano.';

create index if not exists ix_assignments_movement
  on public.position_assignments (movement_id) where movement_id is not null;


-- =============================================================================
--  BLOQUE A — ¿QUEDA ALGÚN PEDIDO VIVO SOBRE ESTE CASILLERO?
-- =============================================================================
-- Se pregunta al resolver una salida: si había dos en cola, sacar una no
-- descompromete el casillero. Vivo = creado y todavía sin ejecutar ni rechazar.
create or replace function public.fn_hay_salida_viva(
  p_position_id uuid,
  p_item_id     uuid,
  p_excluir     uuid default null
)
returns boolean
language sql
stable
set search_path = public
as $fn$
  select exists (
    select 1
      from public.inventory_movements m
     where m.position_id = p_position_id
       and m.item_id     = p_item_id
       and m.id is distinct from p_excluir
       and m.status in ('PENDIENTE', 'APROBADO')
       and m.executed_at is null
       and (m.movement_type = 'SALIDA'
            or (m.movement_type = 'AJUSTE' and m.direction < 0))
  );
$fn$;

comment on function public.fn_hay_salida_viva is
  'Si algún otro movimiento de salida sigue esperando sobre ese casillero. Evita sacarlo del picking cuando había más de un pedido en cola.';


-- =============================================================================
--  BLOQUE B — MARCAR EL CASILLERO DE UN MOVIMIENTO
--
--  En una función y no dentro del trigger porque la usan dos: el trigger de
--  alta y el relleno del final, que le pasa los movimientos que ya estaban
--  pendientes. Dos copias de esta lógica acabarían separándose.
-- =============================================================================
create or replace function public.fn_marcar_casillero(p_mov public.inventory_movements)
returns text
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_delta integer;
  v_asg   public.position_assignments;
begin
  if p_mov.position_id is null or p_mov.status <> 'PENDIENTE' or p_mov.executed_at is not null then
    return 'SIN_CASILLERO';
  end if;

  v_delta := case p_mov.movement_type
               when 'ENTRADA' then  1
               when 'SALIDA'  then -1
               else coalesce(p_mov.direction, 1)
             end;

  select * into v_asg
    from public.position_assignments
   where position_id = p_mov.position_id
     and item_id     = p_mov.item_id
     and status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
   for update;

  if v_delta > 0 then
    -- Entrada: apartar el hueco. Si el casillero ya guarda este artículo no
    -- hace falta —el sitio ya es suyo— y además el índice no admitiría una
    -- segunda fila viva.
    if v_asg.id is not null then
      return 'YA_TENIA_SITIO';
    end if;

    insert into public.position_assignments
      (position_id, item_id, quantity, status, assigned_by, movement_id, notes)
    values
      (p_mov.position_id, p_mov.item_id, p_mov.quantity, 'RESERVADA', p_mov.created_by, p_mov.id,
       'Sitio apartado por el movimiento ' || p_mov.id::text);
    return 'RESERVADA';
  end if;

  -- Salida: lo que hay pasa a estar comprometido. Si no hay nada ubicado ahí
  -- no se marca nada, y al ejecutar fn_ejecutar_movimiento lo rechaza diciendo
  -- cuántas cajas hay realmente.
  if v_asg.id is null then
    return 'NADA_UBICADO';
  end if;
  if v_asg.status <> 'OCUPADA' then
    return 'YA_MARCADO';
  end if;

  update public.position_assignments
     set status = 'EN_PICKING', movement_id = p_mov.id, updated_at = now()
   where id = v_asg.id;
  return 'EN_PICKING';
end;
$fn$;

revoke execute on function public.fn_marcar_casillero(public.inventory_movements) from public, anon, authenticated;


create or replace function public.fn_marcar_casillero_al_crear()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
begin
  perform public.fn_marcar_casillero(new);
  return new;
end;
$fn$;

-- Va como trigger y no dentro de una RPC porque el movimiento se crea con un
-- INSERT directo desde el cliente (RLS lo permite, ver 03_rls.sql bloque E.8):
-- puesto aquí, la marca aparece venga el INSERT de donde venga.
drop trigger if exists trg_mov_marcar_casillero on public.inventory_movements;
create trigger trg_mov_marcar_casillero
  after insert on public.inventory_movements
  for each row execute function public.fn_marcar_casillero_al_crear();


-- =============================================================================
--  BLOQUE C — AL RECHAZAR, DESHACER LA MARCA
--
--  Copia de la versión vigente (migración 02) con el bloque de la marca.
-- =============================================================================
create or replace function public.fn_rechazar_movimiento(
  p_movement_id uuid,
  p_user_id     uuid default null,
  p_motivo      text default null
)
returns public.inventory_movements
language plpgsql
security definer
set search_path = public
as $$
declare v_mov public.inventory_movements;
begin
  select * into v_mov from public.inventory_movements where id = p_movement_id for update;
  if not found then
    raise exception 'El movimiento no existe.';
  end if;
  if v_mov.executed_at is not null then
    raise exception 'No se puede rechazar un movimiento ya ejecutado. Usa una reversión.';
  end if;
  if v_mov.status = 'RECHAZADO' then
    raise exception 'Este movimiento ya estaba rechazado.';
  end if;

  -- Si estaba aprobado, hay stock comprometido que hay que devolver.
  if v_mov.status = 'APROBADO' and v_mov.inventory_id is not null then
    if v_mov.movement_type = 'SALIDA' then
      update public.inventory set qty_reserved = greatest(qty_reserved - v_mov.quantity, 0)
       where id = v_mov.inventory_id;
    elsif v_mov.movement_type = 'ENTRADA' then
      update public.inventory set qty_incoming = greatest(qty_incoming - v_mov.quantity, 0)
       where id = v_mov.inventory_id;
    end if;
  end if;

  -- El hueco que se había apartado vuelve a estar libre. Se libera del todo y
  -- no se baja a cero: una fila viva en cero seguiría ocupando el índice.
  update public.position_assignments
     set status = 'LIBERADA', quantity = 0, released_at = now(),
         movement_id = null, updated_at = now()
   where movement_id = v_mov.id
     and status = 'RESERVADA';

  -- Lo comprometido vuelve a ser stock normal, salvo que otro pedido siga
  -- esperándolo.
  update public.position_assignments
     set status = 'OCUPADA', movement_id = null, updated_at = now()
   where movement_id = v_mov.id
     and status = 'EN_PICKING'
     and not public.fn_hay_salida_viva(position_id, item_id, v_mov.id);

  -- La que sigue comprometida por otro pedido deja de apuntar a este.
  update public.position_assignments
     set movement_id = null, updated_at = now()
   where movement_id = v_mov.id;

  update public.inventory_movements
     set status = 'RECHAZADO', approved_at = now(), approved_by = p_user_id,
         notes = concat_ws(' | ', notes, coalesce(p_motivo, 'Rechazado'))
   where id = p_movement_id
  returning * into v_mov;

  return v_mov;   -- el stock nunca se tocó, por diseño
end;
$$;


-- =============================================================================
--  BLOQUE D — AL EJECUTAR, CONVERTIR LA MARCA
--
--  Copiada de la migración 20 con dos cambios: la reserva de una entrada se
--  convierte en ocupación en vez de sumarse, y una salida saca el casillero
--  del picking cuando ya no queda pedido encima.
-- =============================================================================
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

      elsif v_asg.status = 'RESERVADA' and v_asg.movement_id = v_mov.id then
        -- El hueco que este mismo movimiento aparto al crearse. Ahora las
        -- cajas existen, asi que la reserva se convierte en ocupacion. Se PISA
        -- la cantidad en vez de sumarla —lo reservado no eran cajas, era
        -- sitio— y se usa v_delta, que es lo que de verdad llego y puede no
        -- coincidir con lo que se habia pedido.
        update public.position_assignments
           set quantity = v_delta, status = 'OCUPADA',
               movement_id = null, updated_at = now()
         where id = v_asg.id;

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
           set quantity = quantity + v_delta,
               -- Sale del picking cuando ya no queda ningun pedido vivo sobre
               -- el casillero. No se compara con este movimiento: con dos
               -- salidas encadenadas, la marca la dejo la primera y la segunda
               -- nunca podria retirarla. Una marca puesta a mano (movement_id
               -- nulo) no se toca: no la puso un movimiento.
               status = case
                 when v_asg.status = 'EN_PICKING'
                  and v_asg.movement_id is not null
                  and not public.fn_hay_salida_viva(v_mov.position_id, v_mov.item_id, v_mov.id)
                 then 'OCUPADA' else v_asg.status end,
               movement_id = case
                 when public.fn_hay_salida_viva(v_mov.position_id, v_mov.item_id, v_mov.id)
                 then v_asg.movement_id else null end,
               updated_at = now()
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
--  BLOQUE E — LOS MOVIMIENTOS QUE YA ESTABAN PENDIENTES
--
--  Sin esto, los pendientes de antes de la migración quedarían sin marca y la
--  base contradiría la regla que acaba de establecerse.
--
--  Cada uno va en su propio savepoint: reservar ocupa capacidad, y una entrada
--  a un casillero que hoy está lleno no puede reservar. Eso NO es motivo para
--  abortar la migración entera, pero tampoco para callarlo — se cuentan y se
--  listan los que no se pudieron, con su motivo.
-- =============================================================================
do $$
declare
  v_mov     public.inventory_movements;
  v_res     text;
  v_cuenta  jsonb := '{}'::jsonb;
  v_fallos  integer := 0;
  v_detalle text := '';
begin
  for v_mov in
    select * from public.inventory_movements
     where status = 'PENDIENTE'
       and position_id is not null
       and executed_at is null
     order by created_at
  loop
    begin
      v_res := public.fn_marcar_casillero(v_mov);
      v_cuenta := jsonb_set(v_cuenta, array[v_res],
                            to_jsonb(coalesce((v_cuenta ->> v_res)::integer, 0) + 1));
    exception when others then
      v_fallos  := v_fallos + 1;
      v_detalle := v_detalle || format(E'\n    %s de %s: %s',
                                       v_mov.movement_type, v_mov.quantity, sqlerrm);
    end;
  end loop;

  raise notice 'Movimientos pendientes marcados: %', v_cuenta;
  if v_fallos > 0 then
    raise notice 'No se pudo marcar % (siguen pendientes y se pueden ejecutar igual):%', v_fallos, v_detalle;
  end if;
end;
$$;


-- Cómo queda el reparto de estados en los casilleros.
do $$
declare v_fila record;
begin
  for v_fila in
    select status, count(*) as filas, sum(quantity) as cajas
      from public.position_assignments
     where status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
     group by status order by status
  loop
    raise notice '%: % casilleros, % cajas', v_fila.status, v_fila.filas, v_fila.cajas;
  end loop;
end;
$$;
