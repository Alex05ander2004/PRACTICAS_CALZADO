-- =============================================================================
--  SEED — datos reales de data.csv (20 filas) + limpieza de datos de prueba
--
--  Ejecutar UNA vez en el SQL Editor, después de correr schema-completo.sql y
--  de haber promovido tu primer usuario real a JEFE.
--
--  Es re-ejecutable: la limpieza usa los IDs fijos de los tests, los catálogos
--  usan ON CONFLICT DO NOTHING, y la carga de movimientos/reservas está
--  protegida para no duplicarse en una segunda corrida.
--
--  Decisiones de normalización (detalle completo en supabase/DISENO.md):
--    - tipo_movimiento: INBOUND->ENTRADA, OUTBOUND->SALIDA
--    - fecha_movimiento: se asume DD/MM/YYYY (convención peruana), año de
--      2 dígitos -> 20XX. Las filas en formato ISO del propio CSV confirman
--      la lectura (la secuencia de fechas es consecutiva hacia atrás).
--    - rack/posición: normalizados al formato canónico RACK-NN / L-NN-NN
--    - marca/categoría/proveedor: normalizados a catálogos con slug
--    - "stock" del CSV: se toma como el saldo FÍSICO actual (inventory.quantity).
--      Un movimiento 'Aprobado' del CSV se modela como APROBADO PERO NO
--      EJECUTADO todavía (approved_at seteado, executed_at NULL): reserva o
--      espera stock (qty_reserved / qty_incoming) sin tocar el saldo físico.
--      Esto evita cualquier inconsistencia aritmética (ver caso ZAP-019 más
--      abajo, donde el saldo actual es MENOR que la cantidad del ingreso
--      aprobado) y de paso deja movimientos reales en la cola de ejecución
--      para probar el flujo completo en la demo.
--    - capacity_units de las posiciones: el CSV no trae este dato; se asume
--      200 para todas (ninguna fila supera 120 unidades).
-- =============================================================================


-- =============================================================================
--  BLOQUE A — LIMPIEZA DE DATOS DE PRUEBA
-- =============================================================================
-- IDs fijos usados en tests/01_smoke_test.sql y tests/02_rls_test.sql. No toca
-- tu usuario real: solo borra los perfiles falsos (Ana Jefa, Luis Supervisor,
-- Rosa Operaria, Carlos Auditor) y sus datos asociados.
do $$
declare
  id_jefe_test     uuid := '11111111-1111-1111-1111-111111111111';
  id_super_test    uuid := '22222222-2222-2222-2222-222222222222';
  id_operario_test uuid := '33333333-3333-3333-3333-333333333333';
  id_auditor_test  uuid := '44444444-4444-4444-4444-444444444444';
  id_item_test     uuid := 'cccccccc-0000-0000-0000-000000000002';
  id_producto_test uuid := 'cccccccc-0000-0000-0000-000000000001';
  id_inv_test      uuid := 'cccccccc-0000-0000-0000-000000000003';
  id_pos_test      uuid := 'aaaaaaaa-0000-0000-0000-000000000003';
  id_rack_test     uuid := 'aaaaaaaa-0000-0000-0000-000000000002';
  id_wh_test       uuid := 'aaaaaaaa-0000-0000-0000-000000000001';
  id_marca_test    uuid := 'bbbbbbbb-0000-0000-0000-000000000001';
  id_categoria_test uuid := 'bbbbbbbb-0000-0000-0000-000000000002';
  id_proveedor_test uuid := 'bbbbbbbb-0000-0000-0000-000000000003';
begin
  delete from public.audit_log
   where changed_by in (id_jefe_test, id_super_test, id_operario_test, id_auditor_test)
      or record_id in (id_item_test::text, id_inv_test::text, id_producto_test::text);

  delete from public.stock_ledger        where item_id = id_item_test;
  delete from public.discrepancies       where item_id = id_item_test;
  delete from public.approval_requests   where entity_id = id_item_test;
  delete from public.alerts              where entity_id in (id_inv_test, id_item_test);
  delete from public.position_assignments where item_id = id_item_test or position_id = id_pos_test;

  -- Las reversiones (FK a sí misma) primero, para no chocar con ON DELETE RESTRICT.
  delete from public.inventory_movements where item_id = id_item_test and reversal_of_id is not null;
  delete from public.inventory_movements where item_id = id_item_test;

  delete from public.inventory_items where id = id_item_test;   -- cascada: borra su fila de inventory
  delete from public.products        where id = id_producto_test;
  delete from public.positions       where id = id_pos_test;
  delete from public.racks           where id = id_rack_test;
  delete from public.warehouses      where id = id_wh_test;
  delete from public.brands          where id = id_marca_test;
  delete from public.categories      where id = id_categoria_test;
  delete from public.suppliers       where id = id_proveedor_test;

  -- Al final: las tablas que referencian profiles lo hacen con ON DELETE SET
  -- NULL, así que esto no puede fallar por FK aunque queden filas de otros
  -- tests apuntando a estos perfiles.
  delete from public.profiles
   where id in (id_jefe_test, id_super_test, id_operario_test, id_auditor_test);

  raise notice 'Limpieza de datos de prueba completa.';
end;
$$;


-- =============================================================================
--  BLOQUE B — CATÁLOGOS (marca, categoría, proveedor, almacenes)
-- =============================================================================
insert into public.warehouses (code, name) values
  ('ALM-A', 'Almacén A'),
  ('BOD-B', 'Bodega B'),
  ('BOD-C', 'Bodega C')
on conflict (code) do nothing;

insert into public.brands (slug, name) values
  ('nike', 'Nike'), ('adidas', 'Adidas'), ('puma', 'Puma'), ('converse', 'Converse'),
  ('new-balance', 'New Balance'), ('vans', 'Vans'), ('reebok', 'Reebok'),
  ('asics', 'Asics'), ('fila', 'Fila'), ('under-armour', 'Under Armour')
on conflict (slug) do nothing;

insert into public.categories (slug, name) values
  ('running', 'Running'), ('casual', 'Casual'), ('lifestyle', 'Lifestyle')
on conflict (slug) do nothing;

insert into public.suppliers (slug, name) values
  ('proveedor-andino', 'Proveedor Andino'),
  ('importadora-lima', 'Importadora Lima'),
  ('sport-house', 'Sport House'),
  ('nike-peru', 'Nike Perú'),
  ('adidas-peru', 'Adidas Perú')
on conflict (slug) do nothing;


-- =============================================================================
--  BLOQUE C — MAPA DEL ALMACÉN (racks y posiciones que el CSV usa de verdad)
-- =============================================================================
insert into public.racks (warehouse_id, code)
select w.id, x.rack_code
from (values
  ('ALM-A', 'RACK-03'), ('ALM-A', 'RACK-01'), ('ALM-A', 'RACK-05'), ('ALM-A', 'RACK-06'),
  ('BOD-B', 'RACK-02'), ('BOD-B', 'RACK-04'), ('BOD-B', 'RACK-01'),
  ('BOD-C', 'RACK-02'), ('BOD-C', 'RACK-06')
) as x(wh_code, rack_code)
join public.warehouses w on w.code = x.wh_code
on conflict (warehouse_id, code) do nothing;

insert into public.positions (rack_id, code, capacity_units)
select r.id, x.pos_code, 200
from (values
  ('ALM-A','RACK-03','A-03-02'), ('ALM-A','RACK-01','A-01-03'),
  ('BOD-B','RACK-02','B-02-01'), ('BOD-B','RACK-04','B-04-02'),
  ('ALM-A','RACK-05','A-05-01'), ('BOD-C','RACK-02','C-02-03'),
  ('ALM-A','RACK-03','A-03-04'), ('BOD-B','RACK-01','B-01-02'),
  ('ALM-A','RACK-05','A-05-03'), ('BOD-C','RACK-02','C-02-01'),
  ('ALM-A','RACK-06','A-06-02'), ('BOD-B','RACK-04','B-04-03'),
  ('ALM-A','RACK-03','A-03-01'), ('BOD-C','RACK-02','C-02-02'),
  ('ALM-A','RACK-05','A-05-04'), ('BOD-B','RACK-04','B-04-01'),
  ('ALM-A','RACK-01','A-01-04'), ('BOD-C','RACK-06','C-06-02'),
  ('ALM-A','RACK-03','A-03-03'), ('BOD-B','RACK-02','B-02-04')
) as x(wh_code, rack_code, pos_code)
join public.warehouses w on w.code = x.wh_code
join public.racks      r on r.warehouse_id = w.id and r.code = x.rack_code
on conflict (rack_id, code) do nothing;


-- =============================================================================
--  BLOQUE D — PRODUCTOS (modelo) Y ARTÍCULOS (variante por talla)
-- =============================================================================
insert into public.products (model_code, name, brand_id, category_id, supplier_id)
select x.model_code, x.name, b.id, c.id, s.id
from (values
  ('ZAP-001','Nike Air Max 90',        'nike',         'running',   'proveedor-andino'),
  ('ZAP-002','Adidas Runfalcon 3',     'adidas',       'running',   'importadora-lima'),
  ('ZAP-003','Puma Smash v2',          'puma',         'casual',    'sport-house'),
  ('ZAP-004','Converse Chuck Taylor',  'converse',     'casual',    'proveedor-andino'),
  ('ZAP-005','New Balance 574',        'new-balance',  'lifestyle', 'importadora-lima'),
  ('ZAP-006','Vans Old Skool',         'vans',         'casual',    'sport-house'),
  ('ZAP-007','Nike Revolution 7',      'nike',         'running',   'nike-peru'),
  ('ZAP-008','Adidas Superstar',       'adidas',       'casual',    'adidas-peru'),
  ('ZAP-009','Reebok Club C 85',       'reebok',       'casual',    'importadora-lima'),
  ('ZAP-010','Asics Gel Contend',      'asics',        'running',   'sport-house'),
  ('ZAP-011','Fila Disruptor II',      'fila',         'lifestyle', 'proveedor-andino'),
  ('ZAP-012','Under Armour Charged',   'under-armour', 'running',   'importadora-lima'),
  ('ZAP-013','Nike Court Vision',      'nike',         'casual',    'nike-peru'),
  ('ZAP-014','Puma Future Rider',      'puma',         'lifestyle', 'sport-house'),
  ('ZAP-015','New Balance Fresh Foam', 'new-balance',  'running',   'importadora-lima'),
  ('ZAP-016','Vans Authentic',         'vans',         'casual',    'sport-house'),
  ('ZAP-017','Adidas Ultraboost',      'adidas',       'running',   'adidas-peru'),
  ('ZAP-018','Converse Run Star',      'converse',     'lifestyle', 'proveedor-andino'),
  ('ZAP-019','Nike Pegasus',           'nike',         'running',   'nike-peru'),
  ('ZAP-020','Puma Suede Classic',     'puma',         'casual',    'sport-house')
) as x(model_code, name, brand_slug, cat_slug, sup_slug)
join public.brands     b on b.slug = x.brand_slug
join public.categories c on c.slug = x.cat_slug
join public.suppliers  s on s.slug = x.sup_slug
on conflict (model_code) do nothing;

insert into public.inventory_items (product_id, sku, size_label)
select p.id, x.model_code || '-' || x.talla, x.talla
from (values
  ('ZAP-001','42'), ('ZAP-002','40'), ('ZAP-003','41'), ('ZAP-004','39'), ('ZAP-005','43'),
  ('ZAP-006','38'), ('ZAP-007','44'), ('ZAP-008','40'), ('ZAP-009','42'), ('ZAP-010','41'),
  ('ZAP-011','39'), ('ZAP-012','43'), ('ZAP-013','40'), ('ZAP-014','42'), ('ZAP-015','44'),
  ('ZAP-016','37'), ('ZAP-017','42'), ('ZAP-018','38'), ('ZAP-019','41'), ('ZAP-020','40')
) as x(model_code, talla)
join public.products p on p.model_code = x.model_code
on conflict (sku) do nothing;


-- =============================================================================
--  BLOQUE E — STOCK ACTUAL (inventory.quantity / min_stock)
-- =============================================================================
insert into public.inventory (item_id, warehouse_id, quantity, min_stock)
select it.id, w.id, x.stock, x.stock_min
from (values
  ('ZAP-001-42','ALM-A',120,15), ('ZAP-002-40','ALM-A', 85,10), ('ZAP-003-41','BOD-B', 60, 8),
  ('ZAP-004-39','BOD-B', 45, 5), ('ZAP-005-43','ALM-A', 70,10), ('ZAP-006-38','BOD-C', 55, 7),
  ('ZAP-007-44','ALM-A', 90,12), ('ZAP-008-40','BOD-B', 35, 6), ('ZAP-009-42','ALM-A', 48, 6),
  ('ZAP-010-41','BOD-C', 25, 5), ('ZAP-011-39','ALM-A', 32, 5), ('ZAP-012-43','BOD-B', 18, 4),
  ('ZAP-013-40','ALM-A', 52, 7), ('ZAP-014-42','BOD-C', 20, 5), ('ZAP-015-44','ALM-A', 15, 4),
  ('ZAP-016-37','BOD-B', 40, 6), ('ZAP-017-42','ALM-A', 22, 5), ('ZAP-018-38','BOD-C', 27, 5),
  ('ZAP-019-41','ALM-A',  8,10), ('ZAP-020-40','BOD-B', 95,12)
) as x(sku, wh_code, stock, stock_min)
join public.inventory_items it on it.sku = x.sku
join public.warehouses      w  on w.code = x.wh_code
on conflict (item_id, warehouse_id) do nothing;
-- Nota: ZAP-019-41 queda con quantity(8) <= min_stock(10) a propósito: dispara
-- sola la alerta STOCK_BAJO_MINIMO (trigger fn_alertas_stock) al insertar. Es
-- evidencia real de que el sistema de alertas funciona, no un dato de ejemplo.


-- =============================================================================
--  BLOQUE F — MAPA DE OCUPACIÓN (dónde está físicamente cada artículo)
-- =============================================================================
insert into public.position_assignments (position_id, item_id, quantity, status)
select pos.id, it.id, x.qty, 'OCUPADA'
from (values
  ('ALM-A','RACK-03','A-03-02','ZAP-001-42',120), ('ALM-A','RACK-01','A-01-03','ZAP-002-40', 85),
  ('BOD-B','RACK-02','B-02-01','ZAP-003-41', 60), ('BOD-B','RACK-04','B-04-02','ZAP-004-39', 45),
  ('ALM-A','RACK-05','A-05-01','ZAP-005-43', 70), ('BOD-C','RACK-02','C-02-03','ZAP-006-38', 55),
  ('ALM-A','RACK-03','A-03-04','ZAP-007-44', 90), ('BOD-B','RACK-01','B-01-02','ZAP-008-40', 35),
  ('ALM-A','RACK-05','A-05-03','ZAP-009-42', 48), ('BOD-C','RACK-02','C-02-01','ZAP-010-41', 25),
  ('ALM-A','RACK-06','A-06-02','ZAP-011-39', 32), ('BOD-B','RACK-04','B-04-03','ZAP-012-43', 18),
  ('ALM-A','RACK-03','A-03-01','ZAP-013-40', 52), ('BOD-C','RACK-02','C-02-02','ZAP-014-42', 20),
  ('ALM-A','RACK-05','A-05-04','ZAP-015-44', 15), ('BOD-B','RACK-04','B-04-01','ZAP-016-37', 40),
  ('ALM-A','RACK-01','A-01-04','ZAP-017-42', 22), ('BOD-C','RACK-06','C-06-02','ZAP-018-38', 27),
  ('ALM-A','RACK-03','A-03-03','ZAP-019-41',  8), ('BOD-B','RACK-02','B-02-04','ZAP-020-40', 95)
) as x(wh_code, rack_code, pos_code, sku, qty)
join public.warehouses      w   on w.code = x.wh_code
join public.racks           r   on r.warehouse_id = w.id and r.code = x.rack_code
join public.positions       pos on pos.rack_id = r.id and pos.code = x.pos_code
join public.inventory_items it  on it.sku = x.sku
on conflict (position_id) where status in ('RESERVADA', 'OCUPADA', 'EN_PICKING') do nothing;


-- =============================================================================
--  BLOQUE G — MOVIMIENTOS HISTÓRICOS (uno por artículo, tal como en el CSV)
-- =============================================================================
-- Protegido para correr una sola vez: si el seed ya se aplicó, no duplica
-- movimientos ni vuelve a sumar qty_reserved/qty_incoming.
do $$
declare
  v_jefe_id uuid;
begin
  if exists (select 1 from public.inventory_movements where reason like 'Carga inicial desde data.csv%') then
    raise notice 'Los movimientos del seed ya existían, no se duplican.';
    return;
  end if;

  select id into v_jefe_id from public.profiles where role = 'JEFE' order by created_at limit 1;
  if v_jefe_id is null then
    raise exception 'No hay ningún perfil con role = JEFE todavía. Promuévete a JEFE antes de correr este bloque (ver Fase 2).';
  end if;

  -- created_by queda NULL a propósito: es una carga masiva de datos históricos,
  -- no una acción de una persona en particular (created_by es nullable). Quien
  -- aprobó/rechazó sí se atribuye al jefe real, para que la sustentación tenga
  -- un caso concreto de "quién decidió esto".
  insert into public.inventory_movements (
    item_id, inventory_id, position_id, movement_type, quantity, reason, status,
    approved_by, created_at, approved_at
  )
  select
    it.id, inv.id, pa.position_id, x.tipo, x.qty,
    'Carga inicial desde data.csv (' || lower(x.tipo) || ')',
    x.estado,
    case when x.estado in ('APROBADO', 'RECHAZADO') then v_jefe_id end,
    x.fecha + time '08:00',
    case when x.estado in ('APROBADO', 'RECHAZADO') then x.fecha + time '10:00' end
  from (values
    ('ZAP-001-42','ENTRADA', 30, date '2026-09-08', 'PENDIENTE'),
    ('ZAP-002-40','ENTRADA', 50, date '2026-09-08', 'APROBADO'),
    ('ZAP-003-41','SALIDA',  12, date '2026-09-07', 'APROBADO'),
    ('ZAP-004-39','SALIDA',   8, date '2026-09-07', 'PENDIENTE'),
    ('ZAP-005-43','ENTRADA', 40, date '2026-09-06', 'APROBADO'),
    ('ZAP-006-38','SALIDA',  15, date '2026-09-06', 'PENDIENTE'),
    ('ZAP-007-44','ENTRADA', 60, date '2026-09-05', 'APROBADO'),
    ('ZAP-008-40','SALIDA',  10, date '2026-09-05', 'RECHAZADO'),
    ('ZAP-009-42','ENTRADA', 30, date '2026-09-04', 'PENDIENTE'),
    ('ZAP-010-41','SALIDA',   5, date '2026-09-04', 'APROBADO'),
    ('ZAP-011-39','ENTRADA', 25, date '2026-09-03', 'APROBADO'),
    ('ZAP-012-43','SALIDA',   7, date '2026-09-03', 'PENDIENTE'),
    ('ZAP-013-40','ENTRADA', 20, date '2026-09-02', 'APROBADO'),
    ('ZAP-014-42','SALIDA',   4, date '2026-09-01', 'PENDIENTE'),
    ('ZAP-015-44','ENTRADA', 35, date '2026-08-31', 'PENDIENTE'),
    ('ZAP-016-37','SALIDA',   9, date '2026-08-30', 'APROBADO'),
    ('ZAP-017-42','ENTRADA', 18, date '2026-08-29', 'PENDIENTE'),
    ('ZAP-018-38','SALIDA',   6, date '2026-08-28', 'RECHAZADO'),
    ('ZAP-019-41','ENTRADA', 25, date '2026-08-27', 'APROBADO'),
    ('ZAP-020-40','SALIDA',  20, date '2026-08-26', 'PENDIENTE')
  ) as x(sku, tipo, qty, fecha, estado)
  join public.inventory_items      it  on it.sku = x.sku
  join public.inventory            inv on inv.item_id = it.id
  join public.position_assignments pa  on pa.item_id = it.id and pa.status = 'OCUPADA';

  -- Los movimientos APROBADO comprometen stock (reserva o espera) sin tocar el
  -- saldo físico todavía: exactamente lo que hace fn_aprobar_movimiento, así
  -- que la demo puede "ejecutarlos" en vivo desde el dashboard y ver el saldo
  -- moverse de verdad.
  update public.inventory inv
     set qty_incoming = inv.qty_incoming + sub.qty
    from (
      select it.id as item_id, x.qty
        from (values
          ('ZAP-002-40',50), ('ZAP-005-43',40), ('ZAP-007-44',60),
          ('ZAP-011-39',25), ('ZAP-013-40',20), ('ZAP-019-41',25)
        ) as x(sku, qty)
        join public.inventory_items it on it.sku = x.sku
    ) as sub
   where inv.item_id = sub.item_id;

  update public.inventory inv
     set qty_reserved = inv.qty_reserved + sub.qty
    from (
      select it.id as item_id, x.qty
        from (values ('ZAP-003-41',12), ('ZAP-010-41',5), ('ZAP-016-37',9)) as x(sku, qty)
        join public.inventory_items it on it.sku = x.sku
    ) as sub
   where inv.item_id = sub.item_id;

  raise notice 'Seed de movimientos aplicado: 20 movimientos históricos, 6 con stock comprometido en espera de ejecución.';
end;
$$;


-- =============================================================================
--  VERIFICACIÓN RÁPIDA
-- =============================================================================
select
  (select count(*) from public.products)               as productos,
  (select count(*) from public.inventory_items)         as articulos,
  (select count(*) from public.inventory)                as registros_stock,
  (select count(*) from public.inventory_movements)     as movimientos,
  (select count(*) from public.position_assignments)    as posiciones_ocupadas,
  (select count(*) from public.alerts where status='ACTIVA') as alertas_activas;
-- Esperado: 20 / 20 / 20 / 20 / 20 / al menos 1 (STOCK_BAJO_MINIMO de ZAP-019-41).
