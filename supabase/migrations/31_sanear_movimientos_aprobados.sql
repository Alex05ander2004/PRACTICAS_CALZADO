-- =============================================================================
--  MIGRACIÓN 31 — LO MISMO, PARA LOS MOVIMIENTOS YA APROBADOS
--
--  La migración 30 saneó los movimientos PENDIENTES, pero se dejó fuera los
--  APROBADOS, que arrastran exactamente el mismo defecto de origen: 29 de los
--  33 aprobados sin ejecutar apuntan a un casillero imposible (21 entradas de
--  adulto hacia niveles infantiles, 8 salidas desde casilleros donde ese
--  artículo no está). Pulsar "Ejecutar" en cualquiera de ellos falla.
--
--  Aprobado y pendiente son lo mismo a estos efectos: mientras executed_at sea
--  NULL, el casillero es una intención y todavía se puede corregir. Por eso
--  aquí el saneamiento se hace para los dos estados a la vez, y así vale
--  también si mañana vuelve a hacer falta.
--
--  No se toca ni el stock ni qty_reserved/qty_incoming: lo que un movimiento
--  aprobado tiene comprometido sigue comprometido igual, solo cambia dónde
--  dice que va a dejar o sacar las cajas.
--
--  Requiere 01-30. Idempotente.
-- =============================================================================

-- -----------------------------------------------------------------------------
--  A. Entradas hacia un casillero que no las admite -> a recepción
-- -----------------------------------------------------------------------------
with malas as (
  select m.id
    from public.inventory_movements m
    join public.inventory_items it  on it.id = m.item_id
    join public.positions       pos on pos.id = m.position_id
    left join lateral (
      select coalesce(sum(pa.quantity), 0) as ocupado,
             bool_or(oit.product_id <> it.product_id) as otro_modelo
        from public.position_assignments pa
        join public.inventory_items oit on oit.id = pa.item_id
       where pa.position_id = pos.id
         and pa.status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
         and pa.movement_id is distinct from m.id   -- su propia reserva no estorba
    ) oc on true
   where m.status in ('PENDIENTE', 'APROBADO')
     and m.executed_at is null
     and m.position_id is not null
     and (m.movement_type = 'ENTRADA'
          or (m.movement_type = 'AJUSTE' and coalesce(m.direction, 1) > 0))
     and (
          (it.audience = 'NINO') <> (pos.level <= public.fn_niveles_infantiles())
       or coalesce(oc.otro_modelo, false)
       or m.quantity > coalesce(pos.capacity_units, 0) - coalesce(oc.ocupado, 0)
     )
)
update public.inventory_movements m
   set position_id = null,
       notes = concat_ws(' | ', m.notes,
                         'Casillero retirado: no admitía este artículo. Entra a recepción y se ubica después.')
  from malas
 where m.id = malas.id;


-- -----------------------------------------------------------------------------
--  B. Salidas desde un casillero sin ese artículo -> donde sí lo haya
-- -----------------------------------------------------------------------------
with sin_cajas as (
  select m.id, m.item_id, m.quantity,
         coalesce(inv.warehouse_id, r.warehouse_id) as warehouse_id
    from public.inventory_movements m
    join public.positions pos on pos.id = m.position_id
    join public.racks     r   on r.id   = pos.rack_id
    left join public.inventory inv on inv.id = m.inventory_id
   where m.status in ('PENDIENTE', 'APROBADO')
     and m.executed_at is null
     and m.position_id is not null
     and (m.movement_type = 'SALIDA'
          or (m.movement_type = 'AJUSTE' and coalesce(m.direction, 1) < 0))
     and not exists (
       select 1 from public.position_assignments pa
        where pa.position_id = m.position_id
          and pa.item_id     = m.item_id
          and pa.status in ('OCUPADA', 'EN_PICKING')
          and pa.quantity   >= m.quantity
     )
),
mejor as (
  select sc.id,
         (select pa.position_id
            from public.position_assignments pa
            join public.positions pos2 on pos2.id = pa.position_id
            join public.racks     r2   on r2.id   = pos2.rack_id
           where pa.item_id = sc.item_id
             and pa.status in ('OCUPADA', 'EN_PICKING')
             and r2.warehouse_id = sc.warehouse_id
             and pa.quantity >= sc.quantity      -- que quepa la salida entera
           order by pa.quantity desc, pos2.code
           limit 1) as destino
    from sin_cajas sc
)
update public.inventory_movements m
   set position_id = mejor.destino,
       notes = concat_ws(' | ', m.notes,
                         case when mejor.destino is null
                              then 'Casillero retirado: no hay un estante con tantas cajas de este artículo.'
                              else 'Casillero corregido: el artículo no estaba en el que traía.' end)
  from mejor
 where m.id = mejor.id;


-- -----------------------------------------------------------------------------
--  C. La marca también vale para un movimiento aprobado
-- -----------------------------------------------------------------------------
-- Un aprobado sin ejecutar compromete el casillero igual que uno pendiente: la
-- mercadería sigue sin llegar (entrada) o sin salir (salida). Limitar la marca
-- a PENDIENTE dejaba sin señalar justo los que están más cerca de ejecutarse.
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
  if p_mov.position_id is null
     or p_mov.status not in ('PENDIENTE', 'APROBADO')
     or p_mov.executed_at is not null then
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


-- -----------------------------------------------------------------------------
--  D. Marcar todo lo que quedó con un casillero válido y aún sin marca
-- -----------------------------------------------------------------------------
do $$
declare
  v_mov    public.inventory_movements;
  v_res    text;
  v_cuenta jsonb := '{}'::jsonb;
  v_fallos integer := 0;
  v_det    text := '';
begin
  for v_mov in
    select m.* from public.inventory_movements m
     where m.status in ('PENDIENTE', 'APROBADO')
       and m.executed_at is null
       and m.position_id is not null
       and not exists (select 1 from public.position_assignments pa where pa.movement_id = m.id)
     order by m.created_at
  loop
    begin
      v_res := public.fn_marcar_casillero(v_mov);
      v_cuenta := jsonb_set(v_cuenta, array[v_res],
                            to_jsonb(coalesce((v_cuenta ->> v_res)::integer, 0) + 1));
    exception when others then
      v_fallos := v_fallos + 1;
      v_det := v_det || format(E'\n    %s de %s: %s', v_mov.movement_type, v_mov.quantity, sqlerrm);
    end;
  end loop;

  raise notice 'Marcado: %', v_cuenta;
  if v_fallos > 0 then
    raise notice 'Sin marca % :%', v_fallos, v_det;
  end if;
end;
$$;


-- -----------------------------------------------------------------------------
--  E. Cuántos quedan ejecutables
-- -----------------------------------------------------------------------------
do $$
declare v_f record;
begin
  for v_f in
    select status,
           count(*)                                        as total,
           count(*) filter (where position_id is null)     as a_recepcion,
           count(*) filter (where position_id is not null) as con_casillero
      from public.inventory_movements
     where status in ('PENDIENTE', 'APROBADO') and executed_at is null
     group by status order by status
  loop
    raise notice '%: % sin ejecutar (% con casillero, % a recepción)',
      v_f.status, v_f.total, v_f.con_casillero, v_f.a_recepcion;
  end loop;

  for v_f in
    select status, count(*) as filas, sum(quantity) as cajas
      from public.position_assignments
     where status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
     group by status order by status
  loop
    raise notice 'Casilleros %: % filas, % cajas', v_f.status, v_f.filas, v_f.cajas;
  end loop;
end;
$$;
