-- =============================================================================
--  SMOKE TEST — verifica que el esquema hace lo que promete
--
--  Ejecutar DESPUÉS de schema-completo.sql, en el SQL Editor de Supabase.
--  Es re-ejecutable: limpia sus propios datos al empezar.
--
--  Si termina con "TODAS LAS PRUEBAS PASARON", el modelo funciona:
--  workflow de aprobación, reserva de stock, ejecución, reversión, alertas,
--  segregación de funciones, límites por rol y validación de capacidad.
--
--  Cada prueba corresponde a un caso de docs/ANALISIS-OPERATIVO.md.
-- =============================================================================

do $$
declare
  -- IDs fijos para poder limpiar y volver a correr
  id_jefe       uuid := '11111111-1111-1111-1111-111111111111';
  id_super      uuid := '22222222-2222-2222-2222-222222222222';
  id_operario   uuid := '33333333-3333-3333-3333-333333333333';
  id_wh         uuid := 'aaaaaaaa-0000-0000-0000-000000000001';
  id_rack       uuid := 'aaaaaaaa-0000-0000-0000-000000000002';
  id_pos        uuid := 'aaaaaaaa-0000-0000-0000-000000000003';
  id_marca      uuid := 'bbbbbbbb-0000-0000-0000-000000000001';
  id_categoria  uuid := 'bbbbbbbb-0000-0000-0000-000000000002';
  id_proveedor  uuid := 'bbbbbbbb-0000-0000-0000-000000000003';
  id_producto   uuid := 'cccccccc-0000-0000-0000-000000000001';
  id_item       uuid := 'cccccccc-0000-0000-0000-000000000002';
  id_inv        uuid := 'cccccccc-0000-0000-0000-000000000003';

  v_mov         public.inventory_movements;
  v_rev         public.inventory_movements;
  v_ajuste      public.inventory_movements;
  v_qty         integer;
  v_reserved    integer;
  v_asientos    integer;
  v_alertas     integer;
  v_fallo       boolean;
  v_resultado   jsonb;
begin
  raise notice '--- LIMPIEZA ---';
  delete from public.stock_ledger        where item_id = id_item;
  delete from public.discrepancies       where item_id = id_item;
  delete from public.alerts              where entity_id in (id_inv, id_item);
  delete from public.approval_requests   where entity_id = id_item;
  -- Las reversiones primero: reversal_of_id es ON DELETE RESTRICT.
  delete from public.inventory_movements where item_id = id_item and reversal_of_id is not null;
  delete from public.inventory_movements where item_id = id_item;
  delete from public.position_assignments where item_id = id_item;
  delete from public.inventory           where item_id = id_item;
  delete from public.inventory_items     where id = id_item;
  delete from public.products            where id = id_producto;
  delete from public.positions           where id = id_pos;
  delete from public.racks               where id = id_rack;
  delete from public.warehouses          where id = id_wh;
  delete from public.brands              where id = id_marca;
  delete from public.categories          where id = id_categoria;
  delete from public.suppliers           where id = id_proveedor;
  delete from public.profiles            where id in (id_jefe, id_super, id_operario);

  raise notice '--- DATOS DE PARTIDA ---';
  insert into public.profiles (id, full_name, role, max_movement_qty) values
    (id_jefe,     'Ana Jefa de Almacén', 'JEFE',       null),
    (id_super,    'Luis Supervisor',     'SUPERVISOR', 50),
    (id_operario, 'Rosa Operaria',       'OPERARIO',   null);

  insert into public.brands     (id, slug, name) values (id_marca,     'nike',            'Nike');
  insert into public.categories (id, slug, name) values (id_categoria, 'running',         'Running');
  insert into public.suppliers  (id, slug, name) values (id_proveedor, 'proveedor-andino','Proveedor Andino');

  insert into public.warehouses (id, code, name) values (id_wh, 'ALM-A', 'Almacén A');
  insert into public.racks      (id, warehouse_id, code) values (id_rack, id_wh, 'RACK-03');
  insert into public.positions  (id, rack_id, code, capacity_units)
    values (id_pos, id_rack, 'A-03-02', 50);

  insert into public.products (id, model_code, name, brand_id, category_id, supplier_id)
    values (id_producto, 'ZAP-001', 'Nike Air Max 90', id_marca, id_categoria, id_proveedor);

  insert into public.inventory_items (id, product_id, sku, size_label, price, cost)
    values (id_item, id_producto, 'ZAP-001-42', '42', 850.00, 600.00);

  -- Stock inicial 100, mínimo 85: una salida de 20 debe disparar la alerta.
  insert into public.inventory (id, item_id, warehouse_id, quantity, min_stock, max_stock)
    values (id_inv, id_item, id_wh, 100, 85, 500);

  raise notice 'Stock inicial: 100 unidades de ZAP-001-42 (mínimo 85)';


  -- ===========================================================================
  raise notice '';
  raise notice 'PRUEBA 1 — Crear un movimiento NO debe tocar el stock';
  -- ===========================================================================
  insert into public.inventory_movements
    (item_id, inventory_id, position_id, movement_type, quantity, reason, created_by)
  values
    (id_item, id_inv, id_pos, 'SALIDA', 20, 'Pedido tienda Miraflores', id_super)
  returning * into v_mov;

  select quantity into v_qty from public.inventory where id = id_inv;
  assert v_qty = 100, format('El stock cambió al crear el movimiento: %s (esperado 100)', v_qty);
  assert v_mov.status = 'PENDIENTE', 'El movimiento no nació PENDIENTE';
  assert v_mov.direction = -1, 'El trigger no derivó direction = -1 para una SALIDA';
  raise notice '  OK: stock sigue en 100, movimiento PENDIENTE, direction = -1';


  -- ===========================================================================
  raise notice '';
  raise notice 'PRUEBA 2 — Nadie puede aprobar su propio movimiento (E-30)';
  -- ===========================================================================
  v_fallo := false;
  begin
    perform public.fn_aprobar_movimiento(v_mov.id, id_super);   -- id_super lo creó
  exception when others then
    v_fallo := true;
    raise notice '  Rechazado correctamente: %', sqlerrm;
  end;
  assert v_fallo, 'FALLO GRAVE: el sistema permitió aprobar el propio movimiento';
  raise notice '  OK: segregación de funciones activa';


  -- ===========================================================================
  raise notice '';
  raise notice 'PRUEBA 3 — Un OPERARIO no puede aprobar (E-34)';
  -- ===========================================================================
  v_fallo := false;
  begin
    perform public.fn_aprobar_movimiento(v_mov.id, id_operario);
  exception when others then
    v_fallo := true;
    raise notice '  Rechazado correctamente: %', sqlerrm;
  end;
  assert v_fallo, 'FALLO GRAVE: un operario pudo aprobar';
  raise notice '  OK: límite por rol activo';


  -- ===========================================================================
  raise notice '';
  raise notice 'PRUEBA 4 — Aprobar RESERVA el stock pero no lo mueve (E-20)';
  -- ===========================================================================
  perform public.fn_aprobar_movimiento(v_mov.id, id_jefe);

  select quantity, qty_reserved into v_qty, v_reserved from public.inventory where id = id_inv;
  assert v_qty = 100,     format('El stock se movió al aprobar: %s (esperado 100)', v_qty);
  assert v_reserved = 20, format('No se reservó el stock: qty_reserved = %s (esperado 20)', v_reserved);
  raise notice '  OK: stock 100, comprometido 20, disponible real 80';


  -- ===========================================================================
  raise notice '';
  raise notice 'PRUEBA 5 — No se puede comprometer dos veces lo mismo (E-19/E-20)';
  -- ===========================================================================
  -- Disponible real = 100 - 20 = 80. Una salida de 90 debe rechazarse aunque
  -- el stock bruto (100) alcance.
  insert into public.inventory_movements
    (item_id, inventory_id, movement_type, quantity, reason, created_by)
  values (id_item, id_inv, 'SALIDA', 90, 'Pedido imposible', id_super);

  v_fallo := false;
  begin
    perform public.fn_aprobar_movimiento(
      (select id from public.inventory_movements
        where item_id = id_item and quantity = 90 and status = 'PENDIENTE' limit 1),
      id_jefe);
  exception when others then
    v_fallo := true;
    raise notice '  Rechazado correctamente: %', sqlerrm;
  end;
  assert v_fallo, 'FALLO GRAVE: se aprobó una salida sobre stock ya comprometido';
  raise notice '  OK: valida contra disponible real, no contra stock bruto';


  -- ===========================================================================
  raise notice '';
  raise notice 'PRUEBA 6 — Ejecutar mueve el stock y escribe el kardex';
  -- ===========================================================================
  perform public.fn_ejecutar_movimiento(v_mov.id, id_operario, null, 'BUENO');

  select quantity, qty_reserved into v_qty, v_reserved from public.inventory where id = id_inv;
  assert v_qty = 80,     format('Stock incorrecto tras ejecutar: %s (esperado 80)', v_qty);
  assert v_reserved = 0, format('La reserva no se liberó: %s (esperado 0)', v_reserved);

  select count(*) into v_asientos from public.stock_ledger where movement_id = v_mov.id;
  assert v_asientos = 1, format('El kardex no registró el asiento (%s filas)', v_asientos);
  raise notice '  OK: 100 -> 80, reserva liberada, asiento en el kardex';


  -- ===========================================================================
  raise notice '';
  raise notice 'PRUEBA 7 — La alerta de stock bajo mínimo se dispara sola (E-13)';
  -- ===========================================================================
  select count(*) into v_alertas
    from public.alerts
   where entity_id = id_inv and alert_type = 'STOCK_BAJO_MINIMO' and status = 'ACTIVA';
  assert v_alertas = 1, format('No se generó la alerta de stock bajo mínimo (%s)', v_alertas);
  raise notice '  OK: alerta CRITICA generada por trigger, sin intervención del frontend';


  -- ===========================================================================
  raise notice '';
  raise notice 'PRUEBA 8 — Un movimiento ejecutado no se puede editar (E-33)';
  -- ===========================================================================
  v_fallo := false;
  begin
    update public.inventory_movements set quantity = 5 where id = v_mov.id;
  exception when others then
    v_fallo := true;
    raise notice '  Rechazado correctamente: %', sqlerrm;
  end;
  assert v_fallo, 'FALLO GRAVE: se pudo editar un movimiento ya ejecutado';
  raise notice '  OK: lo ejecutado es inmutable';


  -- ===========================================================================
  raise notice '';
  raise notice 'PRUEBA 9 — Revertir devuelve el stock sin borrar nada (§6)';
  -- ===========================================================================
  -- Un supervisor no puede revertir
  v_fallo := false;
  begin
    perform public.fn_revertir_movimiento(v_mov.id, id_super, 'Picking de talla equivocada');
  exception when others then
    v_fallo := true;
  end;
  assert v_fallo, 'FALLO GRAVE: un supervisor pudo revertir un movimiento ejecutado';

  -- El jefe sí
  v_rev := public.fn_revertir_movimiento(v_mov.id, id_jefe, 'Picking de talla equivocada');

  select quantity into v_qty from public.inventory where id = id_inv;
  assert v_qty = 100, format('La reversión no devolvió el stock: %s (esperado 100)', v_qty);
  assert v_rev.reversal_of_id = v_mov.id, 'La reversión no quedó ligada al movimiento original';

  -- El movimiento original sigue existiendo, intacto
  select count(*) into v_asientos from public.inventory_movements where id = v_mov.id;
  assert v_asientos = 1, 'El movimiento original desapareció: se borró en vez de revertirse';

  -- El kardex tiene los dos asientos
  select count(*) into v_asientos from public.stock_ledger where item_id = id_item;
  assert v_asientos = 2, format('El kardex debería tener 2 asientos, tiene %s', v_asientos);
  raise notice '  OK: 80 -> 100 por contra-asiento, original intacto, 2 asientos en el kardex';


  -- ===========================================================================
  raise notice '';
  raise notice 'PRUEBA 10 — La alerta se cierra sola al recuperarse el stock';
  -- ===========================================================================
  select count(*) into v_alertas
    from public.alerts
   where entity_id = id_inv and alert_type = 'STOCK_BAJO_MINIMO' and status = 'ACTIVA';
  assert v_alertas = 0, 'La alerta siguió activa aunque el stock se recuperó';
  raise notice '  OK: alerta resuelta automáticamente';


  -- ===========================================================================
  raise notice '';
  raise notice 'PRUEBA 11 — Un movimiento no se revierte dos veces';
  -- ===========================================================================
  v_fallo := false;
  begin
    perform public.fn_revertir_movimiento(v_mov.id, id_jefe, 'Segundo intento');
  exception when others then
    v_fallo := true;
  end;
  assert v_fallo, 'FALLO GRAVE: se revirtió dos veces el mismo movimiento';
  raise notice '  OK: reversión única';


  -- ===========================================================================
  raise notice '';
  raise notice 'PRUEBA 12 — El AJUSTE puede restar (bug corregido, E-16)';
  -- ===========================================================================
  insert into public.inventory_movements
    (item_id, inventory_id, movement_type, direction, quantity, reason, created_by)
  values (id_item, id_inv, 'AJUSTE', -1, 3, 'Conteo físico: faltan 3 pares', id_super)
  returning * into v_ajuste;

  perform public.fn_aprobar_movimiento(v_ajuste.id, id_jefe);
  perform public.fn_ejecutar_movimiento(v_ajuste.id, id_jefe, null, 'BUENO');

  select quantity into v_qty from public.inventory where id = id_inv;
  assert v_qty = 97, format('El ajuste negativo no se aplicó: %s (esperado 97)', v_qty);
  raise notice '  OK: 100 -> 97 por ajuste a la baja';


  -- ===========================================================================
  raise notice '';
  raise notice 'PRUEBA 13 — No se puede sobrecargar una posición (E-12)';
  -- ===========================================================================
  v_fallo := false;
  begin
    insert into public.position_assignments (position_id, item_id, quantity, status)
    values (id_pos, id_item, 60, 'OCUPADA');    -- capacidad = 50
  exception when others then
    v_fallo := true;
    raise notice '  Rechazado correctamente: %', sqlerrm;
  end;
  assert v_fallo, 'FALLO GRAVE: se asignaron 60 unidades a un slot con capacidad 50';
  raise notice '  OK: capacidad del slot validada';


  -- ===========================================================================
  raise notice '';
  raise notice 'PRUEBA 14 — Dos productos no pueden ocupar el mismo espacio (CASO)';
  -- ===========================================================================
  insert into public.position_assignments (position_id, item_id, quantity, status)
  values (id_pos, id_item, 40, 'OCUPADA');

  v_fallo := false;
  begin
    insert into public.position_assignments (position_id, item_id, quantity, status)
    values (id_pos, id_item, 5, 'RESERVADA');
  exception when others then
    v_fallo := true;
  end;
  assert v_fallo, 'FALLO GRAVE: dos asignaciones vivas sobre la misma posición';
  raise notice '  OK: índice único parcial bloqueando la doble ocupación';


  -- ===========================================================================
  raise notice '';
  raise notice 'PRUEBA 15 — No se elimina un artículo con stock (E-32)';
  -- ===========================================================================
  v_fallo := false;
  begin
    perform public.fn_eliminar_articulo(id_item, id_jefe, 'Descontinuado');
  exception when others then
    v_fallo := true;
    raise notice '  Rechazado correctamente: %', sqlerrm;
  end;
  assert v_fallo, 'FALLO GRAVE: se eliminó un artículo con stock físico';
  raise notice '  OK: eliminación bloqueada';


  -- ===========================================================================
  raise notice '';
  raise notice 'PRUEBA 16 — Sin rango de jefe, eliminar escala a autorización';
  -- ===========================================================================
  -- Se deja el stock en cero para aislar la regla de autorización
  update public.inventory set quantity = 0, qty_reserved = 0 where id = id_inv;

  v_resultado := public.fn_eliminar_articulo(id_item, id_super, 'Modelo descontinuado');
  assert v_resultado ->> 'estado' = 'PENDIENTE_APROBACION',
    format('La eliminación no escaló: %s', v_resultado);

  select count(*) into v_alertas
    from public.approval_requests
   where entity_id = id_item and action_type = 'ELIMINAR_ARTICULO' and status = 'PENDIENTE';
  assert v_alertas = 1, 'No se creó la solicitud de autorización';
  raise notice '  OK: la eliminación quedó esperando el visto bueno del jefe';


  -- ===========================================================================
  raise notice '';
  raise notice 'PRUEBA 17 — La auditoría registró todo sola (E-38)';
  -- ===========================================================================
  select count(*) into v_asientos
    from public.audit_log
   where table_name = 'inventory_movements' and record_id = v_mov.id::text;
  assert v_asientos >= 2, format('La auditoría no registró el movimiento (%s filas)', v_asientos);
  raise notice '  OK: % eventos auditados solo para el movimiento de prueba', v_asientos;


  raise notice '';
  raise notice '=============================================';
  raise notice '  TODAS LAS PRUEBAS PASARON';
  raise notice '=============================================';
end;
$$;
