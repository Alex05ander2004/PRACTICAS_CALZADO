-- =============================================================================
--  TEST DE RLS — ¿cada rol puede exactamente lo que le corresponde?
--
--  Ejecutar DESPUÉS de 03_rls.sql y de 01_smoke_test.sql.
--
--  Cómo funciona: no hacen falta usuarios reales de Supabase Auth. Se simula la
--  sesión de cada rol escribiendo el JWT en `request.jwt.claims` (que es de
--  donde auth.uid() lee) y cambiando al rol de Postgres `authenticated`, que es
--  el que usa el frontend. Así las políticas se evalúan de verdad.
--
--  El SQL Editor corre como `postgres`, que tiene BYPASSRLS: por eso hay que
--  cambiar de rol explícitamente o las políticas no se aplicarían nunca y el
--  test daría un falso positivo.
-- =============================================================================

do $$
declare
  id_jefe     uuid := '11111111-1111-1111-1111-111111111111';
  id_super    uuid := '22222222-2222-2222-2222-222222222222';
  id_operario uuid := '33333333-3333-3333-3333-333333333333';
  id_auditor  uuid := '44444444-4444-4444-4444-444444444444';
  id_fantasma uuid := '99999999-9999-9999-9999-999999999999';  -- autenticado sin perfil
  id_item     uuid := 'cccccccc-0000-0000-0000-000000000002';
  id_inv      uuid := 'cccccccc-0000-0000-0000-000000000003';
  id_wh       uuid := 'aaaaaaaa-0000-0000-0000-000000000001';
  id_rack     uuid := 'aaaaaaaa-0000-0000-0000-000000000002';
  id_pos      uuid := 'aaaaaaaa-0000-0000-0000-000000000003';
  id_marca    uuid := 'bbbbbbbb-0000-0000-0000-000000000001';
  id_categoria uuid := 'bbbbbbbb-0000-0000-0000-000000000002';
  id_proveedor uuid := 'bbbbbbbb-0000-0000-0000-000000000003';
  id_producto uuid := 'cccccccc-0000-0000-0000-000000000001';

  v_rol       text;
  v_n         integer;
  v_fallo     boolean;
  v_mov_id    uuid;
  v_aprobador uuid;
begin
  -- ---------------------------------------------------------------------------
  -- Preparación (todavía como postgres)
  -- ---------------------------------------------------------------------------
  insert into public.profiles (id, full_name, role, max_movement_qty) values
    (id_jefe,     'Ana Jefa de Almacén', 'JEFE',       null),
    (id_super,    'Luis Supervisor',     'SUPERVISOR', 50),
    (id_operario, 'Rosa Operaria',       'OPERARIO',   null),
    (id_auditor,  'Carlos Auditor',      'AUDITOR',    null)
  on conflict (id) do update set role = excluded.role, is_active = true;

  -- Datos mínimos propios: este test no depende de que 01_smoke_test.sql haya
  -- corrido antes. Un test de seguridad que se salta según el orden de
  -- ejecución es el que nadie corre en la revisión final.
  insert into public.brands     (id, slug, name) values (id_marca,     'nike',             'Nike')             on conflict do nothing;
  insert into public.categories (id, slug, name) values (id_categoria, 'running',          'Running')          on conflict do nothing;
  insert into public.suppliers  (id, slug, name) values (id_proveedor, 'proveedor-andino', 'Proveedor Andino') on conflict do nothing;
  insert into public.warehouses (id, code, name) values (id_wh, 'ALM-A', 'Almacén A')                          on conflict do nothing;
  insert into public.racks      (id, warehouse_id, code) values (id_rack, id_wh, 'RACK-03')                    on conflict do nothing;
  insert into public.positions  (id, rack_id, code, capacity_units) values (id_pos, id_rack, 'A-03-02', 50)    on conflict do nothing;

  insert into public.products (id, model_code, name, brand_id, category_id, supplier_id)
    values (id_producto, 'ZAP-001', 'Nike Air Max 90', id_marca, id_categoria, id_proveedor)
    on conflict do nothing;

  insert into public.inventory_items (id, product_id, sku, size_label, price, cost)
    values (id_item, id_producto, 'ZAP-001-42', '42', 850.00, 600.00)
    on conflict do nothing;

  insert into public.inventory (id, item_id, warehouse_id, quantity, min_stock, max_stock)
    values (id_inv, id_item, id_wh, 100, 85, 500)
    on conflict do nothing;

  -- Un movimiento PENDIENTE creado por el JEFE, para que el SUPERVISOR pueda
  -- aprobarlo sin chocar con la segregación de funciones.
  insert into public.inventory_movements
    (item_id, inventory_id, movement_type, quantity, reason, created_by)
  values (id_item, id_inv, 'ENTRADA', 10, 'Movimiento para probar RLS', id_jefe)
  returning id into v_mov_id;

  raise notice '--- Datos listos. Empieza la simulación de roles ---';


  -- ===========================================================================
  raise notice '';
  raise notice 'PRUEBA 1 — Cada JWT resuelve al rol correcto';
  -- ===========================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', id_operario)::text, true);
  execute 'set local role authenticated';
  select public.fn_rol_actual() into v_rol;
  execute 'reset role';
  assert v_rol = 'OPERARIO', format('Se esperaba OPERARIO y se obtuvo %s', v_rol);

  perform set_config('request.jwt.claims', json_build_object('sub', id_auditor)::text, true);
  execute 'set local role authenticated';
  select public.fn_rol_actual() into v_rol;
  execute 'reset role';
  assert v_rol = 'AUDITOR', format('Se esperaba AUDITOR y se obtuvo %s', v_rol);

  perform set_config('request.jwt.claims', json_build_object('sub', id_fantasma)::text, true);
  execute 'set local role authenticated';
  select public.fn_rol_actual() into v_rol;
  execute 'reset role';
  assert v_rol is null, 'Un usuario sin perfil no debería resolver a ningún rol';
  raise notice '  OK: OPERARIO, AUDITOR y "sin perfil" resuelven correctamente';


  -- ===========================================================================
  raise notice '';
  raise notice 'PRUEBA 2 — Un OPERARIO no puede crear movimientos';
  -- ===========================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', id_operario)::text, true);
  execute 'set local role authenticated';
  v_fallo := false;
  begin
    insert into public.inventory_movements
      (item_id, inventory_id, movement_type, quantity, reason, created_by)
    values (id_item, id_inv, 'SALIDA', 1, 'No debería poder', id_operario);
  exception when others then
    v_fallo := true;
  end;
  execute 'reset role';
  assert v_fallo, 'FALLO GRAVE: un operario creó un movimiento';
  raise notice '  OK: bloqueado por la política de INSERT';


  -- ===========================================================================
  raise notice '';
  raise notice 'PRUEBA 3 — Un SUPERVISOR sí puede, pero solo a su propio nombre';
  -- ===========================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', id_super)::text, true);
  execute 'set local role authenticated';

  insert into public.inventory_movements
    (item_id, inventory_id, movement_type, quantity, reason, created_by)
  values (id_item, id_inv, 'SALIDA', 1, 'Creado por el supervisor', id_super);

  -- Intentar crearlo a nombre del jefe (primer paso para evadir la segregación)
  v_fallo := false;
  begin
    insert into public.inventory_movements
      (item_id, inventory_id, movement_type, quantity, reason, created_by)
    values (id_item, id_inv, 'SALIDA', 1, 'Suplantando al jefe', id_jefe);
  exception when others then
    v_fallo := true;
  end;
  execute 'reset role';
  assert v_fallo, 'FALLO GRAVE: se creó un movimiento a nombre de otra persona';
  raise notice '  OK: crea a su nombre, no al de otro';


  -- ===========================================================================
  raise notice '';
  raise notice 'PRUEBA 4 — NADIE mueve el stock con un UPDATE directo (ni el jefe)';
  -- ===========================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', id_jefe)::text, true);
  execute 'set local role authenticated';
  update public.inventory set quantity = 99999 where id = id_inv;
  get diagnostics v_n = row_count;
  execute 'reset role';
  -- Sin política de UPDATE, la fila es invisible para el UPDATE: 0 filas afectadas.
  assert v_n = 0, format('FALLO GRAVE: el jefe modificó el stock directamente (%s filas)', v_n);

  select quantity into v_n from public.inventory where id = id_inv;
  assert v_n <> 99999, 'FALLO GRAVE: el stock quedó alterado por un UPDATE directo';
  raise notice '  OK: el saldo solo se mueve por el workflow';


  -- ===========================================================================
  raise notice '';
  raise notice 'PRUEBA 5 — El kardex no admite escritura desde el cliente';
  -- ===========================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', id_jefe)::text, true);
  execute 'set local role authenticated';
  v_fallo := false;
  begin
    insert into public.stock_ledger (item_id, warehouse_id, qty_delta, qty_before, qty_after)
    select id_item, warehouse_id, 100, 0, 100 from public.inventory where id = id_inv;
  exception when others then
    v_fallo := true;
  end;
  execute 'reset role';
  assert v_fallo, 'FALLO GRAVE: se pudo escribir un asiento falso en el kardex';
  raise notice '  OK: stock_ledger es inmutable desde la aplicación';


  -- ===========================================================================
  raise notice '';
  raise notice 'PRUEBA 6 — La auditoría solo la ven JEFE y AUDITOR';
  -- ===========================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', id_operario)::text, true);
  execute 'set local role authenticated';
  select count(*) into v_n from public.audit_log;
  execute 'reset role';
  assert v_n = 0, format('FALLO GRAVE: un operario vio %s filas de auditoría', v_n);

  perform set_config('request.jwt.claims', json_build_object('sub', id_auditor)::text, true);
  execute 'set local role authenticated';
  select count(*) into v_n from public.audit_log;
  execute 'reset role';
  assert v_n > 0, 'El auditor no pudo leer la auditoría';
  raise notice '  OK: operario 0 filas, auditor % filas', v_n;


  -- ===========================================================================
  raise notice '';
  raise notice 'PRUEBA 7 — El AUDITOR es estrictamente de solo lectura';
  -- ===========================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', id_auditor)::text, true);
  execute 'set local role authenticated';

  select count(*) into v_n from public.inventory;   -- lee sin problema

  v_fallo := false;
  begin
    insert into public.discrepancies (item_id, discrepancy_type, detail, reported_by)
    values (id_item, 'FALTANTE', 'El auditor no debería poder', id_auditor);
  exception when others then
    v_fallo := true;
  end;
  execute 'reset role';
  assert v_n > 0, 'El auditor no pudo leer el inventario';
  assert v_fallo, 'FALLO GRAVE: el auditor insertó una discrepancia';
  raise notice '  OK: lee todo (% filas de inventario), no escribe nada', v_n;


  -- ===========================================================================
  raise notice '';
  raise notice 'PRUEBA 8 — Un AUDITOR no puede aprobar movimientos';
  -- ===========================================================================
  -- Este es el agujero que tenían las fn_* originales: solo rechazaban al
  -- OPERARIO, así que un rol de solo lectura pasaba el filtro.
  perform set_config('request.jwt.claims', json_build_object('sub', id_auditor)::text, true);
  execute 'set local role authenticated';
  v_fallo := false;
  begin
    perform public.aprobar_movimiento(v_mov_id);
  exception when others then
    v_fallo := true;
  end;
  execute 'reset role';
  assert v_fallo, 'FALLO GRAVE: un auditor aprobó un movimiento';
  raise notice '  OK: guarda de rol activa en la API pública';


  -- ===========================================================================
  raise notice '';
  raise notice 'PRUEBA 9 — Imposible suplantar: las fn_* no son invocables';
  -- ===========================================================================
  -- fn_aprobar_movimiento(uuid, uuid) acepta el usuario como parámetro. Si el
  -- cliente pudiera llamarla, pasaría el UUID del jefe y aprobaría en su nombre.
  perform set_config('request.jwt.claims', json_build_object('sub', id_super)::text, true);
  execute 'set local role authenticated';
  v_fallo := false;
  begin
    perform public.fn_aprobar_movimiento(v_mov_id, id_jefe);   -- suplantación
  exception when others then
    v_fallo := true;
    raise notice '  Rechazado: %', sqlerrm;
  end;
  execute 'reset role';
  assert v_fallo, 'FALLO GRAVE: el cliente pudo llamar la función interna y suplantar a otro usuario';
  raise notice '  OK: EXECUTE revocado sobre las funciones internas';


  -- ===========================================================================
  raise notice '';
  raise notice 'PRUEBA 10 — Al aprobar, queda registrado quien REALMENTE aprobó';
  -- ===========================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', id_super)::text, true);
  execute 'set local role authenticated';
  perform public.aprobar_movimiento(v_mov_id);
  execute 'reset role';

  select approved_by into v_aprobador from public.inventory_movements where id = v_mov_id;
  assert v_aprobador = id_super,
    format('El aprobador registrado es %s y debía ser el supervisor', v_aprobador);
  raise notice '  OK: approved_by sale de la sesión, no de un parámetro del cliente';


  -- ===========================================================================
  raise notice '';
  raise notice 'PRUEBA 11 — Un SUPERVISOR no puede revertir (es potestad del jefe)';
  -- ===========================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', id_super)::text, true);
  execute 'set local role authenticated';
  v_fallo := false;
  begin
    perform public.revertir_movimiento(v_mov_id, 'Intento indebido');
  exception when others then
    v_fallo := true;
  end;
  execute 'reset role';
  assert v_fallo, 'FALLO GRAVE: un supervisor revirtió un movimiento';
  raise notice '  OK: la reversión exige rango de jefe';


  -- ===========================================================================
  raise notice '';
  raise notice 'PRUEBA 12 — Nadie se asciende solo';
  -- ===========================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', id_operario)::text, true);
  execute 'set local role authenticated';
  v_fallo := false;
  begin
    update public.profiles set role = 'JEFE' where id = id_operario;
  exception when others then
    v_fallo := true;
    raise notice '  Rechazado: %', sqlerrm;
  end;
  execute 'reset role';

  select role into v_rol from public.profiles where id = id_operario;
  assert v_rol = 'OPERARIO', format('FALLO GRAVE: el operario terminó con rol %s', v_rol);
  raise notice '  OK: sigue siendo OPERARIO';


  -- ===========================================================================
  raise notice '';
  raise notice 'PRUEBA 13 — DELETE prohibido para todos';
  -- ===========================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', id_jefe)::text, true);
  execute 'set local role authenticated';
  v_fallo := false;
  begin
    delete from public.inventory_items where id = id_item;
  exception when others then
    v_fallo := true;
  end;
  execute 'reset role';
  assert v_fallo, 'FALLO GRAVE: se pudo borrar físicamente un artículo';
  raise notice '  OK: aquí nada se borra, se marca deleted_at';


  -- ===========================================================================
  raise notice '';
  raise notice 'PRUEBA 14 — Las vistas respetan RLS (no lo saltan)';
  -- ===========================================================================
  -- Sin security_invoker, una vista se ejecuta como su dueño y devolvería todo
  -- aunque las tablas base estén protegidas.
  perform set_config('request.jwt.claims', json_build_object('sub', id_fantasma)::text, true);
  execute 'set local role authenticated';
  select count(*) into v_n from public.v_stock_actual;
  execute 'reset role';
  assert v_n = 0, format('FALLO GRAVE: un usuario sin perfil vio %s filas a través de la vista', v_n);

  perform set_config('request.jwt.claims', json_build_object('sub', id_super)::text, true);
  execute 'set local role authenticated';
  select count(*) into v_n from public.v_stock_actual;
  execute 'reset role';
  assert v_n > 0, 'El supervisor no vio nada en la vista de stock';
  raise notice '  OK: sin perfil 0 filas, supervisor % filas', v_n;


  -- ---------------------------------------------------------------------------
  -- Limpieza del movimiento de prueba (como postgres)
  -- ---------------------------------------------------------------------------
  delete from public.stock_ledger        where movement_id = v_mov_id;
  delete from public.inventory_movements
   where reason in ('Movimiento para probar RLS', 'Creado por el supervisor');
  update public.inventory set qty_incoming = 0, qty_reserved = 0 where id = id_inv;

  raise notice '';
  raise notice '=============================================';
  raise notice '  RLS VERIFICADO: 14/14 PRUEBAS PASARON';
  raise notice '=============================================';
end;
$$;
