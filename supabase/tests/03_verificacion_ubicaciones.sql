-- =============================================================================
--  VERIFICACIÓN DE UBICACIONES — ¿cada par está donde el sistema dice?
--
--  Solo lee: no modifica nada. Todo sale en UNA tabla porque el SQL Editor de
--  Supabase muestra únicamente el resultado de la última consulta.
--
--  estado:  OK      = cuadra
--           REVISAR = hay algo que corregir
--           INFO    = dato de contexto, no es un error
--
--  Requiere las migraciones 01-21.
-- =============================================================================
with
vivas as (          -- asignaciones que ocupan sitio en un casillero
  select pa.id, pa.item_id, pa.quantity, pa.status, pa.assigned_at, pa.position_id,
         pos.code as casillero, pos.level, pos.capacity_units,
         r.code as rack, r.warehouse_id, w.code as almacen,
         it.sku, it.product_id, pr.audience
    from public.position_assignments pa
    join public.positions       pos on pos.id = pa.position_id
    join public.racks           r   on r.id   = pos.rack_id
    join public.warehouses      w   on w.id   = r.warehouse_id
    join public.inventory_items it  on it.id  = pa.item_id
    join public.products        pr  on pr.id  = it.product_id
   where pa.status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
),
fisicas as (        -- cajas presentes; lo RESERVADA es sitio apartado para algo que no llegó
  select * from vivas where status in ('OCUPADA', 'EN_PICKING')
),
estantes as (
  select item_id, warehouse_id, sum(quantity) as en_estantes, min(assigned_at) as desde
    from fisicas group by item_id, warehouse_id
),
cruce as (
  select coalesce(inv.item_id, e.item_id)           as item_id,
         coalesce(inv.warehouse_id, e.warehouse_id) as warehouse_id,
         inv.id                                     as inventory_id,
         coalesce(inv.quantity, 0)                  as stock,
         coalesce(e.en_estantes, 0)                 as en_estantes,
         e.desde
    from public.inventory inv
    full join estantes e on e.item_id = inv.item_id and e.warehouse_id = inv.warehouse_id
),
por_almacen as (
  select w.code                                    as almacen,
         sum(c.stock)                              as stock,
         sum(c.en_estantes)                        as en_estantes,
         sum(greatest(c.stock - c.en_estantes, 0)) as sin_ubicar,
         sum(greatest(c.en_estantes - c.stock, 0)) as sobran
    from cruce c
    join public.warehouses w on w.id = c.warehouse_id
   group by w.code
),
ocupacion as (
  select pos.id, pos.capacity_units, coalesce(sum(v.quantity), 0) as hay
    from public.positions pos
    left join vivas v on v.position_id = pos.id
   group by pos.id, pos.capacity_units
),
por_modelo as (
  select pr.id, (pr.audience = 'NINO') as infantil, sum(inv.quantity) as cajas
    from public.products        pr
    join public.inventory_items it  on it.product_id = pr.id
    join public.inventory       inv on inv.item_id   = it.id
   group by pr.id, pr.audience
  having sum(inv.quantity) > 0
),
fantasmas as (
  select c.*, it.sku, w.code as almacen,
         (select string_agg(f.rack || ' ' || f.casillero || ': ' || f.quantity, ', ' order by f.rack, f.casillero)
            from fisicas f where f.item_id = c.item_id and f.warehouse_id = c.warehouse_id) as donde,
         -- Cuánto bajó el stock por movimientos ejecutados DESPUÉS de que esas
         -- cajas se ubicaran. Si alcanza para explicar el sobrante, el stock
         -- dice la verdad: salieron pares y el estante no se descontó (el bug
         -- que la migración 20 corrigió).
         (select coalesce(sum(m.quantity), 0)
            from public.inventory_movements m
           where m.inventory_id = c.inventory_id
             and m.executed_at is not null
             and m.executed_at > c.desde
             and (m.movement_type = 'SALIDA' or (m.movement_type = 'AJUSTE' and m.direction = -1))) as bajas
    from cruce c
    join public.inventory_items it on it.id = c.item_id
    join public.warehouses      w  on w.id  = c.warehouse_id
   where c.en_estantes > c.stock
),
geometria as (
  select r.id, w.code || ' · ' || r.code as rack,
         greatest(r.grid_ancho, r.grid_alto)::numeric as frente,
         least(r.grid_ancho, r.grid_alto)::numeric    as fondo,
         r.niveles
    from public.racks r
    join public.warehouses w on w.id = r.warehouse_id
),
niveles as (
  select g.rack, g.frente, g.fondo, n.nivel,
         (select count(*) from public.positions p where p.rack_id = g.id and p.level = n.nivel)::integer as hoy,
         public.fn_casilleros_para(g.frente, g.fondo, n.nivel) as sugerido
    from geometria g
    cross join lateral generate_series(1, g.niveles) as n(nivel)
)
-- En la sección 2 el estado sale del número: 0 es OK, cualquier otro REVISAR.
select orden, seccion, chequeo, resultado, esperado,
       coalesce(estado, case when resultado = '0' then 'OK' else 'REVISAR' end) as estado
  from (

  -- 1. PARES: lo que dice el stock contra lo que hay en los estantes.
  select 10 as orden, '1. Pares' as seccion, 'Stock vs estantes · ' || almacen as chequeo,
         format('stock %s · en estantes %s · sin ubicar %s · sobran %s', stock, en_estantes, sin_ubicar, sobran) as resultado,
         'en estantes = stock' as esperado,
         case when sin_ubicar = 0 and sobran = 0 then 'OK' else 'REVISAR' end as estado
    from por_almacen
  union all
  select 11, '1. Pares', 'Stock vs estantes · TOTAL',
         format('stock %s · en estantes %s · sin ubicar %s · sobran %s',
                sum(stock), sum(en_estantes), sum(sin_ubicar), sum(sobran)),
         'en estantes = stock',
         case when sum(sin_ubicar) = 0 and sum(sobran) = 0 then 'OK' else 'REVISAR' end
    from por_almacen
  union all
  select 12, '1. Pares', 'Capacidad total',
         format('%s cajas en %s casilleros · ocupación %s%%',
                sum(capacity_units), count(*),
                case when sum(capacity_units) > 0 then round(100.0 * sum(hay) / sum(capacity_units), 1) else 0 end),
         '—', 'INFO'
    from ocupacion

  -- 2. INTEGRIDAD: cada uno debe dar 0.
  union all
  select 20, '2. Integridad', 'Casilleros con más de un modelo',
         (select count(*) from (select position_id from vivas group by position_id
                                 having count(distinct product_id) > 1) x)::text, '0', null
  union all
  select 21, '2. Integridad', 'Casilleros con más cajas de las que caben',
         (select count(*) from ocupacion where hay > capacity_units)::text, '0', null
  union all
  select 22, '2. Integridad', 'Cajas en un nivel que no es el de su público',
         (select count(*) from vivas
           where (audience = 'NINO'   and level >  public.fn_niveles_infantiles())
              or (audience = 'ADULTO' and level <= public.fn_niveles_infantiles()))::text, '0', null
  union all
  select 23, '2. Integridad', 'Ubicaciones vivas con 0 cajas',
         (select count(*) from vivas where quantity = 0)::text, '0', null
  union all
  select 24, '2. Integridad', 'Misma talla dos veces en un casillero',
         (select count(*) from (select position_id, item_id from vivas group by position_id, item_id
                                 having count(*) > 1) x)::text, '0', null
  union all
  select 25, '2. Integridad', 'Cajas en un almacén donde el artículo no tiene stock',
         (select count(*) from cruce where stock = 0 and en_estantes > 0)::text, '0', null
  union all
  select 26, '2. Integridad', 'Racks sin forma de estantería',
         (select count(*) from public.racks
           where least(grid_ancho, grid_alto) > 2
              or greatest(grid_ancho, grid_alto) < 2 * least(grid_ancho, grid_alto))::text, '0', null
  union all
  select 27, '2. Integridad', 'Casilleros donde no entra ni una caja',
         (select count(*) from public.positions where capacity_units = 0)::text, '0', null

  -- 3. TAMAÑO OBJETIVO DE UN CASILLERO: lo que ocupa un modelo típico.
  union all
  select 30, '3. Casilleros', 'Tamaño objetivo · niveles infantiles',
         format('%s cajas por casillero (mediana real: %s, de %s modelos infantiles con stock; se acota entre 20 y 80)',
                public.fn_cajas_por_modelo(true),
                (select round(percentile_cont(0.5) within group (order by cajas)) from por_modelo where infantil),
                (select count(*) from por_modelo where infantil)),
         '—', 'INFO'
  union all
  select 31, '3. Casilleros', 'Tamaño objetivo · niveles de adulto',
         format('%s cajas por casillero (mediana real: %s, de %s modelos de adulto con stock; se acota entre 20 y 80)',
                public.fn_cajas_por_modelo(false),
                (select round(percentile_cont(0.5) within group (order by cajas)) from por_modelo where not infantil),
                (select count(*) from por_modelo where not infantil)),
         '—', 'INFO'

  -- 4. CASILLEROS DE CADA RACK: los de hoy contra los que propone la regla.
  --    INFO si difieren: se aplican con "Aplicar niveles y casilleros".
  union all
  select 40, '4. Casilleros por rack', rack,
         string_agg(
           format('n%s: %s', nivel,
             case when hoy = 0 then 'sin casilleros'
                  else format('%s de %s cm (%s c/u)', hoy, round(frente / hoy * 100),
                              public.fn_cajas_en_slot(frente / hoy, fondo, nivel)) end
             || case when hoy <> sugerido
                     then format(' → %s de %s cm (%s c/u)', sugerido, round(frente / sugerido * 100),
                                 public.fn_cajas_en_slot(frente / sugerido, fondo, nivel))
                     else ' (ya a medida)' end),
           ' · ' order by nivel),
         'hoy → sugerido',
         case when bool_and(hoy = sugerido) then 'OK' else 'INFO' end
    from niveles
   group by rack

  -- 5. CAJAS FANTASMA: con la pista de en qué confiar.
  union all
  select 50, '5. Cajas fantasma', sku || ' en ' || almacen,
         format('en estantes %s (%s) · stock %s · sobran %s · el stock bajó %s por movimientos ejecutados después de ubicarlas',
                en_estantes, donde, stock, en_estantes - stock, bajas)
         || case when bajas >= en_estantes - stock
                 then ' → el kardex explica la diferencia: miente el ESTANTE. Usa "Liberar sobrante".'
                 else ' → ningún movimiento lo explica: cuenta las cajas en el estante antes de elegir.' end,
         'decidir', 'REVISAR'
    from fantasmas

) chequeos
 order by orden, chequeo;
