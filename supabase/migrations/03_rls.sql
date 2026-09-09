-- =============================================================================
--  MIGRACIÓN 03 — SEGURIDAD: RLS, API PÚBLICA Y PERMISOS
--
--  Traduce la matriz de roles de docs/ANALISIS-OPERATIVO.md §1 a políticas de
--  base de datos, y cierra tres agujeros que las migraciones anteriores dejaban:
--
--    1. Las RPC recibían `p_user_id` como parámetro y confiaban en él: un
--       cliente podía pasar el UUID del jefe y aprobar en su nombre.
--    2. Las vistas se ejecutan con los permisos de su dueño y por lo tanto
--       SALTAN el RLS de las tablas base.
--    3. profiles.id no estaba enlazado a auth.users, así que auth.uid() no
--       correspondía con ningún perfil.
--
--  Principio de diseño: el stock NO se modifica nunca por UPDATE directo del
--  cliente. Ninguna tabla de saldo tiene política de escritura. La única vía es
--  el workflow, y el workflow vive en funciones SECURITY DEFINER auditadas.
--
--  Requiere 01 y 02. Idempotente.
-- =============================================================================


-- =============================================================================
--  BLOQUE A — QUIÉN ES QUIEN PREGUNTA
-- =============================================================================

-- SECURITY DEFINER a propósito: si esta función consultara `profiles` con RLS
-- activo desde dentro de una política SOBRE profiles, Postgres entraría en
-- recursión infinita ("infinite recursion detected in policy"). Al ejecutarse
-- como su dueño, la lectura interna no evalúa políticas.
-- STABLE (no VOLATILE) para que el planificador la evalúe una vez por consulta
-- y no una vez por fila.
create or replace function public.fn_rol_actual()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select p.role
    from public.profiles p
   where p.id = auth.uid()
     and p.is_active;
$$;

comment on function public.fn_rol_actual is
  'Rol del usuario autenticado, o NULL si no tiene perfil o está desactivado. Un NULL no matchea ninguna política: sin perfil no se ve nada.';

-- Atajo legible para las políticas de escritura.
create or replace function public.fn_es_al_menos_supervisor()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select (select public.fn_rol_actual()) in ('SUPERVISOR', 'JEFE');
$$;

create or replace function public.fn_es_jefe()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.fn_rol_actual() = 'JEFE';
$$;

-- Guarda de rol para la API pública. Es necesaria porque las funciones fn_* de
-- la migración 02 solo comprobaban que quien aprueba no fuera OPERARIO: un
-- AUDITOR (rol de solo lectura) las habría pasado sin problema. Aquí se declara
-- explícitamente qué roles admite cada operación.
create or replace function public.fn_exigir_rol(variadic p_roles text[])
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_rol text;
begin
  v_rol := public.fn_rol_actual();
  if v_rol is null then
    raise exception 'No tienes un perfil activo en el sistema. Contacta al jefe de almacén.'
      using errcode = 'insufficient_privilege';
  end if;
  if not (v_rol = any (p_roles)) then
    raise exception 'Tu rol (%) no autoriza esta operación.', v_rol
      using errcode = 'insufficient_privilege';
  end if;
  return v_rol;
end;
$$;


-- =============================================================================
--  BLOQUE B — API PÚBLICA: LAS FUNCIONES QUE SÍ PUEDE LLAMAR EL FRONTEND
-- =============================================================================
--  AGUJERO CERRADO: las funciones fn_* aceptan `p_user_id` y confían en él.
--  En vez de reescribirlas (y arriesgar introducir errores en lógica ya
--  probada), se las saca del alcance del cliente y se exponen wrappers que
--  derivan el actor de la sesión con auth.uid(). El parámetro deja de existir
--  en la superficie pública, así que la suplantación es imposible por
--  construcción, no por validación.
--
--  Las fn_* siguen disponibles para el SQL Editor, el seed y los tests, donde
--  quien las ejecuta es el rol postgres y auth.uid() es NULL.
--
--  Convención: `fn_*` = interno.  Sin prefijo = API del frontend.

create or replace function public.actor_actual()
returns uuid
language plpgsql
stable
set search_path = public
as $$
declare v_uid uuid;
begin
  v_uid := auth.uid();
  if v_uid is null then
    raise exception 'No hay sesión activa. Inicia sesión para realizar esta operación.'
      using errcode = 'insufficient_privilege';
  end if;
  return v_uid;
end;
$$;

create or replace function public.aprobar_movimiento(p_movement_id uuid)
returns public.inventory_movements
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.fn_exigir_rol('SUPERVISOR', 'JEFE');
  return public.fn_aprobar_movimiento(p_movement_id, public.actor_actual());
end;
$$;

create or replace function public.ejecutar_movimiento(
  p_movement_id   uuid,
  p_cantidad_real integer default null,
  p_quality       text    default 'BUENO'
)
returns public.inventory_movements
language plpgsql
security definer
set search_path = public
as $$
begin
  -- El operario SÍ ejecuta: recibir y retirar físicamente es su trabajo.
  perform public.fn_exigir_rol('OPERARIO', 'SUPERVISOR', 'JEFE');
  return public.fn_ejecutar_movimiento(p_movement_id, public.actor_actual(), p_cantidad_real, p_quality);
end;
$$;

create or replace function public.rechazar_movimiento(
  p_movement_id uuid,
  p_motivo      text default null
)
returns public.inventory_movements
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.fn_exigir_rol('SUPERVISOR', 'JEFE');
  return public.fn_rechazar_movimiento(p_movement_id, public.actor_actual(), p_motivo);
end;
$$;

create or replace function public.revertir_movimiento(
  p_movement_id uuid,
  p_motivo      text
)
returns public.inventory_movements
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.fn_exigir_rol('JEFE');
  return public.fn_revertir_movimiento(p_movement_id, public.actor_actual(), p_motivo);
end;
$$;

create or replace function public.eliminar_articulo(
  p_item_id uuid,
  p_motivo  text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  -- El supervisor puede pedirlo; fn_eliminar_articulo decide si lo ejecuta
  -- directamente (JEFE) o lo encola en approval_requests.
  perform public.fn_exigir_rol('SUPERVISOR', 'JEFE');
  return public.fn_eliminar_articulo(p_item_id, public.actor_actual(), p_motivo);
end;
$$;

create or replace function public.solicitar_aprobacion(
  p_action_type text,
  p_entity_type text,
  p_entity_id   uuid,
  p_reason      text,
  p_payload     jsonb default '{}'::jsonb
)
returns public.approval_requests
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.fn_exigir_rol('OPERARIO', 'SUPERVISOR', 'JEFE');
  return public.fn_solicitar_aprobacion(p_action_type, p_entity_type, p_entity_id,
                                        p_reason, public.actor_actual(), p_payload);
end;
$$;

create or replace function public.resolver_aprobacion(
  p_request_id uuid,
  p_aprobar    boolean,
  p_nota       text default null
)
returns public.approval_requests
language plpgsql
security definer
set search_path = public
as $$
begin
  -- fn_resolver_aprobacion vuelve a comprobar que quien resuelve tenga el rango
  -- que la solicitud exige; aquí solo se descarta de entrada al AUDITOR.
  perform public.fn_exigir_rol('SUPERVISOR', 'JEFE');
  return public.fn_resolver_aprobacion(p_request_id, public.actor_actual(), p_aprobar, p_nota);
end;
$$;

-- Reconocer una alerta: "yo me hago cargo de esto". Se expone como función y no
-- como UPDATE directo porque una política RLS no puede impedir que, de paso, se
-- cambie la severidad o el tipo de la alerta.
create or replace function public.reconocer_alerta(p_alert_id uuid)
returns public.alerts
language plpgsql
security definer
set search_path = public
as $$
declare v_alerta public.alerts;
begin
  perform public.fn_exigir_rol('OPERARIO', 'SUPERVISOR', 'JEFE');
  update public.alerts
     set status = 'RECONOCIDA',
         acknowledged_by = public.actor_actual(),
         acknowledged_at = now()
   where id = p_alert_id
     and status = 'ACTIVA'
  returning * into v_alerta;

  if not found then
    raise exception 'La alerta no existe o ya fue atendida.';
  end if;
  return v_alerta;
end;
$$;


-- =============================================================================
--  BLOQUE C — VISTAS QUE RESPETAN RLS
-- =============================================================================
--  AGUJERO CERRADO: por defecto una vista se ejecuta con los privilegios de su
--  dueño (postgres), que tiene BYPASSRLS. Sin security_invoker, consultar
--  v_stock_actual devolvería TODO aunque las tablas base estén protegidas.
--  Con security_invoker = on, la vista se evalúa con los permisos de quien la
--  consulta y las políticas de las tablas base sí se aplican.

-- security_invoker existe desde PostgreSQL 15. Si la migración corriera en una
-- versión anterior, fallaría justo aquí: con las funciones públicas ya creadas
-- (bloque B) pero antes de activar RLS (bloque D), que es el peor estado
-- posible. Se comprueba antes y se detiene con un mensaje que explica por qué.
do $$
begin
  if current_setting('server_version_num')::integer < 150000 then
    raise exception
      'Esta migración necesita PostgreSQL 15 o superior (detectado %). Sin security_invoker las vistas se ejecutan con los permisos de su dueño y devolverían todas las filas ignorando RLS, así que activar las políticas daría una falsa sensación de seguridad.',
      current_setting('server_version');
  end if;
end;
$$;

alter view public.v_items_detalle       set (security_invoker = on);
alter view public.v_stock_actual        set (security_invoker = on);
alter view public.v_mapa_almacen        set (security_invoker = on);
alter view public.v_alertas_activas     set (security_invoker = on);
alter view public.v_movimientos_vencidos set (security_invoker = on);
alter view public.v_stock_sin_ubicar    set (security_invoker = on);
alter view public.v_movimientos_detalle set (security_invoker = on);

-- RLS filtra FILAS, no COLUMNAS: no existe forma de decir "este rol ve todo
-- menos el costo". La restricción por columna se resuelve con una vista que
-- simplemente no expone precio ni costo, y el frontend consulta esta cuando
-- quien mira es un OPERARIO.
create or replace view public.v_catalogo_operativo
with (security_invoker = on) as
select
  it.id           as item_id,
  it.sku,
  p.model_code,
  p.name          as producto,
  b.name          as marca,
  c.name          as categoria,
  it.size_label   as talla,
  it.uom,
  it.units_per_box,
  it.barcode,
  it.is_active
from public.inventory_items it
join public.products   p on p.id = it.product_id
left join public.brands     b on b.id = p.brand_id
left join public.categories c on c.id = p.category_id
where it.deleted_at is null
  and p.deleted_at is null;   -- dar de baja el modelo debe ocultar sus tallas

comment on view public.v_catalogo_operativo is
  'Catálogo sin precio ni costo, para el rol OPERARIO. RLS no filtra columnas; esta vista es la forma correcta de resolverlo.';


-- =============================================================================
--  BLOQUE D — ACTIVAR RLS EN LAS 21 TABLAS
-- =============================================================================
alter table public.profiles              enable row level security;
alter table public.brands                enable row level security;
alter table public.categories            enable row level security;
alter table public.suppliers             enable row level security;
alter table public.warehouses            enable row level security;
alter table public.racks                 enable row level security;
alter table public.positions             enable row level security;
alter table public.products              enable row level security;
alter table public.inventory_items       enable row level security;
alter table public.inventory             enable row level security;
alter table public.position_assignments  enable row level security;
alter table public.inventory_orders      enable row level security;
alter table public.inventory_movements   enable row level security;
alter table public.stock_ledger          enable row level security;
alter table public.audit_log             enable row level security;
alter table public.alert_rules           enable row level security;
alter table public.alerts                enable row level security;
alter table public.approval_requests     enable row level security;
alter table public.discrepancies         enable row level security;
alter table public.inventory_counts      enable row level security;
alter table public.inventory_count_lines enable row level security;


-- =============================================================================
--  BLOQUE E — POLÍTICAS
-- =============================================================================
-- Regla transversal: NINGUNA tabla tiene política de DELETE. En este sistema
-- nada se borra físicamente desde la aplicación — los maestros usan deleted_at
-- y los movimientos se anulan con un contra-asiento. Sin política de DELETE,
-- el DELETE queda prohibido para todos, incluido el JEFE.

-- -----------------------------------------------------------------------------
-- E.1 profiles — todos ven quién es quién; solo el jefe administra
-- -----------------------------------------------------------------------------
-- El SELECT abierto es necesario: el dashboard muestra "aprobado por Ana Jefa"
-- y necesita resolver el nombre. No hay datos sensibles más allá del correo.
drop policy if exists p_profiles_select on public.profiles;
create policy p_profiles_select on public.profiles
  for select to authenticated
  using ((select public.fn_rol_actual()) is not null);

drop policy if exists p_profiles_insert on public.profiles;
create policy p_profiles_insert on public.profiles
  for insert to authenticated
  with check ((select public.fn_es_jefe()));

-- El jefe administra a todos; cualquiera puede corregir su propio nombre.
-- Nota: RLS no impide que, al editar su fila, un usuario se cambie el `role`.
-- Eso lo bloquea el trigger trg_profiles_no_autoascenso, más abajo.
drop policy if exists p_profiles_update on public.profiles;
create policy p_profiles_update on public.profiles
  for update to authenticated
  using ((select public.fn_es_jefe()) or id = (select auth.uid()))
  with check ((select public.fn_es_jefe()) or id = (select auth.uid()));

-- -----------------------------------------------------------------------------
-- E.2 Catálogos: marcas, categorías, proveedores
-- -----------------------------------------------------------------------------
drop policy if exists p_brands_select on public.brands;
create policy p_brands_select on public.brands
  for select to authenticated using ((select public.fn_rol_actual()) is not null);
drop policy if exists p_brands_write on public.brands;
create policy p_brands_write on public.brands
  for insert to authenticated with check ((select public.fn_es_al_menos_supervisor()));
drop policy if exists p_brands_update on public.brands;
create policy p_brands_update on public.brands
  for update to authenticated
  using ((select public.fn_es_al_menos_supervisor()))
  with check ((select public.fn_es_al_menos_supervisor()));

drop policy if exists p_categories_select on public.categories;
create policy p_categories_select on public.categories
  for select to authenticated using ((select public.fn_rol_actual()) is not null);
drop policy if exists p_categories_write on public.categories;
create policy p_categories_write on public.categories
  for insert to authenticated with check ((select public.fn_es_al_menos_supervisor()));
drop policy if exists p_categories_update on public.categories;
create policy p_categories_update on public.categories
  for update to authenticated
  using ((select public.fn_es_al_menos_supervisor()))
  with check ((select public.fn_es_al_menos_supervisor()));

drop policy if exists p_suppliers_select on public.suppliers;
create policy p_suppliers_select on public.suppliers
  for select to authenticated using ((select public.fn_rol_actual()) is not null);
drop policy if exists p_suppliers_write on public.suppliers;
create policy p_suppliers_write on public.suppliers
  for insert to authenticated with check ((select public.fn_es_al_menos_supervisor()));
drop policy if exists p_suppliers_update on public.suppliers;
create policy p_suppliers_update on public.suppliers
  for update to authenticated
  using ((select public.fn_es_al_menos_supervisor()))
  with check ((select public.fn_es_al_menos_supervisor()));

-- -----------------------------------------------------------------------------
-- E.3 Mapa del almacén: warehouses, racks, positions
-- -----------------------------------------------------------------------------
-- El operario necesita LEER el mapa (tiene que saber dónde ubicar), pero no
-- redefinir la topología del almacén.
drop policy if exists p_warehouses_select on public.warehouses;
create policy p_warehouses_select on public.warehouses
  for select to authenticated using ((select public.fn_rol_actual()) is not null);
drop policy if exists p_warehouses_write on public.warehouses;
create policy p_warehouses_write on public.warehouses
  for insert to authenticated with check ((select public.fn_es_al_menos_supervisor()));
drop policy if exists p_warehouses_update on public.warehouses;
create policy p_warehouses_update on public.warehouses
  for update to authenticated
  using ((select public.fn_es_al_menos_supervisor()))
  with check ((select public.fn_es_al_menos_supervisor()));

drop policy if exists p_racks_select on public.racks;
create policy p_racks_select on public.racks
  for select to authenticated using ((select public.fn_rol_actual()) is not null);
drop policy if exists p_racks_write on public.racks;
create policy p_racks_write on public.racks
  for insert to authenticated with check ((select public.fn_es_al_menos_supervisor()));
drop policy if exists p_racks_update on public.racks;
create policy p_racks_update on public.racks
  for update to authenticated
  using ((select public.fn_es_al_menos_supervisor()))
  with check ((select public.fn_es_al_menos_supervisor()));

drop policy if exists p_positions_select on public.positions;
create policy p_positions_select on public.positions
  for select to authenticated using ((select public.fn_rol_actual()) is not null);
drop policy if exists p_positions_write on public.positions;
create policy p_positions_write on public.positions
  for insert to authenticated with check ((select public.fn_es_al_menos_supervisor()));
drop policy if exists p_positions_update on public.positions;
create policy p_positions_update on public.positions
  for update to authenticated
  using ((select public.fn_es_al_menos_supervisor()))
  with check ((select public.fn_es_al_menos_supervisor()));

-- -----------------------------------------------------------------------------
-- E.4 Maestro de productos y artículos
-- -----------------------------------------------------------------------------
-- El OPERARIO ve el catálogo completo aquí, incluidos precio y costo. Para
-- ocultárselos, el frontend debe consultar v_catalogo_operativo en vez de la
-- tabla. Se documenta como decisión consciente: cerrar el SELECT de la tabla
-- al operario le impediría también ver el nombre del producto que va a mover.
-- La papelera no es visible para el trabajo diario: un producto con deleted_at
-- no debe aparecer en buscadores ni selectores. Solo JEFE (que puede restaurar)
-- y AUDITOR (que revisa el histórico) ven lo eliminado. Sin este filtro, el
-- borrado lógico dependería de que cada consulta del frontend se acuerde de
-- excluirlo, y bastaría una que lo olvide para anular el control.
drop policy if exists p_products_select on public.products;
create policy p_products_select on public.products
  for select to authenticated
  using (
    (select public.fn_rol_actual()) is not null
    and (deleted_at is null or (select public.fn_rol_actual()) in ('JEFE', 'AUDITOR'))
  );
drop policy if exists p_products_write on public.products;
create policy p_products_write on public.products
  for insert to authenticated with check ((select public.fn_es_al_menos_supervisor()));
drop policy if exists p_products_update on public.products;
create policy p_products_update on public.products
  for update to authenticated
  using ((select public.fn_es_al_menos_supervisor()))
  with check ((select public.fn_es_al_menos_supervisor()));

drop policy if exists p_items_select on public.inventory_items;
create policy p_items_select on public.inventory_items
  for select to authenticated
  using (
    (select public.fn_rol_actual()) is not null
    and (deleted_at is null or (select public.fn_rol_actual()) in ('JEFE', 'AUDITOR'))
  );
drop policy if exists p_items_write on public.inventory_items;
create policy p_items_write on public.inventory_items
  for insert to authenticated with check ((select public.fn_es_al_menos_supervisor()));
drop policy if exists p_items_update on public.inventory_items;
create policy p_items_update on public.inventory_items
  for update to authenticated
  using ((select public.fn_es_al_menos_supervisor()))
  with check ((select public.fn_es_al_menos_supervisor()));

-- -----------------------------------------------------------------------------
-- E.5 inventory — SOLO LECTURA PARA TODOS
-- -----------------------------------------------------------------------------
-- La decisión de seguridad más importante del archivo: el saldo de stock NO
-- tiene política de INSERT ni de UPDATE. Ni el jefe puede tocarlo directamente.
-- La única forma de mover stock es el workflow (aprobar -> ejecutar), que corre
-- dentro de funciones SECURITY DEFINER y deja asiento en stock_ledger.
-- Un UPDATE suelto sobre esta tabla es exactamente lo que hace imposible
-- auditar un inventario, así que se prohíbe de raíz.
drop policy if exists p_inventory_select on public.inventory;
create policy p_inventory_select on public.inventory
  for select to authenticated
  using ((select public.fn_rol_actual()) is not null);

-- -----------------------------------------------------------------------------
-- E.6 position_assignments — el operario ubica y retira
-- -----------------------------------------------------------------------------
-- Aquí sí escribe el OPERARIO: ubicar físicamente la mercadería es su trabajo.
drop policy if exists p_assign_select on public.position_assignments;
create policy p_assign_select on public.position_assignments
  for select to authenticated using ((select public.fn_rol_actual()) is not null);
drop policy if exists p_assign_insert on public.position_assignments;
create policy p_assign_insert on public.position_assignments
  for insert to authenticated
  with check ((select public.fn_rol_actual()) in ('OPERARIO', 'SUPERVISOR', 'JEFE'));
drop policy if exists p_assign_update on public.position_assignments;
create policy p_assign_update on public.position_assignments
  for update to authenticated
  using ((select public.fn_rol_actual()) in ('OPERARIO', 'SUPERVISOR', 'JEFE'))
  with check ((select public.fn_rol_actual()) in ('OPERARIO', 'SUPERVISOR', 'JEFE'));

-- -----------------------------------------------------------------------------
-- E.7 inventory_orders — las crea el equipo logístico
-- -----------------------------------------------------------------------------
drop policy if exists p_orders_select on public.inventory_orders;
create policy p_orders_select on public.inventory_orders
  for select to authenticated using ((select public.fn_rol_actual()) is not null);
drop policy if exists p_orders_insert on public.inventory_orders;
create policy p_orders_insert on public.inventory_orders
  for insert to authenticated
  with check ((select public.fn_es_al_menos_supervisor()) and created_by = (select auth.uid()));
drop policy if exists p_orders_update on public.inventory_orders;
create policy p_orders_update on public.inventory_orders
  for update to authenticated
  using ((select public.fn_es_al_menos_supervisor()))
  with check ((select public.fn_es_al_menos_supervisor()));

-- -----------------------------------------------------------------------------
-- E.8 inventory_movements — se crean desde el cliente, se resuelven por RPC
-- -----------------------------------------------------------------------------
-- INSERT sí (un supervisor registra la intención de mover), pero NO hay
-- política de UPDATE: aprobar, rechazar, ejecutar y revertir pasan
-- obligatoriamente por las funciones, que son las que validan segregación de
-- funciones, límites por rol y disponibilidad de stock. Si existiera un UPDATE
-- abierto, bastaría con `update ... set status = 'APROBADO'` para saltarse todo
-- el control interno.
--
-- `created_by = auth.uid()` en el WITH CHECK impide crear un movimiento a
-- nombre de otra persona, que es el primer paso para evadir la segregación.
drop policy if exists p_mov_select on public.inventory_movements;
create policy p_mov_select on public.inventory_movements
  for select to authenticated using ((select public.fn_rol_actual()) is not null);
drop policy if exists p_mov_insert on public.inventory_movements;
create policy p_mov_insert on public.inventory_movements
  for insert to authenticated
  with check (
    (select public.fn_es_al_menos_supervisor())
    and created_by = (select auth.uid())
    and status = 'PENDIENTE'          -- nace pendiente, siempre
    and executed_at is null
    and approved_by is null
    and reversal_of_id is null        -- una reversión solo la emite la RPC
  );

-- -----------------------------------------------------------------------------
-- E.9 stock_ledger — append-only, y ni siquiera se puede append desde el cliente
-- -----------------------------------------------------------------------------
-- Solo lectura. Los asientos los escribe fn_ejecutar_movimiento. Sin política
-- de INSERT/UPDATE, el kardex es inmutable desde la aplicación: es lo que
-- permite afirmar que el histórico no fue manipulado.
drop policy if exists p_ledger_select on public.stock_ledger;
create policy p_ledger_select on public.stock_ledger
  for select to authenticated using ((select public.fn_rol_actual()) is not null);

-- -----------------------------------------------------------------------------
-- E.10 audit_log — solo jefe y auditor
-- -----------------------------------------------------------------------------
-- Quien puede ser auditado no debería poder leer (ni menos escribir) la pista
-- de auditoría. Sin política de INSERT: las filas las pone el trigger
-- fn_auditoria, que es SECURITY DEFINER y no pasa por RLS.
drop policy if exists p_audit_select on public.audit_log;
create policy p_audit_select on public.audit_log
  for select to authenticated
  using ((select public.fn_rol_actual()) in ('JEFE', 'AUDITOR'));

-- -----------------------------------------------------------------------------
-- E.11 alerts / alert_rules
-- -----------------------------------------------------------------------------
-- Las alertas las ve todo el mundo (para eso existen) pero no se editan a mano:
-- reconocerlas pasa por reconocer_alerta(). Sin política de UPDATE, un usuario
-- no puede silenciar una alerta crítica cambiándole la severidad.
drop policy if exists p_alerts_select on public.alerts;
create policy p_alerts_select on public.alerts
  for select to authenticated using ((select public.fn_rol_actual()) is not null);

drop policy if exists p_alert_rules_select on public.alert_rules;
create policy p_alert_rules_select on public.alert_rules
  for select to authenticated using ((select public.fn_rol_actual()) is not null);
drop policy if exists p_alert_rules_update on public.alert_rules;
create policy p_alert_rules_update on public.alert_rules
  for update to authenticated
  using ((select public.fn_es_jefe())) with check ((select public.fn_es_jefe()));
drop policy if exists p_alert_rules_insert on public.alert_rules;
create policy p_alert_rules_insert on public.alert_rules
  for insert to authenticated with check ((select public.fn_es_jefe()));

-- -----------------------------------------------------------------------------
-- E.12 approval_requests — el escalamiento
-- -----------------------------------------------------------------------------
-- Ve la solicitud quien la pidió, más quien tiene que resolverla.
-- Sin política de UPDATE: resolver pasa por resolver_aprobacion(), que valida
-- que quien resuelve no sea quien pidió y que tenga el rango necesario.
drop policy if exists p_approval_select on public.approval_requests;
create policy p_approval_select on public.approval_requests
  for select to authenticated
  using (
    (select public.fn_rol_actual()) in ('JEFE', 'AUDITOR')
    or requested_by = (select auth.uid())
    or (required_role = 'SUPERVISOR' and (select public.fn_es_al_menos_supervisor()))
  );

drop policy if exists p_approval_insert on public.approval_requests;
create policy p_approval_insert on public.approval_requests
  for insert to authenticated
  with check (
    -- AUDITOR excluido: es un rol de solo lectura, no pide autorizaciones.
    (select public.fn_rol_actual()) in ('OPERARIO', 'SUPERVISOR', 'JEFE')
    and requested_by = (select auth.uid())
    and status = 'PENDIENTE'
  );

-- -----------------------------------------------------------------------------
-- E.13 discrepancies — el operario reporta, el supervisor resuelve
-- -----------------------------------------------------------------------------
drop policy if exists p_discrep_select on public.discrepancies;
create policy p_discrep_select on public.discrepancies
  for select to authenticated using ((select public.fn_rol_actual()) is not null);
drop policy if exists p_discrep_insert on public.discrepancies;
create policy p_discrep_insert on public.discrepancies
  for insert to authenticated
  with check (
    (select public.fn_rol_actual()) in ('OPERARIO', 'SUPERVISOR', 'JEFE')
    and reported_by = (select auth.uid())
  );
drop policy if exists p_discrep_update on public.discrepancies;
create policy p_discrep_update on public.discrepancies
  for update to authenticated
  using ((select public.fn_es_al_menos_supervisor()))
  with check ((select public.fn_es_al_menos_supervisor()));

-- -----------------------------------------------------------------------------
-- E.14 Conteo cíclico — el operario cuenta, el supervisor abre y cierra
-- -----------------------------------------------------------------------------
drop policy if exists p_counts_select on public.inventory_counts;
create policy p_counts_select on public.inventory_counts
  for select to authenticated using ((select public.fn_rol_actual()) is not null);
drop policy if exists p_counts_insert on public.inventory_counts;
create policy p_counts_insert on public.inventory_counts
  for insert to authenticated with check ((select public.fn_es_al_menos_supervisor()));
drop policy if exists p_counts_update on public.inventory_counts;
create policy p_counts_update on public.inventory_counts
  for update to authenticated
  using ((select public.fn_es_al_menos_supervisor()))
  with check ((select public.fn_es_al_menos_supervisor()));

-- Las líneas sí las escribe el operario: contar es su trabajo.
drop policy if exists p_count_lines_select on public.inventory_count_lines;
create policy p_count_lines_select on public.inventory_count_lines
  for select to authenticated using ((select public.fn_rol_actual()) is not null);
drop policy if exists p_count_lines_insert on public.inventory_count_lines;
create policy p_count_lines_insert on public.inventory_count_lines
  for insert to authenticated
  with check ((select public.fn_rol_actual()) in ('OPERARIO', 'SUPERVISOR', 'JEFE'));
drop policy if exists p_count_lines_update on public.inventory_count_lines;
create policy p_count_lines_update on public.inventory_count_lines
  for update to authenticated
  using ((select public.fn_rol_actual()) in ('OPERARIO', 'SUPERVISOR', 'JEFE'))
  with check ((select public.fn_rol_actual()) in ('OPERARIO', 'SUPERVISOR', 'JEFE'));


-- =============================================================================
--  BLOQUE F — LO QUE RLS NO PUEDE HACER: TRIGGERS COMPLEMENTARIOS
-- =============================================================================

-- Una política UPDATE no puede comparar el valor viejo con el nuevo (USING ve
-- OLD, WITH CHECK ve NEW, pero no hay forma de relacionarlos). Sin este
-- trigger, la política que deja a cada usuario editar su propia fila de
-- profiles le permitiría también ascenderse a JEFE.
create or replace function public.fn_no_autoascenso()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- El rol postgres (SQL Editor, seed, migraciones) no pasa por esta validación.
  if auth.uid() is null then
    return new;
  end if;

  if new.role is distinct from old.role and public.fn_rol_actual() is distinct from 'JEFE' then
    raise exception 'No puedes cambiar tu propio rol. Solo un jefe asigna roles.'
      using errcode = 'insufficient_privilege';
  end if;

  if new.max_movement_qty is distinct from old.max_movement_qty
     and public.fn_rol_actual() is distinct from 'JEFE' then
    raise exception 'Solo un jefe modifica los límites de aprobación.'
      using errcode = 'insufficient_privilege';
  end if;

  if new.is_active is distinct from old.is_active
     and public.fn_rol_actual() is distinct from 'JEFE' then
    raise exception 'Solo un jefe activa o desactiva usuarios.'
      using errcode = 'insufficient_privilege';
  end if;

  -- El correo identifica a la persona en el dashboard y es lo que se usa para
  -- promover al primer jefe desde el SQL Editor. Dejarlo editable permitiría
  -- que alguien se ponga el correo de otro y termine promovido por error.
  if new.email is distinct from old.email
     and public.fn_rol_actual() is distinct from 'JEFE' then
    raise exception 'El correo lo administra el jefe de almacén.'
      using errcode = 'insufficient_privilege';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_profiles_no_autoascenso on public.profiles;
create trigger trg_profiles_no_autoascenso
  before update on public.profiles
  for each row execute function public.fn_no_autoascenso();


-- =============================================================================
--  BLOQUE G — PERMISOS DE ROL (defensa en profundidad, antes de RLS)
-- =============================================================================
-- RLS filtra filas, pero solo si el rol de Postgres tiene permiso sobre la
-- tabla. Estos GRANT/REVOKE son la capa previa: aunque una política quedara mal
-- escrita, el permiso de rol sigue bloqueando lo que no corresponde.

-- Nadie sin autenticar toca nada. El dashboard exige sesión.
revoke all on all tables    in schema public from anon;
revoke all on all functions in schema public from anon;
revoke all on all sequences in schema public from anon;

-- DELETE prohibido globalmente: coherente con "aquí nada se borra físicamente".
-- Es también la red de seguridad por si alguien agregara una política de DELETE
-- por descuido en el futuro.
revoke delete on all tables in schema public from authenticated;

-- Denegar por defecto y conceder solo lo necesario: el cliente NO debe poder
-- llamar las fn_* internas, que aceptan p_user_id y permitirían suplantación.
revoke execute on all functions in schema public from authenticated;

grant execute on function public.fn_rol_actual()                to authenticated;
grant execute on function public.fn_es_al_menos_supervisor()    to authenticated;
grant execute on function public.fn_es_jefe()                   to authenticated;
grant execute on function public.actor_actual()                 to authenticated;

grant execute on function public.aprobar_movimiento(uuid)                       to authenticated;
grant execute on function public.ejecutar_movimiento(uuid, integer, text)       to authenticated;
grant execute on function public.rechazar_movimiento(uuid, text)                to authenticated;
grant execute on function public.revertir_movimiento(uuid, text)                to authenticated;
grant execute on function public.eliminar_articulo(uuid, text)                  to authenticated;
grant execute on function public.solicitar_aprobacion(text, text, uuid, text, jsonb) to authenticated;
grant execute on function public.resolver_aprobacion(uuid, boolean, text)       to authenticated;
grant execute on function public.reconocer_alerta(uuid)                         to authenticated;

grant select on public.v_catalogo_operativo to authenticated;

-- El revoke masivo de arriba es deliberadamente amplio, pero puede alcanzar
-- funciones de extensión que sí hacen falta. gen_random_uuid() es el DEFAULT del
-- id de casi todas las tablas: si pgcrypto quedó instalada en `public` (la
-- migración 01 la crea sin cláusula SCHEMA), sin este grant todo INSERT hecho
-- por un usuario autenticado fallaría con 'permission denied for function'.
-- Se re-concede solo si efectivamente vive en public.
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as firma
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('gen_random_uuid', 'digest', 'crypt', 'gen_salt')
  loop
    execute format('grant execute on function %s to authenticated', r.firma);
  end loop;
end;
$$;


-- =============================================================================
--  BLOQUE H — VÍNCULO CON SUPABASE AUTH
-- =============================================================================
-- AGUJERO CERRADO (parcialmente): profiles.id debe ser el mismo UUID que
-- auth.users.id, o auth.uid() nunca encontrará un perfil y RLS bloqueará todo.
--
-- No se activa la FK a auth.users porque los perfiles del smoke test
-- (11111111-…, 22222222-…) no existen en auth.users y el ALTER fallaría.
-- En su lugar se auto-crea el perfil cuando alguien se registra, que es el
-- patrón estándar de Supabase.
--
-- El primer usuario debe promoverse a JEFE manualmente desde el SQL Editor:
--    update public.profiles set role = 'JEFE' where email = 'tu@correo.com';
-- Es deliberado: si el registro público pudiera crear jefes, cualquiera con el
-- enlace de sign-up se haría administrador del almacén.
create or replace function public.fn_crear_perfil_nuevo_usuario()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, email, role)
  values (
    new.id,
    -- El último fallback no es cosmético: full_name es NOT NULL con CHECK de
    -- longitud, y un alta por teléfono o por un proveedor OAuth que no devuelva
    -- correo dejaría los dos primeros en NULL. Como el trigger corre en la
    -- transacción del alta, ese fallo abortaría el registro entero.
    coalesce(
      nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''),
      nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
      'Usuario ' || left(new.id::text, 8)
    ),
    new.email,
    'OPERARIO'          -- el rol mínimo, siempre
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

do $$
begin
  drop trigger if exists trg_auth_user_creado on auth.users;
  create trigger trg_auth_user_creado
    after insert on auth.users
    for each row execute function public.fn_crear_perfil_nuevo_usuario();
exception when insufficient_privilege or undefined_table then
  raise notice 'No se pudo crear el trigger sobre auth.users (permisos o esquema ausente). Crea los perfiles manualmente con el mismo id de auth.users.';
end;
$$;


-- =============================================================================
--  NOTAS PARA LA SUSTENTACIÓN
-- =============================================================================
--  1. ¿Por qué el stock no tiene política de escritura?
--     Porque un UPDATE directo sobre `inventory` es indistinguible de un fraude.
--     Toda variación de saldo pasa por el workflow y queda con asiento en
--     stock_ledger, autor y motivo.
--
--  2. ¿Por qué hay funciones `fn_*` y otras sin prefijo?
--     Las fn_* reciben el usuario como parámetro y son de uso administrativo;
--     están revocadas para el cliente. Las públicas derivan el usuario de
--     auth.uid(), así que nadie puede operar en nombre de otro.
--
--  3. ¿Por qué ninguna tabla permite DELETE?
--     Maestros con deleted_at, movimientos con contra-asiento, kardex y
--     auditoría append-only. El DELETE está revocado a nivel de rol además de
--     no tener política.
--
--  4. ¿Cómo se prueba todo esto?
--     tests/02_rls_test.sql simula usuarios reales con set_config sobre
--     request.jwt.claims y verifica que cada rol pueda hacer exactamente lo que
--     le corresponde, y nada más.
-- =============================================================================
