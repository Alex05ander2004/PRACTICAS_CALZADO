-- =============================================================================
--  SEED 03 — LÍNEA INFANTIL (para demostrar la regla nivel 1 = niños)
--
--  Ejecutar DESPUÉS de migrations/04_publico_por_edad.sql. Agrega 10 productos
--  infantiles REALES Y DISTINTOS de los de adulto (no son tallas chicas de un
--  modelo de adulto — así funciona en la práctica: las marcas sacan la línea
--  infantil como producto aparte, con su propio nombre comercial).
--
--  Se ubican en un rack nuevo por almacén (RACK-08, nivel 1) para que el
--  trigger trg_assign_publico_nivel los acepte. Intentar ubicarlos en
--  RACK-07 (nivel 2, donde vive el stock de adulto) fallaría a propósito —
--  es exactamente lo que se puede demostrar en la sustentación.
--
--  Re-ejecutable, mismo patrón que seed.sql y 02_seed_ampliacion.sql.
-- =============================================================================


-- =============================================================================
--  BLOQUE A — RACK INFANTIL POR ALMACÉN (nivel 1: inferior)
-- =============================================================================
-- La geometria es obligatoria desde la migracion 09: alli se calculo para los
-- racks que ya existian y despues se puso NOT NULL sin default, asi que en una
-- instalacion limpia hay que darla al insertar. Se usa la misma formula de esa
-- migracion -dos columnas de racks de 14x2 con pasillo en medio- contando los
-- que ya haya en el almacen, para que ninguno pise a otro y el trigger
-- anti-solape no rechace el seed.
insert into public.racks (warehouse_id, code, grid_x, grid_y, grid_ancho, grid_alto)
select w.id, 'RACK-08',
       (3 + ((select count(*) from public.racks r where r.warehouse_id = w.id) % 2) * 18)::integer,
       (3 + ((select count(*) from public.racks r where r.warehouse_id = w.id) / 2) * 6)::integer,
       14, 2
from public.warehouses w
on conflict (warehouse_id, code) do nothing;

insert into public.positions (rack_id, code, capacity_units, level)
select r.id, left(w.code, 1) || '-08-' || lpad(n::text, 2, '0'), 150, 1
from public.warehouses w
join public.racks r on r.warehouse_id = w.id and r.code = 'RACK-08'
cross join generate_series(1, 10) as n
on conflict (rack_id, code) do nothing;


-- =============================================================================
--  BLOQUE B — 10 PRODUCTOS INFANTILES (modelo propio, no talla chica de adulto)
-- =============================================================================
insert into public.products (model_code, name, audience, brand_id, category_id, supplier_id)
select x.model_code, x.name, 'NINO', b.id, c.id, s.id
from (values
  ('ZAP-056','Nike Air Max 90 GS',        'nike',       'running', 'nike-peru'),
  ('ZAP-057','Nike Revolution 7 TD',      'nike',       'running', 'proveedor-andino'),
  ('ZAP-058','Adidas Superstar Kids',     'adidas',     'casual',  'adidas-peru'),
  ('ZAP-059','Adidas Runfalcon Kids',     'adidas',     'running', 'importadora-lima'),
  ('ZAP-060','Puma Smash Kids',           'puma',       'casual',  'sport-house'),
  ('ZAP-061','Converse Chuck Taylor Kids','converse',   'casual',  'proveedor-andino'),
  ('ZAP-062','New Balance 574 Kids',      'new-balance','lifestyle','importadora-lima'),
  ('ZAP-063','Vans Old Skool Kids',       'vans',       'casual',  'sport-house'),
  ('ZAP-064','Skechers Light-Up Kids',    'skechers',   'casual',  'calzado-sur'),
  ('ZAP-065','Reebok Classic Kids',       'reebok',     'casual',  'importadora-lima')
) as x(model_code, name, brand_slug, cat_slug, sup_slug)
join public.brands     b on b.slug = x.brand_slug
join public.categories c on c.slug = x.cat_slug
join public.suppliers  s on s.slug = x.sup_slug
on conflict (model_code) do nothing;

-- audience va tambien en el articulo, no solo en el producto: desde la
-- migracion 27 es el del ARTICULO el que decide el tamano de la caja y en que
-- nivel del rack puede ir. Sin esto se quedaria con el default 'ADULTO' y el
-- trigger rechazaria ubicarlo en el nivel 1.
insert into public.inventory_items (product_id, sku, size_label, price, cost, audience)
select p.id, x.model_code || '-' || x.talla, x.talla, x.price, x.cost, 'NINO'
from (values
  ('ZAP-056','33', 220, 150), ('ZAP-057','29', 180, 120), ('ZAP-058','31', 190, 130),
  ('ZAP-059','30', 150, 100), ('ZAP-060','32', 140,  95), ('ZAP-061','28', 130,  85),
  ('ZAP-062','33', 210, 145), ('ZAP-063','30', 150, 100), ('ZAP-064','29', 160, 105),
  ('ZAP-065','31', 140,  95)
) as x(model_code, talla, price, cost)
join public.products p on p.model_code = x.model_code
on conflict (sku) do nothing;


-- =============================================================================
--  BLOQUE C — STOCK, UBICACIÓN (nivel 1) Y MOVIMIENTO HISTÓRICO
-- =============================================================================
do $$
declare
  v_jefe_id uuid;
begin
  if exists (select 1 from public.inventory_movements where reason like 'Carga inicial - linea infantil%') then
    raise notice 'La línea infantil ya se había cargado, no se duplica.';
    return;
  end if;

  select id into v_jefe_id from public.profiles where role = 'JEFE' order by created_at limit 1;
  if v_jefe_id is null then
    raise exception 'No hay ningún perfil con role = JEFE todavía.';
  end if;

  create temporary table tmp_infantil (
    sku text, wh_code text, stock int, min_stock int,
    tipo_mov text, qty_mov int, estado_mov text
  ) on commit drop;

  insert into tmp_infantil values
    ('ZAP-056-33','ALM-A', 24, 6, 'ENTRADA', 12, 'APROBADO'),
    ('ZAP-057-29','ALM-A', 18, 5, 'ENTRADA',  8, 'PENDIENTE'),
    ('ZAP-058-31','BOD-B', 30, 6, 'SALIDA',   6, 'APROBADO'),
    ('ZAP-059-30','BOD-B', 15, 4, 'ENTRADA',  9, 'PENDIENTE'),
    ('ZAP-060-32','BOD-C', 20, 5, 'ENTRADA', 10, 'APROBADO'),
    ('ZAP-061-28','ALM-A', 12, 4, 'SALIDA',   3, 'RECHAZADO'),
    ('ZAP-062-33','BOD-B', 22, 5, 'ENTRADA', 11, 'PENDIENTE'),
    ('ZAP-063-30','BOD-C', 17, 5, 'SALIDA',   4, 'APROBADO'),
    ('ZAP-064-29','ALM-A', 26, 6, 'ENTRADA', 14, 'PENDIENTE'),
    ('ZAP-065-31','BOD-C', 14, 4, 'SALIDA',   3, 'PENDIENTE');

  -- Stock
  insert into public.inventory (item_id, warehouse_id, quantity, min_stock)
  select it.id, w.id, t.stock, t.min_stock
    from tmp_infantil t
    join public.inventory_items it on it.sku = t.sku
    join public.warehouses      w  on w.code = t.wh_code
  on conflict (item_id, warehouse_id) do nothing;

  -- Ubicación en el rack infantil (nivel 1) de su almacén. Si esto se
  -- intentara contra una posición de nivel 2, el trigger de la migración 04
  -- lo rechazaría — es la demostración en vivo de la regla.
  insert into public.position_assignments (position_id, item_id, quantity, status)
  select pos.id, it.id, t.stock, 'OCUPADA'
    from (
      select t.*, row_number() over (partition by t.wh_code order by t.sku) as n
        from tmp_infantil t
    ) t
    join public.inventory_items it  on it.sku = t.sku
    join public.warehouses      w   on w.code = t.wh_code
    join public.racks           r   on r.warehouse_id = w.id and r.code = 'RACK-08'
    join public.positions       pos on pos.rack_id = r.id
                                    and pos.code = left(t.wh_code, 1) || '-08-' || lpad(t.n::text, 2, '0')
  -- El indice cambio en la migracion 20: antes era una asignacion viva por
  -- casillero (position_id) y ahora es una por casillero y talla
  -- (position_id, item_id), porque un casillero guarda un modelo con varias
  -- tallas. Con la clausula vieja el seed falla al no encontrar indice.
  on conflict (position_id, item_id) where status in ('RESERVADA', 'OCUPADA', 'EN_PICKING') do nothing;

  -- Movimiento histórico, fechas relativas a hoy (igual que en 02_seed_ampliacion.sql).
  insert into public.inventory_movements (
    item_id, inventory_id, position_id, movement_type, quantity, reason, status,
    approved_by, created_at, approved_at
  )
  select
    it.id, inv.id, pa.position_id, t.tipo_mov, t.qty_mov,
    'Carga inicial - linea infantil (' || lower(t.tipo_mov) || ')',
    t.estado_mov,
    case when t.estado_mov in ('APROBADO', 'RECHAZADO') then v_jefe_id end,
    (current_date - (row_number() over (order by t.sku) % 5)::int) + time '09:30',
    case when t.estado_mov in ('APROBADO', 'RECHAZADO')
         then (current_date - (row_number() over (order by t.sku) % 5)::int) + time '11:30'
    end
  from tmp_infantil t
  join public.inventory_items      it  on it.sku = t.sku
  join public.inventory            inv on inv.item_id = it.id
  join public.position_assignments pa  on pa.item_id = it.id and pa.status = 'OCUPADA';

  update public.inventory inv
     set qty_incoming = inv.qty_incoming + t.qty_mov
    from tmp_infantil t
    join public.inventory_items it on it.sku = t.sku
   where inv.item_id = it.id and t.tipo_mov = 'ENTRADA' and t.estado_mov = 'APROBADO';

  update public.inventory inv
     set qty_reserved = inv.qty_reserved + t.qty_mov
    from tmp_infantil t
    join public.inventory_items it on it.sku = t.sku
   where inv.item_id = it.id and t.tipo_mov = 'SALIDA' and t.estado_mov = 'APROBADO';

  raise notice 'Línea infantil cargada: 10 artículos en nivel 1 de RACK-08.';
end;
$$;


-- =============================================================================
--  VERIFICACIÓN
-- =============================================================================
select
  (select count(*) from public.products where audience = 'NINO')       as productos_infantiles,
  (select count(*) from public.inventory_items ii
     join public.products p on p.id = ii.product_id where p.audience='NINO') as articulos_infantiles,
  (select count(*) from public.position_assignments pa
     join public.positions pos on pos.id = pa.position_id
    where pos.level = 1 and pa.status = 'OCUPADA')                      as ocupacion_nivel_1,
  (select count(*) from public.positions where level is null)           as posiciones_sin_nivel;
-- Esperado: 10 / 10 / 10 / 0

-- Prueba en vivo de la regla (debe FALLAR con el mensaje del trigger):
-- insert into public.position_assignments (position_id, item_id, quantity, status)
-- select pos.id, ii.id, 5, 'OCUPADA'
--   from public.positions pos, public.inventory_items ii
--  where pos.level = 2 and ii.sku = 'ZAP-056-33' limit 1;
