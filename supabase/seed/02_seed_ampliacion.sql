-- =============================================================================
--  SEED 02 — AMPLIACIÓN PARA DEMO ("necesitamos más productos para que se vea
--  más real" — pedido del jefe)
--
--  Ejecutar DESPUÉS de seed.sql. Agrega:
--    - Precio/costo de referencia a los 20 artículos originales del CSV real
--      (no traían esas columnas: el KPI "Valor total" mostraba S/ 0.00 siempre).
--    - 15 tallas adicionales de 10 productos YA existentes (muestra la relación
--      1 producto -> muchas tallas de forma explícita en la demo).
--    - 35 productos nuevos (3 marcas, 3 categorías y 3 proveedores nuevos, para
--      que los filtros de la Fase 5 tengan variedad real que filtrar).
--  Total después de este script: 70 artículos.
--
--  Todos los precios/costos son datos DE REFERENCIA inventados para la demo,
--  no vienen de ningún archivo real — se deja explícito para la sustentación.
--
--  Re-ejecutable: catálogos con ON CONFLICT, posiciones con generate_series +
--  ON CONFLICT, y el bloque de movimientos protegido igual que en seed.sql.
-- =============================================================================


-- =============================================================================
--  BLOQUE A — PRECIO DE REFERENCIA PARA LOS 20 ARTÍCULOS ORIGINALES
-- =============================================================================
update public.inventory_items ii
   set price = x.price, cost = x.cost
  from (values
    ('ZAP-001-42', 480, 330), ('ZAP-002-40', 250, 170), ('ZAP-003-41', 220, 150),
    ('ZAP-004-39', 230, 155), ('ZAP-005-43', 380, 260), ('ZAP-006-38', 260, 175),
    ('ZAP-007-44', 260, 175), ('ZAP-008-40', 300, 205), ('ZAP-009-42', 270, 185),
    ('ZAP-010-41', 240, 165), ('ZAP-011-39', 210, 140), ('ZAP-012-43', 290, 200),
    ('ZAP-013-40', 220, 150), ('ZAP-014-42', 250, 170), ('ZAP-015-44', 420, 290),
    ('ZAP-016-37', 200, 135), ('ZAP-017-42', 650, 450), ('ZAP-018-38', 260, 175),
    ('ZAP-019-41', 480, 330), ('ZAP-020-40', 240, 165)
  ) as x(sku, price, cost)
 where ii.sku = x.sku
   and ii.price is null;   -- no pisa un precio real si alguna vez se carga uno


-- =============================================================================
--  BLOQUE B — CATÁLOGOS NUEVOS
-- =============================================================================
insert into public.brands (slug, name) values
  ('saucony', 'Saucony'), ('skechers', 'Skechers'), ('salomon', 'Salomon')
on conflict (slug) do nothing;

insert into public.categories (slug, name) values
  ('basketball', 'Basketball'), ('training', 'Training'), ('trail', 'Trail Running')
on conflict (slug) do nothing;

insert into public.suppliers (slug, name) values
  ('deportes-total', 'Deportes Total'),
  ('calzado-sur', 'Calzado Sur'),
  ('global-sport-import', 'Global Sport Import')
on conflict (slug) do nothing;


-- =============================================================================
--  BLOQUE C — RACK DE AMPLIACIÓN POR ALMACÉN (mismo mapa, más capacidad)
-- =============================================================================
insert into public.racks (warehouse_id, code)
select w.id, 'RACK-07' from public.warehouses w
on conflict (warehouse_id, code) do nothing;

-- 25 posiciones por almacén (letra = inicial del código de almacén, igual que
-- en seed.sql): sobran de sobra para los 50 artículos nuevos repartidos en 3
-- almacenes.
insert into public.positions (rack_id, code, capacity_units)
select r.id, left(w.code, 1) || '-07-' || lpad(n::text, 2, '0'), 200
from public.warehouses w
join public.racks r on r.warehouse_id = w.id and r.code = 'RACK-07'
cross join generate_series(1, 25) as n
on conflict (rack_id, code) do nothing;


-- =============================================================================
--  BLOQUE D — 35 PRODUCTOS NUEVOS + SU PRIMERA VARIANTE (talla, precio, costo)
-- =============================================================================
insert into public.products (model_code, name, brand_id, category_id, supplier_id)
select x.model_code, x.name, b.id, c.id, s.id
from (values
  ('ZAP-021','Nike ZoomX Vaporfly 3',        'nike',         'running',    'nike-peru'),
  ('ZAP-022','Nike Free Run 5.0',            'nike',         'running',    'proveedor-andino'),
  ('ZAP-023','Nike Air Force 1',             'nike',         'casual',     'nike-peru'),
  ('ZAP-024','Nike Dunk Low',                'nike',         'casual',     'nike-peru'),
  ('ZAP-025','Nike LeBron 21',               'nike',         'basketball', 'sport-house'),
  ('ZAP-026','Nike Metcon 9',                'nike',         'training',   'proveedor-andino'),
  ('ZAP-027','Adidas Ultraboost 22',         'adidas',       'running',    'adidas-peru'),
  ('ZAP-028','Adidas Gazelle',               'adidas',       'casual',     'importadora-lima'),
  ('ZAP-029','Adidas Terrex Free Hiker',     'adidas',       'trail',      'adidas-peru'),
  ('ZAP-030','Adidas Dropset Trainer',       'adidas',       'training',   'importadora-lima'),
  ('ZAP-031','Puma Velocity Nitro 2',        'puma',         'running',    'sport-house'),
  ('ZAP-032','Puma RS-X',                    'puma',         'lifestyle',  'sport-house'),
  ('ZAP-033','Puma Cali Sport',              'puma',         'casual',     'proveedor-andino'),
  ('ZAP-034','Converse One Star',            'converse',     'casual',     'proveedor-andino'),
  ('ZAP-035','Converse Chuck 70',            'converse',     'lifestyle',  'proveedor-andino'),
  ('ZAP-036','New Balance FuelCell Rebel v3','new-balance',  'running',    'importadora-lima'),
  ('ZAP-037','New Balance 550',              'new-balance',  'casual',     'importadora-lima'),
  ('ZAP-038','Vans Sk8-Hi',                  'vans',         'casual',     'sport-house'),
  ('ZAP-039','Vans UltraRange EXO',          'vans',         'lifestyle',  'sport-house'),
  ('ZAP-040','Reebok Nano X3',               'reebok',       'training',   'deportes-total'),
  ('ZAP-041','Reebok Classic Leather',       'reebok',       'casual',     'importadora-lima'),
  ('ZAP-042','Asics Gel-Kayano 30',          'asics',        'running',    'sport-house'),
  ('ZAP-043','Asics Gel-Nimbus 25',          'asics',        'running',    'sport-house'),
  ('ZAP-044','Asics Gel-Lyte III',           'asics',        'lifestyle',  'sport-house'),
  ('ZAP-045','Fila Ray Tracer',              'fila',         'lifestyle',  'proveedor-andino'),
  ('ZAP-046','Fila Grant Hill 2',            'fila',         'basketball', 'proveedor-andino'),
  ('ZAP-047','Under Armour HOVR Machina 3',  'under-armour', 'running',    'importadora-lima'),
  ('ZAP-048','Under Armour Curry 11',        'under-armour', 'basketball', 'importadora-lima'),
  ('ZAP-049','Under Armour TriBase Reign 5', 'under-armour', 'training',   'importadora-lima'),
  ('ZAP-050','Saucony Endorphin Speed 3',    'saucony',      'running',    'global-sport-import'),
  ('ZAP-051','Saucony Jazz Original',        'saucony',      'casual',     'global-sport-import'),
  ('ZAP-052','Saucony Peregrine 13',         'saucony',      'trail',      'global-sport-import'),
  ('ZAP-053','Skechers GOrun Ride 11',       'skechers',     'running',    'calzado-sur'),
  ('ZAP-054','Skechers D''Lites',            'skechers',     'casual',     'calzado-sur'),
  ('ZAP-055','Salomon Speedcross 6',         'salomon',      'trail',      'global-sport-import')
) as x(model_code, name, brand_slug, cat_slug, sup_slug)
join public.brands     b on b.slug = x.brand_slug
join public.categories c on c.slug = x.cat_slug
join public.suppliers  s on s.slug = x.sup_slug
on conflict (model_code) do nothing;

insert into public.inventory_items (product_id, sku, size_label, price, cost)
select p.id, x.model_code || '-' || x.talla, x.talla, x.price, x.cost
from (values
  ('ZAP-021','42', 890, 620), ('ZAP-022','41', 380, 260), ('ZAP-023','43', 420, 290),
  ('ZAP-024','40', 460, 320), ('ZAP-025','44', 780, 540), ('ZAP-026','42', 520, 360),
  ('ZAP-027','41', 690, 470), ('ZAP-028','39', 320, 220), ('ZAP-029','43', 750, 520),
  ('ZAP-030','42', 410, 280), ('ZAP-031','40', 430, 300), ('ZAP-032','42', 380, 260),
  ('ZAP-033','38', 310, 210), ('ZAP-034','39', 280, 190), ('ZAP-035','41', 340, 230),
  ('ZAP-036','42', 560, 390), ('ZAP-037','43', 400, 270), ('ZAP-038','40', 300, 200),
  ('ZAP-039','41', 340, 230), ('ZAP-040','42', 480, 330), ('ZAP-041','40', 290, 200),
  ('ZAP-042','43', 650, 450), ('ZAP-043','41', 620, 430), ('ZAP-044','42', 350, 240),
  ('ZAP-045','39', 260, 175), ('ZAP-046','44', 340, 230), ('ZAP-047','42', 540, 375),
  ('ZAP-048','45', 720, 500), ('ZAP-049','41', 460, 320), ('ZAP-050','42', 680, 470),
  ('ZAP-051','40', 310, 210), ('ZAP-052','43', 480, 330), ('ZAP-053','41', 350, 240),
  ('ZAP-054','39', 280, 190), ('ZAP-055','42', 620, 430)
) as x(model_code, talla, price, cost)
join public.products p on p.model_code = x.model_code
on conflict (sku) do nothing;


-- =============================================================================
--  BLOQUE E — 15 TALLAS ADICIONALES DE 10 PRODUCTOS YA EXISTENTES
--  El precio/costo se hereda del hermano ya cargado (Bloque A de este script
--  o de seed.sql): mismo modelo, misma talla nueva, mismo precio de lista.
-- =============================================================================
insert into public.inventory_items (product_id, sku, size_label, price, cost)
select p.id, p.model_code || '-' || x.talla, x.talla, ref.price, ref.cost
from (values
  ('ZAP-001','40'), ('ZAP-001','44'), ('ZAP-002','38'), ('ZAP-003','43'),
  ('ZAP-004','41'), ('ZAP-005','40'), ('ZAP-005','45'), ('ZAP-007','41'),
  ('ZAP-008','38'), ('ZAP-009','44'), ('ZAP-011','41'), ('ZAP-013','43'),
  ('ZAP-014','44'), ('ZAP-016','40'), ('ZAP-019','43')
) as x(model_code, talla)
join public.products p on p.model_code = x.model_code
join public.inventory_items ref on ref.product_id = p.id and ref.price is not null
on conflict (sku) do nothing;


-- =============================================================================
--  BLOQUE F — LOGÍSTICA DE LOS 50 ARTÍCULOS NUEVOS
--  (stock, ubicación y un movimiento histórico por artículo, igual que en
--  seed.sql). Se arma en una tabla temporal para no repetir la lista tres veces.
-- =============================================================================
do $$
declare
  v_jefe_id uuid;
begin
  if exists (select 1 from public.inventory_movements where reason like 'Carga adicional (demo ampliada)%') then
    raise notice 'La ampliación ya se había cargado, no se duplica.';
    return;
  end if;

  select id into v_jefe_id from public.profiles where role = 'JEFE' order by created_at limit 1;
  if v_jefe_id is null then
    raise exception 'No hay ningún perfil con role = JEFE todavía.';
  end if;

  create temporary table tmp_expansion (
    sku text, wh_code text, stock int, min_stock int,
    tipo_mov text, qty_mov int, estado_mov text
  ) on commit drop;

  insert into tmp_expansion values
    ('ZAP-001-40','ALM-A', 28, 6,'ENTRADA',10,'APROBADO'), ('ZAP-001-44','ALM-A', 34, 6,'SALIDA', 6,'PENDIENTE'),
    ('ZAP-002-38','ALM-A', 19, 5,'ENTRADA',12,'PENDIENTE'), ('ZAP-003-43','BOD-B', 22, 5,'SALIDA', 4,'APROBADO'),
    ('ZAP-004-41','BOD-B', 15, 5,'ENTRADA', 8,'PENDIENTE'), ('ZAP-005-40','ALM-A', 26, 6,'ENTRADA',15,'APROBADO'),
    ('ZAP-005-45','ALM-A',  9, 6,'ENTRADA', 6,'PENDIENTE'), ('ZAP-007-41','ALM-A', 31, 6,'SALIDA', 5,'APROBADO'),
    ('ZAP-008-38','BOD-B', 18, 5,'SALIDA', 3,'RECHAZADO'), ('ZAP-009-44','ALM-A', 21, 5,'ENTRADA',10,'PENDIENTE'),
    ('ZAP-011-41','ALM-A', 14, 4,'ENTRADA', 7,'APROBADO'), ('ZAP-013-43','ALM-A', 24, 6,'SALIDA', 5,'PENDIENTE'),
    ('ZAP-014-44','BOD-C', 12, 4,'SALIDA', 3,'APROBADO'),  ('ZAP-016-40','BOD-B', 17, 5,'ENTRADA', 9,'PENDIENTE'),
    ('ZAP-019-43','ALM-A', 20, 8,'ENTRADA',12,'APROBADO'),
    ('ZAP-021-42','ALM-A', 40, 8,'ENTRADA',18,'APROBADO'), ('ZAP-022-41','BOD-B', 33, 6,'SALIDA', 7,'PENDIENTE'),
    ('ZAP-023-43','ALM-A', 55, 10,'ENTRADA',25,'APROBADO'),('ZAP-024-40','ALM-A', 47, 8,'SALIDA', 9,'PENDIENTE'),
    ('ZAP-025-44','BOD-C', 16, 5,'ENTRADA',10,'PENDIENTE'), ('ZAP-026-42','BOD-B', 29, 6,'ENTRADA',14,'APROBADO'),
    ('ZAP-027-41','ALM-A', 25, 6,'SALIDA', 6,'APROBADO'),  ('ZAP-028-39','BOD-B', 38, 7,'ENTRADA',16,'PENDIENTE'),
    ('ZAP-029-43','BOD-C', 13, 4,'ENTRADA', 8,'PENDIENTE'), ('ZAP-030-42','BOD-B', 22, 5,'SALIDA', 4,'RECHAZADO'),
    ('ZAP-031-40','ALM-A', 30, 6,'ENTRADA',12,'APROBADO'), ('ZAP-032-42','BOD-C', 27, 6,'SALIDA', 5,'PENDIENTE'),
    ('ZAP-033-38','BOD-B', 19, 5,'ENTRADA', 9,'PENDIENTE'), ('ZAP-034-39','ALM-A', 44, 7,'ENTRADA',20,'APROBADO'),
    ('ZAP-035-41','BOD-C', 21, 5,'SALIDA', 4,'PENDIENTE'), ('ZAP-036-42','ALM-A', 17, 5,'ENTRADA', 8,'APROBADO'),
    ('ZAP-037-43','BOD-B', 23, 5,'SALIDA', 5,'PENDIENTE'), ('ZAP-038-40','ALM-A', 36, 6,'ENTRADA',15,'APROBADO'),
    ('ZAP-039-41','BOD-C', 14, 4,'SALIDA', 3,'RECHAZADO'), ('ZAP-040-42','BOD-B', 20, 5,'ENTRADA',10,'PENDIENTE'),
    ('ZAP-041-40','ALM-A', 32, 6,'SALIDA', 6,'APROBADO'),  ('ZAP-042-43','ALM-A', 18, 5,'ENTRADA', 9,'PENDIENTE'),
    ('ZAP-043-41','BOD-C', 15, 5,'SALIDA', 4,'APROBADO'),  ('ZAP-044-42','BOD-B', 26, 6,'ENTRADA',12,'PENDIENTE'),
    ('ZAP-045-39','ALM-A', 41, 7,'ENTRADA',18,'APROBADO'), ('ZAP-046-44','BOD-C', 11, 4,'SALIDA', 2,'PENDIENTE'),
    ('ZAP-047-42','ALM-A', 24, 6,'ENTRADA',11,'APROBADO'), ('ZAP-048-45','BOD-B',  7, 6,'ENTRADA', 5,'PENDIENTE'),
    ('ZAP-049-41','BOD-C', 19, 5,'SALIDA', 4,'RECHAZADO'), ('ZAP-050-42','ALM-A', 22, 6,'ENTRADA',10,'APROBADO'),
    ('ZAP-051-40','BOD-B', 35, 6,'SALIDA', 7,'PENDIENTE'), ('ZAP-052-43','BOD-C', 13, 5,'ENTRADA', 8,'PENDIENTE'),
    ('ZAP-053-41','ALM-A', 28, 6,'ENTRADA',13,'APROBADO'), ('ZAP-054-39','BOD-B', 39, 7,'SALIDA', 8,'PENDIENTE'),
    ('ZAP-055-42','BOD-C', 16, 5,'ENTRADA', 9,'APROBADO');

  -- Stock
  insert into public.inventory (item_id, warehouse_id, quantity, min_stock)
  select it.id, w.id, t.stock, t.min_stock
    from tmp_expansion t
    join public.inventory_items it on it.sku = t.sku
    join public.warehouses      w  on w.code = t.wh_code
  on conflict (item_id, warehouse_id) do nothing;

  -- Ubicación: posición secuencial dentro del RACK-07 del almacén que le tocó.
  insert into public.position_assignments (position_id, item_id, quantity, status)
  select pos.id, it.id, t.stock, 'OCUPADA'
    from (
      select t.*, row_number() over (partition by t.wh_code order by t.sku) as n
        from tmp_expansion t
    ) t
    join public.inventory_items it  on it.sku = t.sku
    join public.warehouses      w   on w.code = t.wh_code
    join public.racks           r   on r.warehouse_id = w.id and r.code = 'RACK-07'
    join public.positions       pos on pos.rack_id = r.id
                                    and pos.code = left(t.wh_code, 1) || '-07-' || lpad(t.n::text, 2, '0')
  -- El indice cambio en la migracion 20: antes era una asignacion viva por
  -- casillero (position_id) y ahora es una por casillero y talla
  -- (position_id, item_id), porque un casillero guarda un modelo con varias
  -- tallas. Con la clausula vieja el seed falla al no encontrar indice.
  on conflict (position_id, item_id) where status in ('RESERVADA', 'OCUPADA', 'EN_PICKING') do nothing;

  -- Movimiento histórico. Fechas RELATIVAS a hoy (current_date - n) para que
  -- la demo se vea "reciente" sin importar qué día se corra este script.
  insert into public.inventory_movements (
    item_id, inventory_id, position_id, movement_type, quantity, reason, status,
    approved_by, created_at, approved_at
  )
  select
    it.id, inv.id, pa.position_id, t.tipo_mov, t.qty_mov,
    'Carga adicional (demo ampliada) — ' || lower(t.tipo_mov),
    t.estado_mov,
    case when t.estado_mov in ('APROBADO', 'RECHAZADO') then v_jefe_id end,
    -- row_number() devuelve bigint y Postgres no tiene el operador `date - bigint`
    -- (solo `date - integer`), de ahí el ::int. `date + time` da timestamp, que
    -- se convierte implícitamente a timestamptz al insertarse en la columna.
    (current_date - (row_number() over (order by t.sku) % 7)::int) + time '09:00',
    case when t.estado_mov in ('APROBADO', 'RECHAZADO')
         then (current_date - (row_number() over (order by t.sku) % 7)::int) + time '11:00'
    end
  from tmp_expansion t
  join public.inventory_items      it  on it.sku = t.sku
  join public.inventory            inv on inv.item_id = it.id
  join public.position_assignments pa  on pa.item_id = it.id and pa.status = 'OCUPADA';

  -- Igual que en seed.sql: lo APROBADO compromete stock (reserva/espera) sin
  -- tocar el saldo físico todavía.
  update public.inventory inv
     set qty_incoming = inv.qty_incoming + t.qty_mov
    from tmp_expansion t
    join public.inventory_items it on it.sku = t.sku
   where inv.item_id = it.id and t.tipo_mov = 'ENTRADA' and t.estado_mov = 'APROBADO';

  update public.inventory inv
     set qty_reserved = inv.qty_reserved + t.qty_mov
    from tmp_expansion t
    join public.inventory_items it on it.sku = t.sku
   where inv.item_id = it.id and t.tipo_mov = 'SALIDA' and t.estado_mov = 'APROBADO';

  raise notice 'Ampliación aplicada: 50 artículos nuevos con stock, ubicación y movimiento.';
end;
$$;


-- =============================================================================
--  VERIFICACIÓN
-- =============================================================================
select
  (select count(*) from public.products)           as productos,
  (select count(*) from public.inventory_items)     as articulos,
  (select count(*) from public.inventory)            as registros_stock,
  (select count(*) from public.inventory_movements) as movimientos,
  (select count(*) from public.inventory_items where price is null) as sin_precio;
-- Esperado: 55 productos / 70 artículos / 70 stock / 70 movimientos / 0 sin precio.
