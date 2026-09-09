-- =============================================================================
--  MIGRACIÓN 02 — CONTROL OPERATIVO Y ERROR HUMANO
--
--  Origen: docs/ANALISIS-OPERATIVO.md (40 modos de fallo catalogados).
--  Implementa las tres capas de defensa:
--     CAPA 1 PREVENIR  -> constraints, segregación de funciones, idempotencia,
--                         límites por rol, validación de capacidad
--     CAPA 2 DETECTAR  -> alertas con severidad, reglas configurables
--     CAPA 3 CORREGIR  -> reversión por contra-asiento, papelera, auditoría,
--                         aprobaciones escaladas, conteo cíclico
--
--  Requiere 01_schema_base.sql. Idempotente: se puede re-ejecutar.
-- =============================================================================


-- =============================================================================
--  BLOQUE A — CORRECCIONES AL ESQUEMA BASE
-- =============================================================================

-- -----------------------------------------------------------------------------
-- A.1 profiles: 4 roles reales + límite de autorización por persona
-- -----------------------------------------------------------------------------
-- El CASO nombra dos actores, pero una operación real tiene cuatro niveles de
-- responsabilidad. Sin esta distinción no se puede expresar "esto lo aprueba
-- alguien de arriba", que es el control que pidió el negocio.
alter table public.profiles drop constraint if exists profiles_role_check;

update public.profiles
   set role = case role
                when 'ALMACEN'   then 'OPERARIO'
                when 'LOGISTICA' then 'SUPERVISOR'
                when 'ADMIN'     then 'JEFE'
                else role
              end
 where role in ('ALMACEN', 'LOGISTICA', 'ADMIN');

alter table public.profiles
  alter column role set default 'OPERARIO',
  add constraint profiles_role_check
      check (role in ('OPERARIO', 'SUPERVISOR', 'JEFE', 'AUDITOR'));

-- Techo de autorización individual: cuánto puede aprobar esta persona sin que
-- la operación escale a un rol superior. NULL = sin techo (JEFE).
alter table public.profiles
  add column if not exists max_movement_qty integer
      check (max_movement_qty is null or max_movement_qty > 0);

comment on column public.profiles.max_movement_qty is
  'Cantidad máxima que puede aprobar sin escalar. NULL = sin límite. Ataca E-34 (escalamiento de privilegios).';

-- -----------------------------------------------------------------------------
-- A.2 inventory_movements: dirección, idempotencia, reversión, calidad
-- -----------------------------------------------------------------------------
alter table public.inventory_movements
  -- BUG CORREGIDO: un AJUSTE solo podía sumar (quantity > 0 y la RPC siempre
  -- sumaba). Era imposible corregir un conteo físico a la baja, que es
  -- justamente el caso de error humano más común (E-16).
  add column if not exists direction smallint not null default 1,

  -- Cantidad que se ESPERABA mover, contra la que realmente se movió.
  -- La diferencia genera una discrepancia (E-01, E-02, E-18).
  add column if not exists expected_quantity integer
      check (expected_quantity is null or expected_quantity > 0),

  -- Antídoto del doble clic y de la doble recepción por dos operarios
  -- (E-06, E-25). El cliente genera una clave por intento de operación.
  add column if not exists idempotency_key text,

  -- Contra-asiento: enlaza esta reversión con el movimiento que anula (§6).
  add column if not exists reversal_of_id uuid
      references public.inventory_movements (id) on delete restrict,

  -- Mercadería que llega dañada no puede sumar al stock vendible (E-05).
  add column if not exists quality_status text not null default 'BUENO',

  -- Bloqueo optimista contra edición concurrente (E-35).
  add column if not exists version integer not null default 1;

-- Las SALIDAS ya existentes quedarían con direction = 1 (el default) y violarían
-- el CHECK que se agrega abajo. Se corrigen antes de imponerlo.
update public.inventory_movements set direction = -1
 where movement_type = 'SALIDA' and direction <> -1;
update public.inventory_movements set direction = 1
 where movement_type = 'ENTRADA' and direction <> 1;

alter table public.inventory_movements
  drop constraint if exists ck_mov_direction,
  drop constraint if exists ck_mov_quality,
  drop constraint if exists ck_mov_segregacion;

alter table public.inventory_movements
  -- El signo lo fija el tipo, salvo en AJUSTE donde el operador lo declara.
  add constraint ck_mov_direction check (
        (movement_type = 'ENTRADA' and direction =  1)
     or (movement_type = 'SALIDA'  and direction = -1)
     or (movement_type = 'AJUSTE'  and direction in (-1, 1))
  ),
  add constraint ck_mov_quality check (
    quality_status in ('BUENO', 'DANADO', 'CUARENTENA')
  ),
  -- SEGREGACIÓN DE FUNCIONES: quien crea no puede aprobar. Control interno
  -- básico que el esquema base no impedía (E-30).
  -- Excepción explícita: una reversión la emite y autoriza el mismo jefe, porque
  -- es una corrección de excepción que ya quedó atribuida y auditada.
  add constraint ck_mov_segregacion check (
    reversal_of_id is not null
    or approved_by is null or created_by is null or approved_by <> created_by
  );

-- Un movimiento solo puede revertirse UNA vez.
create unique index if not exists ux_mov_reversal_unica
  on public.inventory_movements (reversal_of_id)
  where reversal_of_id is not null;

-- Idempotencia real: dos intentos con la misma clave no crean dos movimientos.
create unique index if not exists ux_mov_idempotency
  on public.inventory_movements (idempotency_key)
  where idempotency_key is not null;

comment on column public.inventory_movements.direction is
  'Sentido del movimiento: +1 suma, -1 resta. Permite AJUSTE negativo sin romper quantity > 0.';
comment on column public.inventory_movements.reversal_of_id is
  'Si no es NULL, este movimiento es el contra-asiento que anula al referenciado. El original nunca se edita ni se borra.';

-- -----------------------------------------------------------------------------
-- A.3 inventory: stock no vendible separado del vendible
-- -----------------------------------------------------------------------------
alter table public.inventory
  add column if not exists qty_damaged    integer not null default 0 check (qty_damaged    >= 0),
  add column if not exists qty_quarantine integer not null default 0 check (qty_quarantine >= 0);

comment on column public.inventory.qty_damaged is
  'Recibido con daño. Está en el almacén pero NO es vendible: nunca entra en `quantity` (E-05).';

-- -----------------------------------------------------------------------------
-- A.4 inventory_items / products: papelera en vez de borrado
-- -----------------------------------------------------------------------------
-- Eliminar un artículo con historial rompe el kardex (E-32). Se marca como
-- eliminado, desaparece del dashboard y solo un JEFE puede restaurarlo.
alter table public.inventory_items
  add column if not exists deleted_at timestamptz,
  add column if not exists deleted_by uuid references public.profiles (id) on delete set null,
  add column if not exists uom text not null default 'PAR',
  add column if not exists units_per_box integer check (units_per_box is null or units_per_box > 0),
  add column if not exists version integer not null default 1;

alter table public.inventory_items
  drop constraint if exists ck_items_uom;
alter table public.inventory_items
  -- En calzado se recibe por caja y se vende por par: confundirlos multiplica
  -- el stock por 12 (E-29).
  add constraint ck_items_uom check (uom in ('PAR', 'CAJA', 'UNIDAD'));

alter table public.products
  add column if not exists deleted_at timestamptz,
  add column if not exists deleted_by uuid references public.profiles (id) on delete set null;

-- El dashboard filtra por estas columnas en cada consulta.
create index if not exists ix_items_vivos    on public.inventory_items (id) where deleted_at is null;
create index if not exists ix_products_vivos on public.products        (id) where deleted_at is null;

-- -----------------------------------------------------------------------------
-- A.5 inventory_orders: ejecución parcial y documento de respaldo
-- -----------------------------------------------------------------------------
alter table public.inventory_orders drop constraint if exists inventory_orders_status_check;
alter table public.inventory_orders
  -- Se anunciaron 50 y llegaron 48: la orden no está ni completa ni cancelada (E-23).
  add constraint inventory_orders_status_check check (
    status in ('PENDIENTE', 'APROBADO', 'RECHAZADO', 'EJECUTADO',
               'COMPLETADA_PARCIAL', 'CANCELADO')
  );

alter table public.inventory_orders
  -- En Perú la guía de remisión es obligatoria para trasladar mercadería.
  add column if not exists document_ref text;


-- =============================================================================
--  BLOQUE B — TABLAS NUEVAS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- B.1 audit_log — quién hizo qué, con valor antes y después
-- -----------------------------------------------------------------------------
-- Se alimenta por TRIGGER de base de datos, no desde el frontend: si dependiera
-- del cliente, bastaría con llamar a la API directamente para dejar de auditar.
create table if not exists public.audit_log (
  id          bigserial primary key,
  table_name  text        not null,
  record_id   text        not null,
  action      text        not null check (action in ('INSERT', 'UPDATE', 'DELETE')),
  old_data    jsonb,
  new_data    jsonb,
  changed_by  uuid        references public.profiles (id) on delete set null,
  changed_at  timestamptz not null default now()
);
comment on table public.audit_log is 'Append-only. Responde "quién cambió esto y qué decía antes" (E-38).';

create index if not exists ix_audit_tabla_registro on public.audit_log (table_name, record_id);
create index if not exists ix_audit_fecha          on public.audit_log (changed_at desc);
create index if not exists ix_audit_usuario        on public.audit_log (changed_by);

-- -----------------------------------------------------------------------------
-- B.2 alert_rules — umbrales configurables sin tocar código
-- -----------------------------------------------------------------------------
create table if not exists public.alert_rules (
  id            uuid primary key default gen_random_uuid(),
  alert_type    text        not null unique,
  severity      text        not null check (severity in ('CRITICA', 'ADVERTENCIA', 'INFO')),
  threshold_num numeric,                        -- horas de SLA, % de variación, múltiplo atípico
  is_enabled    boolean     not null default true,
  description   text        not null,
  updated_at    timestamptz not null default now()
);
comment on table public.alert_rules is 'El jefe de almacén cambia un SLA sin desplegar código.';

-- -----------------------------------------------------------------------------
-- B.3 alerts — la alerta como entidad con ciclo de vida y responsable
-- -----------------------------------------------------------------------------
create table if not exists public.alerts (
  id             uuid primary key default gen_random_uuid(),
  alert_type     text        not null,
  severity       text        not null check (severity in ('CRITICA', 'ADVERTENCIA', 'INFO')),
  entity_type    text        not null,          -- 'inventory', 'inventory_movements', 'positions'
  entity_id      uuid,
  title          text        not null,
  detail         text,
  status         text        not null default 'ACTIVA'
                 check (status in ('ACTIVA', 'RECONOCIDA', 'RESUELTA')),
  acknowledged_by uuid       references public.profiles (id) on delete set null,
  acknowledged_at timestamptz,
  resolved_at    timestamptz,
  created_at     timestamptz not null default now(),
  -- Una alerta reconocida exige saber quién se hizo cargo.
  constraint ck_alert_reconocida check (
    (status = 'ACTIVA')
    or (status = 'RECONOCIDA' and acknowledged_by is not null and acknowledged_at is not null)
    or (status = 'RESUELTA'   and resolved_at is not null)
  )
);
comment on table public.alerts is 'Nunca se borra. ACTIVA -> RECONOCIDA (alguien se hace cargo) -> RESUELTA (la condición desapareció).';

-- Evita inundar el panel con la misma alerta repetida para la misma entidad.
create unique index if not exists ux_alerta_activa_unica
  on public.alerts (alert_type, entity_type, entity_id)
  where status = 'ACTIVA';

create index if not exists ix_alerts_status_sev on public.alerts (status, severity);
create index if not exists ix_alerts_created    on public.alerts (created_at desc);

-- -----------------------------------------------------------------------------
-- B.4 approval_requests — confirmación "de arriba" (maker-checker)
-- -----------------------------------------------------------------------------
-- Una acción sensible NO se ejecuta: se encola aquí y un rol superior la
-- resuelve. El payload guarda lo necesario para ejecutarla al aprobar.
create table if not exists public.approval_requests (
  id            uuid primary key default gen_random_uuid(),
  action_type   text        not null check (action_type in (
                  'ELIMINAR_ARTICULO', 'REVERTIR_MOVIMIENTO', 'AJUSTE_INVENTARIO',
                  'CANTIDAD_ATIPICA', 'SOBRANTE_RECEPCION', 'CAMBIO_PRECIO',
                  'RESTAURAR_REGISTRO')),
  entity_type   text        not null,
  entity_id     uuid,
  payload       jsonb       not null default '{}'::jsonb,
  reason        text        not null check (length(btrim(reason)) > 0),
  required_role text        not null default 'JEFE' check (required_role in ('SUPERVISOR', 'JEFE')),
  status        text        not null default 'PENDIENTE'
                check (status in ('PENDIENTE', 'APROBADA', 'RECHAZADA')),
  requested_by  uuid        references public.profiles (id) on delete set null,
  resolved_by   uuid        references public.profiles (id) on delete set null,
  resolution_note text,
  created_at    timestamptz not null default now(),
  resolved_at   timestamptz,
  -- Misma segregación que en los movimientos: nadie aprueba su propia solicitud.
  constraint ck_approval_segregacion check (
    resolved_by is null or requested_by is null or resolved_by <> requested_by
  ),
  constraint ck_approval_resuelta check (
    (status = 'PENDIENTE' and resolved_at is null)
    or (status <> 'PENDIENTE' and resolved_at is not null and resolved_by is not null)
  )
);
comment on table public.approval_requests is 'Motivo obligatorio: una autorización sin justificación no es auditable (E-40).';

create index if not exists ix_approval_pendientes on public.approval_requests (required_role, created_at)
  where status = 'PENDIENTE';

-- -----------------------------------------------------------------------------
-- B.5 discrepancies — lo esperado contra lo que realmente pasó
-- -----------------------------------------------------------------------------
create table if not exists public.discrepancies (
  id            uuid primary key default gen_random_uuid(),
  movement_id   uuid        references public.inventory_movements (id) on delete set null,
  order_id      uuid        references public.inventory_orders (id)    on delete set null,
  item_id       uuid        not null references public.inventory_items (id) on delete restrict,
  discrepancy_type text     not null check (discrepancy_type in (
                    'FALTANTE', 'SOBRANTE', 'SKU_INCORRECTO', 'DANADO', 'POSICION_INCORRECTA')),
  expected_qty  integer,
  actual_qty    integer,
  qty_diff      integer,
  detail        text,
  status        text        not null default 'ABIERTA'
                check (status in ('ABIERTA', 'EN_REVISION', 'RESUELTA')),
  reported_by   uuid        references public.profiles (id) on delete set null,
  resolved_by   uuid        references public.profiles (id) on delete set null,
  resolution    text,
  created_at    timestamptz not null default now(),
  resolved_at   timestamptz
);
comment on table public.discrepancies is 'El proveedor anunció 50 y entregó 48: la diferencia se registra, no se disimula (E-01/E-02).';

create index if not exists ix_discrep_abiertas on public.discrepancies (status, created_at desc);
create index if not exists ix_discrep_item     on public.discrepancies (item_id);

-- -----------------------------------------------------------------------------
-- B.6 inventory_counts — conteo cíclico: cuadrar sistema contra físico
-- -----------------------------------------------------------------------------
create table if not exists public.inventory_counts (
  id           uuid primary key default gen_random_uuid(),
  warehouse_id uuid        not null references public.warehouses (id) on delete restrict,
  rack_id      uuid        references public.racks (id) on delete set null,   -- NULL = almacén completo
  status       text        not null default 'ABIERTO'
               check (status in ('ABIERTO', 'CONTADO', 'AJUSTADO', 'CANCELADO')),
  counted_by   uuid        references public.profiles (id) on delete set null,
  approved_by  uuid        references public.profiles (id) on delete set null,
  notes        text,
  created_at   timestamptz not null default now(),
  counted_at   timestamptz,
  approved_at  timestamptz
);

create table if not exists public.inventory_count_lines (
  id           uuid primary key default gen_random_uuid(),
  count_id     uuid        not null references public.inventory_counts (id) on delete cascade,
  item_id      uuid        not null references public.inventory_items (id) on delete restrict,
  position_id  uuid        references public.positions (id) on delete set null,
  qty_system   integer     not null check (qty_system >= 0),   -- foto del saldo al momento del conteo
  qty_physical integer     check (qty_physical is null or qty_physical >= 0),
  qty_diff     integer generated always as (coalesce(qty_physical, 0) - qty_system) stored,
  movement_id  uuid        references public.inventory_movements (id) on delete set null,
  notes        text,
  constraint uq_count_line unique (count_id, item_id, position_id)
);
comment on column public.inventory_count_lines.movement_id is
  'AJUSTE generado al aprobar la diferencia. Trazabilidad: de la diferencia física al asiento del kardex.';

create index if not exists ix_count_lines_count on public.inventory_count_lines (count_id);


-- =============================================================================
--  BLOQUE C — CAPA 1: PREVENIR
-- =============================================================================

-- -----------------------------------------------------------------------------
-- C.1 Derivar `direction` del tipo de movimiento
-- -----------------------------------------------------------------------------
-- Así el frontend no tiene que acordarse de mandar -1 en una SALIDA: si se
-- equivoca, el signo lo corrige la base de datos.
create or replace function public.fn_derivar_direction()
returns trigger
language plpgsql
as $$
begin
  if new.movement_type = 'ENTRADA' then
    new.direction := 1;
  elsif new.movement_type = 'SALIDA' then
    new.direction := -1;
  end if;   -- AJUSTE conserva el valor declarado por el operador
  return new;
end;
$$;

drop trigger if exists trg_mov_direction on public.inventory_movements;
create trigger trg_mov_direction
  before insert or update of movement_type on public.inventory_movements
  for each row execute function public.fn_derivar_direction();

-- -----------------------------------------------------------------------------
-- C.2 Capacidad de la posición
-- -----------------------------------------------------------------------------
-- BUG CORREGIDO: `positions.capacity_units` existía pero nadie lo validaba;
-- se podían asignar 500 pares a un slot con capacidad para 50 (E-12).
create or replace function public.fn_validar_capacidad_posicion()
returns trigger
language plpgsql
as $$
declare
  v_capacidad integer;
  v_ocupado   integer;
begin
  if new.status = 'LIBERADA' then
    return new;
  end if;

  select capacity_units into v_capacidad
    from public.positions where id = new.position_id;

  -- 0 = sin límite declarado
  if coalesce(v_capacidad, 0) = 0 then
    return new;
  end if;

  select coalesce(sum(quantity), 0) into v_ocupado
    from public.position_assignments
   where position_id = new.position_id
     and status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
     and id <> coalesce(new.id, '00000000-0000-0000-0000-000000000000'::uuid);

  if v_ocupado + new.quantity > v_capacidad then
    raise exception 'La posición no tiene espacio: capacidad %, ya ocupadas %, se intenta agregar %',
      v_capacidad, v_ocupado, new.quantity
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_assign_capacidad on public.position_assignments;
create trigger trg_assign_capacidad
  before insert or update on public.position_assignments
  for each row execute function public.fn_validar_capacidad_posicion();

-- -----------------------------------------------------------------------------
-- C.3 Inmutabilidad de lo ya ejecutado
-- -----------------------------------------------------------------------------
-- Un movimiento ejecutado es un hecho consumado: se corrige con una reversión,
-- nunca editándolo (E-33). Solo se permite anotar observaciones.
create or replace function public.fn_bloquear_edicion_ejecutado()
returns trigger
language plpgsql
as $$
begin
  if old.executed_at is not null then
    if new.item_id       is distinct from old.item_id
    or new.quantity      is distinct from old.quantity
    or new.movement_type is distinct from old.movement_type
    or new.direction     is distinct from old.direction
    or new.status        is distinct from old.status
    or new.executed_at   is distinct from old.executed_at
    or new.inventory_id  is distinct from old.inventory_id then
      raise exception 'El movimiento % ya fue ejecutado y no puede modificarse. Para corregirlo, emite una reversión.', old.id
        using errcode = 'check_violation';
    end if;
  end if;
  new.version := old.version + 1;
  return new;
end;
$$;

drop trigger if exists trg_mov_inmutable on public.inventory_movements;
create trigger trg_mov_inmutable
  before update on public.inventory_movements
  for each row execute function public.fn_bloquear_edicion_ejecutado();

-- -----------------------------------------------------------------------------
-- C.4 Bloqueo optimista en artículos
-- -----------------------------------------------------------------------------
-- Dos supervisores editando el mismo artículo: el segundo ya no pisa al primero
-- en silencio, recibe un error explícito (E-35).
create or replace function public.fn_bloqueo_optimista_item()
returns trigger
language plpgsql
as $$
begin
  if new.version is not null and new.version <> old.version then
    raise exception 'Otra persona modificó este artículo mientras lo editabas. Recarga y vuelve a intentarlo.'
      using errcode = 'serialization_failure';
  end if;
  new.version := old.version + 1;
  return new;
end;
$$;

drop trigger if exists trg_items_version on public.inventory_items;
create trigger trg_items_version
  before update on public.inventory_items
  for each row execute function public.fn_bloqueo_optimista_item();


-- =============================================================================
--  BLOQUE D — AUDITORÍA
-- =============================================================================

-- Usuario actual en Supabase: viene del JWT que PostgREST publica en la sesión.
-- Con fallback a NULL para que el script también corra desde el SQL Editor.
create or replace function public.fn_usuario_actual()
returns uuid
language plpgsql
stable
as $$
declare v_uid uuid;
begin
  begin
    v_uid := nullif(current_setting('request.jwt.claims', true)::json ->> 'sub', '')::uuid;
  exception when others then
    v_uid := null;
  end;
  return v_uid;
end;
$$;

create or replace function public.fn_auditoria()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.audit_log (table_name, record_id, action, old_data, new_data, changed_by)
  values (
    tg_table_name,
    coalesce(new.id::text, old.id::text),
    tg_op,
    case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end,
    public.fn_usuario_actual()
  );
  return coalesce(new, old);
end;
$$;

-- Se audita lo que afecta stock, dinero o autorizaciones.
drop trigger if exists trg_audit_items      on public.inventory_items;
create trigger trg_audit_items      after insert or update or delete on public.inventory_items
  for each row execute function public.fn_auditoria();

drop trigger if exists trg_audit_inventory  on public.inventory;
create trigger trg_audit_inventory  after insert or update or delete on public.inventory
  for each row execute function public.fn_auditoria();

drop trigger if exists trg_audit_movements  on public.inventory_movements;
create trigger trg_audit_movements  after insert or update or delete on public.inventory_movements
  for each row execute function public.fn_auditoria();

drop trigger if exists trg_audit_orders     on public.inventory_orders;
create trigger trg_audit_orders     after insert or update or delete on public.inventory_orders
  for each row execute function public.fn_auditoria();

drop trigger if exists trg_audit_assign     on public.position_assignments;
create trigger trg_audit_assign     after insert or update or delete on public.position_assignments
  for each row execute function public.fn_auditoria();


-- =============================================================================
--  BLOQUE E — CAPA 2: DETECTAR (ALERTAS)
-- =============================================================================

-- Crea la alerta si no hay ya una activa igual; si la condición desapareció,
-- cierra la que estuviera abierta.
create or replace function public.fn_emitir_alerta(
  p_type    text,
  p_entity_type text,
  p_entity_id   uuid,
  p_title   text,
  p_detail  text default null
)
returns void
language plpgsql
as $$
declare
  v_sev text;
  v_on  boolean;
begin
  select severity, is_enabled into v_sev, v_on
    from public.alert_rules where alert_type = p_type;

  if coalesce(v_on, true) is false then
    return;
  end if;

  insert into public.alerts (alert_type, severity, entity_type, entity_id, title, detail)
  values (p_type, coalesce(v_sev, 'ADVERTENCIA'), p_entity_type, p_entity_id, p_title, p_detail)
  on conflict (alert_type, entity_type, entity_id) where status = 'ACTIVA'
  do nothing;
end;
$$;

create or replace function public.fn_cerrar_alerta(
  p_type text, p_entity_type text, p_entity_id uuid
)
returns void
language plpgsql
as $$
begin
  update public.alerts
     set status = 'RESUELTA', resolved_at = now()
   where alert_type = p_type
     and entity_type = p_entity_type
     and entity_id = p_entity_id
     and status in ('ACTIVA', 'RECONOCIDA');
end;
$$;

-- Semáforo de stock: se dispara en la BD, no depende de que el dashboard
-- esté abierto ni de que alguien mire la pantalla (E-13, E-14).
create or replace function public.fn_alertas_stock()
returns trigger
language plpgsql
as $$
declare v_sku text;
begin
  select sku into v_sku from public.inventory_items where id = new.item_id;

  if new.quantity = 0 then
    perform public.fn_emitir_alerta('STOCK_AGOTADO', 'inventory', new.id,
      'Sin stock: ' || coalesce(v_sku, '?'),
      'El saldo llegó a cero.');
    perform public.fn_cerrar_alerta('STOCK_BAJO_MINIMO', 'inventory', new.id);

  elsif new.quantity <= new.min_stock then
    perform public.fn_emitir_alerta('STOCK_BAJO_MINIMO', 'inventory', new.id,
      'Bajo mínimo: ' || coalesce(v_sku, '?'),
      format('Stock %s, mínimo %s.', new.quantity, new.min_stock));
    perform public.fn_cerrar_alerta('STOCK_AGOTADO', 'inventory', new.id);

  else
    perform public.fn_cerrar_alerta('STOCK_BAJO_MINIMO', 'inventory', new.id);
    perform public.fn_cerrar_alerta('STOCK_AGOTADO',     'inventory', new.id);
  end if;

  if new.max_stock is not null and new.quantity > new.max_stock then
    perform public.fn_emitir_alerta('STOCK_SOBRE_MAXIMO', 'inventory', new.id,
      'Sobre máximo: ' || coalesce(v_sku, '?'),
      format('Stock %s, máximo %s.', new.quantity, new.max_stock));
  else
    perform public.fn_cerrar_alerta('STOCK_SOBRE_MAXIMO', 'inventory', new.id);
  end if;

  return new;
end;
$$;

drop trigger if exists trg_inventory_alertas on public.inventory;
create trigger trg_inventory_alertas
  after insert or update of quantity, min_stock, max_stock on public.inventory
  for each row execute function public.fn_alertas_stock();

-- Umbrales por defecto. El jefe los edita desde el dashboard.
insert into public.alert_rules (alert_type, severity, threshold_num, description) values
  ('STOCK_BAJO_MINIMO',     'CRITICA',     null, 'El saldo llegó o bajó del mínimo definido.'),
  ('STOCK_AGOTADO',         'CRITICA',     null, 'Saldo en cero.'),
  ('STOCK_SOBRE_MAXIMO',    'INFO',        null, 'Saldo por encima del máximo: capital inmovilizado.'),
  ('DISCREPANCIA_RECEPCION','ADVERTENCIA', null, 'Lo recibido no coincide con lo anunciado.'),
  ('CANTIDAD_ATIPICA',      'ADVERTENCIA', 5,    'Cantidad supera N veces el promedio histórico del SKU.'),
  ('APROBACION_VENCIDA',    'ADVERTENCIA', 24,   'Movimiento pendiente de aprobación por más de N horas.'),
  ('EJECUCION_VENCIDA',     'ADVERTENCIA', 48,   'Movimiento aprobado sin ejecutar por más de N horas.'),
  ('STOCK_SIN_UBICAR',      'ADVERTENCIA', null, 'Hay stock sin ninguna posición asignada.'),
  ('POSICION_SOBRECARGADA', 'CRITICA',     null, 'Asignación por encima de la capacidad del slot.'),
  ('INTENTO_NO_AUTORIZADO', 'ADVERTENCIA', null, 'Acción rechazada por falta de permisos.'),
  ('VARIACION_PRECIO',      'ADVERTENCIA', 30,   'Precio modificado más de N% respecto al anterior.')
on conflict (alert_type) do nothing;

-- Variación fuerte de precio: dedazo en el decimal o cambio que alguien debe
-- revisar (E-28).
create or replace function public.fn_alerta_precio()
returns trigger
language plpgsql
as $$
declare v_umbral numeric;
begin
  if old.price is null or new.price is null or old.price = 0 then
    return new;
  end if;

  select threshold_num into v_umbral from public.alert_rules where alert_type = 'VARIACION_PRECIO';

  if abs(new.price - old.price) / old.price * 100 >= coalesce(v_umbral, 30) then
    perform public.fn_emitir_alerta('VARIACION_PRECIO', 'inventory_items', new.id,
      'Cambio de precio inusual: ' || new.sku,
      format('De %s a %s.', old.price, new.price));
  end if;
  return new;
end;
$$;

drop trigger if exists trg_items_alerta_precio on public.inventory_items;
create trigger trg_items_alerta_precio
  after update of price on public.inventory_items
  for each row execute function public.fn_alerta_precio();


-- =============================================================================
--  BLOQUE F — WORKFLOW CORREGIDO: APROBAR / EJECUTAR / REVERTIR
-- =============================================================================
-- Cambio conceptual respecto a la migración 01: aprobar y ejecutar dejan de ser
-- el mismo acto, porque en la operación real no lo son. Aprobar COMPROMETE
-- stock (reserva); ejecutar lo MUEVE físicamente.
--
--   ENTRADA  aprobar -> qty_incoming += q      ejecutar -> qty_incoming -= q, quantity += real
--   SALIDA   aprobar -> qty_reserved += q      ejecutar -> qty_reserved -= q, quantity -= real
--   AJUSTE   aprobar -> (nada)                 ejecutar -> quantity += q * direction
--
-- Esto corrige el bug del esquema base: qty_reserved y qty_incoming existían
-- pero ninguna función los mantenía, y `ck_inventory_reserved` podía reventar
-- una salida legítima.

-- -----------------------------------------------------------------------------
-- F.1 Aprobar
-- -----------------------------------------------------------------------------
create or replace function public.fn_aprobar_movimiento(
  p_movement_id uuid,
  p_user_id     uuid default null
)
returns public.inventory_movements
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mov  public.inventory_movements;
  v_inv  public.inventory;
  v_wh   uuid;
  v_rol  text;
  v_tope integer;
  v_disp integer;
begin
  select * into v_mov from public.inventory_movements where id = p_movement_id for update;
  if not found then
    raise exception 'El movimiento no existe.';
  end if;
  if v_mov.status <> 'PENDIENTE' then
    raise exception 'Este movimiento ya fue % y no puede aprobarse de nuevo.', lower(v_mov.status);
  end if;

  -- SEGREGACIÓN DE FUNCIONES (E-30): mensaje explícito antes de que salte el
  -- constraint, para que el dashboard pueda mostrarlo tal cual.
  if p_user_id is not null and v_mov.created_by = p_user_id then
    raise exception 'No puedes aprobar un movimiento que tú mismo creaste. Debe autorizarlo otra persona.';
  end if;

  -- LÍMITE POR ROL (E-34): sobre el techo, la operación escala en vez de pasar.
  if p_user_id is not null then
    select role, max_movement_qty into v_rol, v_tope from public.profiles where id = p_user_id;

    if v_rol = 'OPERARIO' then
      raise exception 'Tu rol no autoriza aprobaciones. Solicita la autorización a un supervisor.';
    end if;
    if v_tope is not null and v_mov.quantity > v_tope then
      raise exception 'La cantidad (%) supera tu límite de aprobación (%). Debe autorizarlo un jefe.',
        v_mov.quantity, v_tope;
    end if;
  end if;

  select coalesce(o.warehouse_id, inv.warehouse_id) into v_wh
    from public.inventory_movements m
    left join public.inventory_orders o on o.id = m.order_id
    left join public.inventory      inv on inv.id = m.inventory_id
   where m.id = p_movement_id;

  if v_wh is null then
    raise exception 'El movimiento no está ligado a una orden ni a un registro de inventario: no se sabe en qué almacén aplicarlo.';
  end if;

  insert into public.inventory (item_id, warehouse_id, quantity)
  values (v_mov.item_id, v_wh, 0)
  on conflict (item_id, warehouse_id) do nothing;

  select * into v_inv from public.inventory
   where item_id = v_mov.item_id and warehouse_id = v_wh for update;

  -- APROBACIÓN A CIEGAS (E-31): se valida contra el disponible REAL, no contra
  -- el stock bruto, para no comprometer dos veces la misma mercadería (E-20).
  if v_mov.movement_type = 'SALIDA' then
    v_disp := v_inv.quantity - v_inv.qty_reserved;
    if v_disp < v_mov.quantity then
      raise exception 'Stock insuficiente: hay % disponibles (% en stock, % ya comprometidos) y se piden %.',
        v_disp, v_inv.quantity, v_inv.qty_reserved, v_mov.quantity;
    end if;
    update public.inventory set qty_reserved = qty_reserved + v_mov.quantity where id = v_inv.id;

  elsif v_mov.movement_type = 'ENTRADA' then
    update public.inventory set qty_incoming = qty_incoming + v_mov.quantity where id = v_inv.id;
  end if;

  update public.inventory_movements
     set status = 'APROBADO', approved_at = now(), approved_by = p_user_id,
         inventory_id = coalesce(inventory_id, v_inv.id)
   where id = p_movement_id
  returning * into v_mov;

  return v_mov;
end;
$$;

-- -----------------------------------------------------------------------------
-- F.2 Ejecutar (el operario recibió o retiró físicamente)
-- -----------------------------------------------------------------------------
create or replace function public.fn_ejecutar_movimiento(
  p_movement_id  uuid,
  p_user_id      uuid    default null,
  p_cantidad_real integer default null,   -- NULL = llegó/salió exactamente lo aprobado
  p_quality      text    default 'BUENO'
)
returns public.inventory_movements
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mov   public.inventory_movements;
  v_inv   public.inventory;
  v_real  integer;
  v_delta integer;
  v_before integer;
begin
  select * into v_mov from public.inventory_movements where id = p_movement_id for update;
  if not found then
    raise exception 'El movimiento no existe.';
  end if;
  if v_mov.status <> 'APROBADO' then
    raise exception 'Solo se puede ejecutar un movimiento aprobado (este está %).', lower(v_mov.status);
  end if;
  -- DOBLE EJECUCIÓN (E-06): dos operarios recibiendo la misma orden.
  if v_mov.executed_at is not null then
    raise exception 'Este movimiento ya fue ejecutado el % y no puede volver a ejecutarse.', v_mov.executed_at;
  end if;

  v_real := coalesce(p_cantidad_real, v_mov.quantity);
  if v_real <= 0 then
    raise exception 'La cantidad ejecutada debe ser mayor que cero.';
  end if;

  select * into v_inv from public.inventory where id = v_mov.inventory_id for update;
  if not found then
    raise exception 'El movimiento no tiene registro de inventario asociado.';
  end if;

  v_before := v_inv.quantity;

  if v_mov.movement_type = 'ENTRADA' then
    -- Se libera lo esperado y entra lo realmente recibido.
    if p_quality = 'BUENO' then
      update public.inventory
         set qty_incoming = greatest(qty_incoming - v_mov.quantity, 0),
             quantity     = quantity + v_real
       where id = v_inv.id;
      v_delta := v_real;
    else
      -- Mercadería dañada o en cuarentena: entra al almacén pero NO al stock
      -- vendible (E-05).
      update public.inventory
         set qty_incoming    = greatest(qty_incoming - v_mov.quantity, 0),
             qty_damaged     = qty_damaged    + case when p_quality = 'DANADO'     then v_real else 0 end,
             qty_quarantine  = qty_quarantine + case when p_quality = 'CUARENTENA' then v_real else 0 end
       where id = v_inv.id;
      v_delta := 0;
    end if;

  elsif v_mov.movement_type = 'SALIDA' then
    if v_inv.quantity < v_real then
      raise exception 'No se puede retirar %: solo hay % en stock.', v_real, v_inv.quantity;
    end if;
    -- Se libera la reserva y se descuenta el stock en la MISMA sentencia: es lo
    -- que evita que el constraint qty_reserved <= quantity reviente a mitad.
    update public.inventory
       set qty_reserved = greatest(qty_reserved - v_mov.quantity, 0),
           quantity     = quantity - v_real
     where id = v_inv.id;
    v_delta := -v_real;

  else  -- AJUSTE: el signo lo da direction (permite corregir a la baja)
    v_delta := v_real * v_mov.direction;
    if v_inv.quantity + v_delta < 0 then
      raise exception 'El ajuste dejaría el stock en negativo (hay %, se ajusta %).', v_inv.quantity, v_delta;
    end if;
    update public.inventory set quantity = quantity + v_delta where id = v_inv.id;
  end if;

  if v_delta <> 0 then
    insert into public.stock_ledger (movement_id, item_id, warehouse_id, position_id,
                                     qty_delta, qty_before, qty_after, executed_by)
    values (v_mov.id, v_mov.item_id, v_inv.warehouse_id, v_mov.position_id,
            v_delta, v_before, v_before + v_delta, p_user_id);
  end if;

  -- DISCREPANCIA (E-01/E-02/E-18): lo esperado no fue lo que pasó.
  if v_real <> v_mov.quantity then
    insert into public.discrepancies (movement_id, order_id, item_id, discrepancy_type,
                                      expected_qty, actual_qty, qty_diff, detail, reported_by)
    values (v_mov.id, v_mov.order_id, v_mov.item_id,
            case when v_real < v_mov.quantity then 'FALTANTE' else 'SOBRANTE' end,
            v_mov.quantity, v_real, v_real - v_mov.quantity,
            'Diferencia detectada al ejecutar el movimiento.', p_user_id);

    perform public.fn_emitir_alerta('DISCREPANCIA_RECEPCION', 'inventory_movements', v_mov.id,
      'Diferencia entre lo esperado y lo ejecutado',
      format('Esperado %s, real %s.', v_mov.quantity, v_real));
  end if;

  if p_quality <> 'BUENO' then
    insert into public.discrepancies (movement_id, order_id, item_id, discrepancy_type,
                                      expected_qty, actual_qty, qty_diff, detail, reported_by)
    values (v_mov.id, v_mov.order_id, v_mov.item_id, 'DANADO',
            v_mov.quantity, v_real, 0,
            format('Mercadería recibida con estado %s.', p_quality), p_user_id);
  end if;

  update public.inventory_movements
     set executed_at = now(), executed_by = p_user_id,
         expected_quantity = v_mov.quantity,
         quality_status = p_quality
   where id = v_mov.id
  returning * into v_mov;

  return v_mov;
end;
$$;

-- -----------------------------------------------------------------------------
-- F.3 Rechazar (libera lo que se hubiera comprometido)
-- -----------------------------------------------------------------------------
create or replace function public.fn_rechazar_movimiento(
  p_movement_id uuid,
  p_user_id     uuid default null,
  p_motivo      text default null
)
returns public.inventory_movements
language plpgsql
security definer
set search_path = public
as $$
declare v_mov public.inventory_movements;
begin
  select * into v_mov from public.inventory_movements where id = p_movement_id for update;
  if not found then
    raise exception 'El movimiento no existe.';
  end if;
  if v_mov.executed_at is not null then
    raise exception 'No se puede rechazar un movimiento ya ejecutado. Usa una reversión.';
  end if;
  if v_mov.status = 'RECHAZADO' then
    raise exception 'Este movimiento ya estaba rechazado.';
  end if;

  -- Si estaba aprobado, hay stock comprometido que hay que devolver.
  if v_mov.status = 'APROBADO' and v_mov.inventory_id is not null then
    if v_mov.movement_type = 'SALIDA' then
      update public.inventory set qty_reserved = greatest(qty_reserved - v_mov.quantity, 0)
       where id = v_mov.inventory_id;
    elsif v_mov.movement_type = 'ENTRADA' then
      update public.inventory set qty_incoming = greatest(qty_incoming - v_mov.quantity, 0)
       where id = v_mov.inventory_id;
    end if;
  end if;

  update public.inventory_movements
     set status = 'RECHAZADO', approved_at = now(), approved_by = p_user_id,
         notes = concat_ws(' | ', notes, coalesce(p_motivo, 'Rechazado'))
   where id = p_movement_id
  returning * into v_mov;

  return v_mov;   -- el stock nunca se tocó, por diseño
end;
$$;

-- -----------------------------------------------------------------------------
-- F.4 Revertir un movimiento YA EJECUTADO (el "reroll")
-- -----------------------------------------------------------------------------
-- No edita ni borra: emite el contra-asiento que lo anula, deja ambos ligados y
-- conserva la evidencia de quién se equivocó y quién autorizó la corrección.
create or replace function public.fn_revertir_movimiento(
  p_movement_id uuid,
  p_user_id     uuid,
  p_motivo      text
)
returns public.inventory_movements
language plpgsql
security definer
set search_path = public
as $$
declare
  v_orig  public.inventory_movements;
  v_nueva public.inventory_movements;
  v_rol   text;
  v_tipo  text;
  v_dir   smallint;
begin
  if p_motivo is null or length(btrim(p_motivo)) = 0 then
    raise exception 'La reversión exige un motivo: sin justificación no es auditable.';
  end if;

  select role into v_rol from public.profiles where id = p_user_id;
  if v_rol is distinct from 'JEFE' then
    raise exception 'Solo un jefe puede revertir un movimiento ya ejecutado.';
  end if;

  select * into v_orig from public.inventory_movements where id = p_movement_id for update;
  if not found then
    raise exception 'El movimiento no existe.';
  end if;
  if v_orig.executed_at is null then
    raise exception 'Este movimiento no se ejecutó: no hay nada que revertir (recházalo o cancélalo).';
  end if;
  if v_orig.reversal_of_id is not null then
    raise exception 'Una reversión no se revierte. Emite el movimiento original nuevamente.';
  end if;
  if exists (select 1 from public.inventory_movements where reversal_of_id = p_movement_id) then
    raise exception 'Este movimiento ya fue revertido.';
  end if;

  -- El contra-asiento invierte el sentido del original.
  if v_orig.movement_type = 'ENTRADA' then
    v_tipo := 'SALIDA';  v_dir := -1;
  elsif v_orig.movement_type = 'SALIDA' then
    v_tipo := 'ENTRADA'; v_dir := 1;
  else
    v_tipo := 'AJUSTE';  v_dir := (v_orig.direction * -1)::smallint;
  end if;

  insert into public.inventory_movements (
    order_id, item_id, inventory_id, position_id, movement_type, direction,
    quantity, reason, status, notes, created_by, approved_by, approved_at,
    reversal_of_id
  ) values (
    v_orig.order_id, v_orig.item_id, v_orig.inventory_id, v_orig.position_id,
    v_tipo, v_dir, v_orig.quantity,
    'Reversión de movimiento ' || v_orig.id::text,
    'APROBADO', p_motivo, p_user_id, p_user_id, now(),
    v_orig.id
  ) returning * into v_nueva;

  -- La reversión se ejecuta de inmediato: el error ya ocurrió en el mundo físico
  -- y el stock del sistema debe volver a reflejarlo sin esperar otro turno.
  -- Aquí created_by = approved_by a propósito (el jefe emite y autoriza su
  -- propia corrección); ck_mov_segregacion exceptúa este caso por reversal_of_id.
  v_nueva := public.fn_ejecutar_movimiento(v_nueva.id, p_user_id, v_orig.quantity, 'BUENO');

  return v_nueva;
end;
$$;

-- -----------------------------------------------------------------------------
-- F.5 Compatibilidad: aprobar + ejecutar en un solo paso
-- -----------------------------------------------------------------------------
-- El README pide que "aprobar actualice el stock". En la operación real son dos
-- actos distintos, pero este wrapper conserva el flujo simple para los casos en
-- que quien aprueba es también quien confirma la ejecución.
create or replace function public.fn_aprobar_y_ejecutar_movimiento(
  p_movement_id uuid,
  p_user_id     uuid    default null,
  p_ejecutar    boolean default true
)
returns public.inventory_movements
language plpgsql
security definer
set search_path = public
as $$
declare v_mov public.inventory_movements;
begin
  v_mov := public.fn_aprobar_movimiento(p_movement_id, p_user_id);
  if p_ejecutar then
    v_mov := public.fn_ejecutar_movimiento(p_movement_id, p_user_id, null, 'BUENO');
  end if;
  return v_mov;
end;
$$;


-- =============================================================================
--  BLOQUE G — CAPA 3: APROBACIONES ESCALADAS Y PAPELERA
-- =============================================================================

-- -----------------------------------------------------------------------------
-- G.1 Solicitar autorización "de arriba"
-- -----------------------------------------------------------------------------
create or replace function public.fn_solicitar_aprobacion(
  p_action_type text,
  p_entity_type text,
  p_entity_id   uuid,
  p_reason      text,
  p_user_id     uuid default null,
  p_payload     jsonb default '{}'::jsonb
)
returns public.approval_requests
language plpgsql
security definer
set search_path = public
as $$
declare v_req public.approval_requests;
begin
  insert into public.approval_requests (action_type, entity_type, entity_id, payload,
                                        reason, requested_by)
  values (p_action_type, p_entity_type, p_entity_id, p_payload, p_reason, p_user_id)
  returning * into v_req;
  return v_req;
end;
$$;

-- -----------------------------------------------------------------------------
-- G.2 Eliminar un artículo: nunca directo, siempre con autorización
-- -----------------------------------------------------------------------------
-- Si el artículo tiene historial, ni siquiera el jefe lo borra físicamente: se
-- manda a la papelera. El kardex debe seguir cuadrando dentro de diez años.
create or replace function public.fn_eliminar_articulo(
  p_item_id uuid,
  p_user_id uuid,
  p_motivo  text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rol       text;
  v_tiene_mov boolean;
  v_stock     integer;
  v_req       public.approval_requests;
begin
  if p_motivo is null or length(btrim(p_motivo)) = 0 then
    raise exception 'Indica el motivo de la eliminación.';
  end if;

  select role into v_rol from public.profiles where id = p_user_id;

  select exists (select 1 from public.inventory_movements where item_id = p_item_id)
    into v_tiene_mov;
  select coalesce(sum(quantity), 0) into v_stock
    from public.inventory where item_id = p_item_id;

  -- Un artículo con stock físico no se elimina: primero hay que sacarlo.
  if v_stock > 0 then
    raise exception 'No se puede eliminar: el artículo todavía tiene % unidades en stock. Regístralas como salida o ajuste primero.', v_stock;
  end if;

  -- Sin rango de jefe, la eliminación se encola para autorización (E-32).
  if v_rol is distinct from 'JEFE' then
    v_req := public.fn_solicitar_aprobacion(
      'ELIMINAR_ARTICULO', 'inventory_items', p_item_id, p_motivo, p_user_id,
      jsonb_build_object('tiene_movimientos', v_tiene_mov)
    );
    return jsonb_build_object(
      'estado', 'PENDIENTE_APROBACION',
      'solicitud_id', v_req.id,
      'mensaje', 'La eliminación quedó pendiente de autorización de un jefe.'
    );
  end if;

  update public.inventory_items
     set deleted_at = now(), deleted_by = p_user_id, is_active = false
   where id = p_item_id;

  return jsonb_build_object(
    'estado', 'ELIMINADO',
    'mensaje', 'Artículo enviado a la papelera. Su historial se conserva y puede restaurarse.'
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- G.3 Resolver una solicitud escalada
-- -----------------------------------------------------------------------------
create or replace function public.fn_resolver_aprobacion(
  p_request_id uuid,
  p_user_id    uuid,
  p_aprobar    boolean,
  p_nota       text default null
)
returns public.approval_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req public.approval_requests;
  v_rol text;
begin
  select * into v_req from public.approval_requests where id = p_request_id for update;
  if not found then
    raise exception 'La solicitud no existe.';
  end if;
  if v_req.status <> 'PENDIENTE' then
    raise exception 'Esta solicitud ya fue %.', lower(v_req.status);
  end if;
  if v_req.requested_by = p_user_id then
    raise exception 'No puedes resolver una solicitud que tú mismo pediste.';
  end if;

  select role into v_rol from public.profiles where id = p_user_id;
  if v_req.required_role = 'JEFE' and v_rol is distinct from 'JEFE' then
    perform public.fn_emitir_alerta('INTENTO_NO_AUTORIZADO', 'approval_requests', p_request_id,
      'Intento de resolver una solicitud sin rango suficiente', null);
    raise exception 'Esta solicitud requiere autorización de un jefe.';
  end if;

  if p_aprobar then
    -- Ejecuta la acción que quedó congelada esperando el visto bueno.
    case v_req.action_type
      when 'ELIMINAR_ARTICULO' then
        update public.inventory_items
           set deleted_at = now(), deleted_by = p_user_id, is_active = false
         where id = v_req.entity_id;
      when 'RESTAURAR_REGISTRO' then
        update public.inventory_items
           set deleted_at = null, deleted_by = null, is_active = true
         where id = v_req.entity_id;
      else
        null;   -- las demás las ejecuta su propia RPC tras la aprobación
    end case;
  end if;

  update public.approval_requests
     set status = case when p_aprobar then 'APROBADA' else 'RECHAZADA' end,
         resolved_by = p_user_id, resolved_at = now(), resolution_note = p_nota
   where id = p_request_id
  returning * into v_req;

  return v_req;
end;
$$;


-- =============================================================================
--  BLOQUE H — VISTAS PARA EL PANEL DE CONTROL
-- =============================================================================

-- H.1 Bandeja de alertas activas, ya ordenada por urgencia.
create or replace view public.v_alertas_activas as
select
  a.id, a.alert_type, a.severity, a.title, a.detail,
  a.entity_type, a.entity_id, a.status, a.created_at,
  extract(epoch from (now() - a.created_at)) / 3600 as horas_abierta
from public.alerts a
where a.status in ('ACTIVA', 'RECONOCIDA')
order by
  case a.severity when 'CRITICA' then 1 when 'ADVERTENCIA' then 2 else 3 end,
  a.created_at desc;

-- H.2 Colas de trabajo vencidas: lo que nadie aprobó ni ejecutó a tiempo
-- (E-36, E-37). Es la consulta que responde "¿qué está trabado?".
create or replace view public.v_movimientos_vencidos as
select
  m.id, m.movement_type, m.quantity, m.status,
  it.sku, p.name as producto,
  case when m.status = 'PENDIENTE' then 'APROBACION_VENCIDA' else 'EJECUCION_VENCIDA' end as tipo_atraso,
  coalesce(m.approved_at, m.created_at) as desde,
  round(extract(epoch from (now() - coalesce(m.approved_at, m.created_at))) / 3600, 1) as horas
from public.inventory_movements m
join public.inventory_items it on it.id = m.item_id
join public.products        p  on p.id  = it.product_id
where (m.status = 'PENDIENTE'
       and m.created_at < now() - (select coalesce(threshold_num, 24) from public.alert_rules where alert_type = 'APROBACION_VENCIDA') * interval '1 hour')
   or (m.status = 'APROBADO' and m.executed_at is null
       and m.approved_at < now() - (select coalesce(threshold_num, 48) from public.alert_rules where alert_type = 'EJECUCION_VENCIDA') * interval '1 hour');

-- H.3 Stock sin ubicar: existe en el saldo pero no está en ninguna posición (E-09).
create or replace view public.v_stock_sin_ubicar as
select
  inv.id as inventory_id, it.sku, p.name as producto, it.size_label as talla,
  w.name as almacen, inv.quantity
from public.inventory inv
join public.inventory_items it on it.id = inv.item_id
join public.products        p  on p.id  = it.product_id
join public.warehouses      w  on w.id  = inv.warehouse_id
where inv.quantity > 0
  and not exists (
    select 1 from public.position_assignments pa
     where pa.item_id = inv.item_id
       and pa.status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
  );

-- H.4 Trazabilidad completa de un movimiento, con su reversión si la tuvo.
create or replace view public.v_movimientos_detalle as
select
  m.id, m.created_at, m.approved_at, m.executed_at,
  it.sku, p.name as producto, it.size_label as talla,
  m.movement_type, m.direction, m.quantity, m.expected_quantity,
  m.quality_status, m.status,
  case
    when m.reversal_of_id is not null           then 'REVERSION'
    when r.id is not null                       then 'REVERTIDO'
    when m.executed_at is not null              then 'EJECUTADO'
    when m.status = 'APROBADO'                  then 'APROBADO_SIN_EJECUTAR'
    else m.status
  end                                as situacion,
  m.reversal_of_id,
  r.id                               as revertido_por,
  m.reason, m.notes,
  cb.full_name                       as creado_por,
  ab.full_name                       as aprobado_por,
  eb.full_name                       as ejecutado_por
from public.inventory_movements m
join public.inventory_items it on it.id = m.item_id
join public.products        p  on p.id  = it.product_id
left join public.inventory_movements r on r.reversal_of_id = m.id
left join public.profiles  cb on cb.id = m.created_by
left join public.profiles  ab on ab.id = m.approved_by
left join public.profiles  eb on eb.id = m.executed_by;


-- =============================================================================
--  FASE 2 (SIGUIENTE): RLS
-- =============================================================================
-- La matriz de roles de docs/ANALISIS-OPERATIVO.md §1 se traduce directo a
-- políticas:
--   OPERARIO   : SELECT del catálogo y su cola; ejecutar (nunca aprobar)
--   SUPERVISOR : crear órdenes y movimientos, aprobar dentro de su límite
--   JEFE       : todo, incluidas reversiones y resolución de escalamientos
--   AUDITOR    : SELECT global, incluido audit_log; ningún write
-- Las funciones de este archivo ya son SECURITY DEFINER con search_path fijo,
-- que es lo que permite que un OPERARIO ejecute un movimiento sin darle permiso
-- directo de UPDATE sobre la tabla inventory.
-- =============================================================================
