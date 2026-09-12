-- =============================================================================
--  MIGRACIÓN 30 — LOS MOVIMIENTOS PENDIENTES QUE APUNTAN A DONDE NO DEBEN
--
--  Al marcar los casilleros (migración 29) salieron a la luz 33 de los 38
--  movimientos pendientes: no se les pudo poner la marca porque el casillero
--  que llevan no sirve. No es un problema de la 29 — esos movimientos ya eran
--  inejecutables, solo que el error habría aparecido al ejecutarlos:
--
--    · 18 ENTRADAS de calzado de adulto apuntando a un nivel infantil. Son
--      datos sembrados antes de que existiera la regla de niveles (migración
--      15), así que nunca fueron válidos con las reglas de hoy.
--
--    · 15 SALIDAS que dicen sacar de un casillero donde ese artículo no está.
--
--  Se corrige la INTENCIÓN, que es lo único que hay: el casillero de un
--  movimiento pendiente es una propuesta, no un hecho. Nada de stock cambia.
--
--    · La entrada que no puede ir a ese casillero pasa a "recepción"
--      (position_id NULL): entra igual y se ubica después, que es justamente
--      para lo que existe esa opción.
--
--    · La salida se reapunta al casillero donde ese artículo sí tiene cajas
--      (el que más tenga, en el mismo almacén). Si no está en ninguno, pasa
--      también a recepción y saldrá del stock sin ubicar.
--
--  Requiere 01-29. Idempotente: al volver a correrla no encuentra nada que
--  corregir.
-- =============================================================================

-- -----------------------------------------------------------------------------
--  A. Entradas hacia un casillero que no las admite
-- -----------------------------------------------------------------------------
-- Se comprueban las tres reglas que aplican los triggers: el nivel según el
-- público, que el casillero no sea de otro modelo, y que quepan.
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
    ) oc on true
   where m.status = 'PENDIENTE'
     and m.executed_at is null
     and m.position_id is not null
     and (m.movement_type = 'ENTRADA'
          or (m.movement_type = 'AJUSTE' and coalesce(m.direction, 1) > 0))
     and (
          (it.audience = 'NINO')   <> (pos.level <= public.fn_niveles_infantiles())
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
--  B. Salidas desde un casillero donde el artículo no está
-- -----------------------------------------------------------------------------
-- Se reapunta al casillero con más cajas de ese artículo dentro del mismo
-- almacén. El almacén sale del registro de inventario del movimiento y, si
-- todavía no tiene uno, del almacén del casillero que llevaba.
with sin_cajas as (
  select m.id, m.item_id,
         coalesce(inv.warehouse_id, r.warehouse_id) as warehouse_id
    from public.inventory_movements m
    join public.positions pos on pos.id = m.position_id
    join public.racks     r   on r.id   = pos.rack_id
    left join public.inventory inv on inv.id = m.inventory_id
   where m.status = 'PENDIENTE'
     and m.executed_at is null
     and m.position_id is not null
     and (m.movement_type = 'SALIDA'
          or (m.movement_type = 'AJUSTE' and coalesce(m.direction, 1) < 0))
     and not exists (
       select 1 from public.position_assignments pa
        where pa.position_id = m.position_id
          and pa.item_id     = m.item_id
          and pa.status in ('OCUPADA', 'EN_PICKING')
     )
),
mejor as (
  select sc.id,
         (select pa.position_id
            from public.position_assignments pa
            join public.positions pos2 on pos2.id = pa.position_id
            join public.racks     r2   on r2.id   = pos2.rack_id
           where pa.item_id = sc.item_id
             and pa.status  = 'OCUPADA'
             and r2.warehouse_id = sc.warehouse_id
           order by pa.quantity desc, pos2.code
           limit 1) as destino
    from sin_cajas sc
)
update public.inventory_movements m
   set position_id = mejor.destino,
       notes = concat_ws(' | ', m.notes,
                         case when mejor.destino is null
                              then 'Casillero retirado: el artículo no está en ningún estante de este almacén.'
                              else 'Casillero corregido: el artículo no estaba en el que traía.' end)
  from mejor
 where m.id = mejor.id;


-- -----------------------------------------------------------------------------
--  C. Ahora sí, marcar los que quedaron con un casillero válido
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
     where m.status = 'PENDIENTE'
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

  raise notice 'Marcado tras sanear: %', v_cuenta;
  if v_fallos > 0 then
    raise notice 'Siguen sin marca % :%', v_fallos, v_det;
  end if;
end;
$$;


-- -----------------------------------------------------------------------------
--  D. Cómo queda
-- -----------------------------------------------------------------------------
do $$
declare v_f record;
begin
  for v_f in
    select status, count(*) as filas, sum(quantity) as cajas
      from public.position_assignments
     where status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
     group by status order by status
  loop
    raise notice 'Casilleros %: % filas, % cajas', v_f.status, v_f.filas, v_f.cajas;
  end loop;

  for v_f in
    select movement_type,
           count(*) filter (where position_id is not null) as con_casillero,
           count(*) filter (where position_id is null)     as a_recepcion
      from public.inventory_movements
     where status = 'PENDIENTE' and executed_at is null
     group by movement_type order by movement_type
  loop
    raise notice 'Pendientes %: % con casillero, % a recepción',
      v_f.movement_type, v_f.con_casillero, v_f.a_recepcion;
  end loop;
end;
$$;
