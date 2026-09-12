-- =============================================================================
--  04 — AJUSTES DESPUÉS DE CARGAR LOS DATOS
--
--  Cuatro de las migraciones no crean estructura: transforman datos que ya
--  existen. En una instalación limpia se ejecutan sobre una base vacía, no
--  encuentran nada y no hacen nada. Hay que volver a pasarlas DESPUÉS de los
--  seeds, y eso es lo que hay aquí:
--
--    · 23 — parte cada rack en casilleros a medida de un modelo
--    · 28 — pone las medidas de la caja a los artículos que no las traen
--    · 30 y 31 — corrigen los movimientos que apuntan a un casillero imposible
--
--  Sin este archivo el almacén queda con los casilleros grandes de fábrica, los
--  artículos sin dimensiones y unos sesenta movimientos que fallan al
--  ejecutarlos. Con él, el sistema queda como el que se describe en el README.
--
--  Se ejecuta UNA vez, al final de la instalación. Es re-ejecutable: todo lo
--  que hace es idempotente.
-- =============================================================================

-- -----------------------------------------------------------------------------
--  A. Casilleros a medida en todos los racks (migración 23)
-- -----------------------------------------------------------------------------
-- Parte cada nivel en tantos huecos como haga falta para que uno guarde
-- aproximadamente un modelo completo, y reparte lo que quede sobrecargado.
do $$
declare v_res jsonb;
begin
  v_res := public.fn_ajustar_todo(null);
  raise notice 'Casilleros ajustados: %', v_res;
end;
$$;


-- -----------------------------------------------------------------------------
--  A bis. Cada artículo hereda del producto lo que el seed no le puso
-- -----------------------------------------------------------------------------
-- El público y el proveedor son del ARTÍCULO desde la migración 27, que los
-- rellenó desde el producto para los que ya existían. En una instalación limpia
-- esa migración no encuentra nada, así que se repite aquí.
--
-- El público importa antes de esto —decide en qué nivel puede ir cada caja, y
-- los seeds ya ubican stock—, por eso los seeds lo ponen ellos. Esto es la red
-- por si algún artículo se quedara sin él.
update public.inventory_items it
   set audience = case when pr.audience = 'NINO' then 'NINO' else 'ADULTO' end
  from public.products pr
 where pr.id = it.product_id
   and it.audience is distinct from (case when pr.audience = 'NINO' then 'NINO' else 'ADULTO' end);

update public.inventory_items it
   set supplier_id = pr.supplier_id
  from public.products pr
 where pr.id = it.product_id
   and it.supplier_id is null
   and pr.supplier_id is not null;


-- -----------------------------------------------------------------------------
--  B. Medidas de la caja en cada artículo (migración 28)
-- -----------------------------------------------------------------------------
with caja as (
  select 'NINO'::text as publico, public.fn_medidas_caja(1) as m, 0.600::numeric as kg
  union all
  select 'ADULTO', public.fn_medidas_caja(public.fn_niveles_infantiles() + 1), 0.900::numeric
)
update public.inventory_items it
   set length = coalesce(it.length, round(caja.m[1] * 100, 2)),
       width  = coalesce(it.width,  round(caja.m[2] * 100, 2)),
       height = coalesce(it.height, round(caja.m[3] * 100, 2)),
       weight = coalesce(it.weight, caja.kg),
       updated_at = now()
  from caja
 where caja.publico = it.audience
   and (it.length is null or it.width is null or it.height is null or it.weight is null);


-- -----------------------------------------------------------------------------
--  C. Movimientos que apuntan a un casillero imposible (migraciones 30 y 31)
-- -----------------------------------------------------------------------------
-- Entradas hacia un nivel que no admite ese público, o hacia un casillero de
-- otro modelo o sin sitio: se quedan en recepción y se ubican después.
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
         and pa.movement_id is distinct from m.id
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

-- Salidas desde un casillero donde ese artículo no está: se reapuntan a donde
-- sí tiene cajas suficientes.
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
             and pa.quantity >= sc.quantity
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
--  D. Marcar los casilleros de los movimientos que siguen vivos (migración 29)
-- -----------------------------------------------------------------------------
do $$
declare
  v_mov    public.inventory_movements;
  v_cuenta jsonb := '{}'::jsonb;
  v_res    text;
  v_fallos integer := 0;
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
    end;
  end loop;
  raise notice 'Casilleros marcados: %  (no se pudo con %)', v_cuenta, v_fallos;
end;
$$;


-- -----------------------------------------------------------------------------
--  E. Cómo quedó
-- -----------------------------------------------------------------------------
do $$
declare
  v_art integer; v_pares integer; v_cas integer; v_estantes integer; v_revision integer;
begin
  select count(*) into v_art from public.inventory_items where deleted_at is null;
  select coalesce(sum(quantity), 0) into v_pares from public.inventory;
  select count(*) into v_cas from public.positions;
  select coalesce(sum(quantity), 0) into v_estantes
    from public.position_assignments where status in ('OCUPADA', 'EN_PICKING');
  select count(*) into v_revision from public.v_revision_ubicaciones;

  raise notice '--------------------------------------------------';
  raise notice ' Articulos:        %', v_art;
  raise notice ' Pares en stock:   %', v_pares;
  raise notice ' Casilleros:       %', v_cas;
  raise notice ' Pares en estante: %', v_estantes;
  raise notice ' Incidencias:      %   <- deberia ser 0', v_revision;
  raise notice '--------------------------------------------------';
end;
$$;
