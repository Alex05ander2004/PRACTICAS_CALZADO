-- =============================================================================
--  WMS CALZADO DEPORTIVO — ESQUEMA COMPLETO (archivo consolidado)
--
--  Unión de las migraciones del proyecto, en orden:
--     01_schema_base.sql            -> modelo de datos
--     02_mejoras_operativas.sql     -> control operativo y error humano
--     03_rls.sql                    -> seguridad: RLS, API pública, permisos
--     04_publico_por_edad.sql       -> calzado infantil en nivel 1, adulto en 2+
--     05_umbrales_inventario.sql    -> editar min_stock/max_stock por columna
--     06_crear_registro_inventario.sql -> crear el primer registro de stock
--     07_mapa_almacen_completo.sql  -> IDs de posicion/asignacion en el mapa
--     08_rutas_almacen.sql          -> (superada por la 09) grafo declarado a mano
--     09_layout_editor.sql          -> plano editable por geometria + rutas con A*
--     10_crud_racks.sql             -> crear/eliminar racks desde el editor
--     11_capacidad_y_tamano.sql     -> tamano del almacen y capacidad en cajas
--     12_entrada_en_la_pared.sql    -> la entrada solo existe sobre una pared
--     13_crud_almacenes.sql         -> crear/eliminar almacenes
--     14_prefijo_de_posicion_alfanumerico.sql -> prefijo de posicion con digitos
--     15_cajas_reales_y_niveles.sql -> cajas reales, infantil en 2 niveles, minimo 3 por rack
--     16_ubicacion_en_movimientos.sql -> la vista de movimientos expone rack y posicion
--     17_reubicar_por_nivel.sql     -> lista de reubicaciones pendientes y mover atomico
--     18_reubicar_repartiendo.sql   -> reubicar repartiendo en varios casilleros
--     19_girar_la_caja.sql          -> probar las dos orientaciones de la caja
--     20_casilleros_por_modelo.sql  -> casillero por modelo, estantes al dia con el stock
--     21_casilleros_a_medida_y_revision.sql -> casilleros automaticos y revision de ubicaciones
--     22_estimacion_explicada.sql   -> la estimacion dice que caja y objetivo uso cada nivel
--     23_aplicar_casilleros_a_todo.sql -> casilleros a medida en todos los racks
--
--  Se puede pegar completo en el SQL Editor de Supabase y ejecutar de una sola
--  vez sobre una base vacía. Es idempotente. Requiere PostgreSQL 15+.
--
--  Documentación: supabase/DISENO.md · docs/ANALISIS-OPERATIVO.md
--  Verificación:  tests/01_smoke_test.sql · tests/02_rls_test.sql
--  Datos de demo: seed/seed.sql · seed/02_seed_ampliacion.sql · seed/03_seed_infantil.sql
-- =============================================================================


-- =============================================================================
--  WMS CALZADO DEPORTIVO — ESQUEMA DE BASE DE DATOS (PostgreSQL / Supabase)
--  Fase 1: modelo de datos (DDL). SIN RLS y SIN seed data (ver notas al final).
--
--  Reconcilia el README del test (inventory / inventory_items / inventory_movements)
--  con la narrativa operativa del CASO.txt (mapa de almacén, racks, posiciones,
--  INBOUND/OUTBOUND, reservas de espacio, orden creada vs movimiento ejecutado)
--  y con las inconsistencias reales del data.csv (casing, formatos de rack /
--  posicion / fecha).
--
--  Orden de las sentencias: primero tablas sin FK, luego dependientes.
--  Idempotente: se puede re-ejecutar completo en el SQL Editor de Supabase.
-- =============================================================================

-- Extensión para gen_random_uuid(). En Supabase ya viene habilitada, pero la
-- dejamos explícita para que el script corra en cualquier Postgres >= 13.
create extension if not exists "pgcrypto";

-- -----------------------------------------------------------------------------
-- 0. FUNCIÓN AUXILIAR: mantener updated_at automáticamente
-- -----------------------------------------------------------------------------
-- Se define antes que las tablas porque los triggers al final la referencian.
-- Motivo: updated_at no debe depender de que el cliente (frontend) lo mande;
-- si el stock se toca desde una RPC, un trigger o el SQL Editor, la marca de
-- tiempo debe salir igual. Por eso vive en la base de datos, no en la app.
create or replace function public.fn_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;


-- =============================================================================
--  BLOQUE A — CATÁLOGOS Y MAPA DEL ALMACÉN (tablas sin FK primero)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- A.1 profiles — quién crea, quién aprueba y quién ejecuta
-- -----------------------------------------------------------------------------
-- El CASO distingue dos actores: el EQUIPO LOGÍSTICO (crea órdenes INBOUND /
-- OUTBOUND y aprueba) y los TRABAJADORES DE ALMACÉN (reciben, ubican y retiran
-- físicamente). Sin esta tabla no hay trazabilidad de "quién hizo qué" ni base
-- para las políticas RLS de la Fase 2.
-- El id se alinea 1:1 con auth.users de Supabase; la FK queda comentada para que
-- el script también corra en un Postgres limpio sin el esquema auth.
create table if not exists public.profiles (
  id          uuid primary key default gen_random_uuid(),
  -- constraint fk_profiles_auth foreign key (id) references auth.users (id) on delete cascade,
  full_name   text        not null check (length(btrim(full_name)) > 0),
  email       text        unique,
  role        text        not null default 'ALMACEN'
              check (role in ('ADMIN', 'LOGISTICA', 'ALMACEN')),
  is_active   boolean     not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
comment on table  public.profiles is 'Usuarios operativos. Fase 2: se enlaza a auth.users y sirve de base para RLS por rol.';
comment on column public.profiles.role is 'LOGISTICA crea/aprueba órdenes; ALMACEN ejecuta movimientos físicos; ADMIN todo.';

-- -----------------------------------------------------------------------------
-- A.2 brands / categories / suppliers — catálogos normalizados
-- -----------------------------------------------------------------------------
-- El README los pedía como text libre dentro de inventory_items, pero el CSV
-- demuestra por qué eso no sirve: "NIKE"/"Nike"/"nike" y "Running"/"RUNNING"
-- serían 3 filtros distintos en el dashboard. Se extraen a catálogos con UNIQUE
-- sobre un `slug` canónico en minúsculas: la normalización ocurre UNA sola vez
-- (al importar el CSV) y no se puede volver a ensuciar.
create table if not exists public.brands (
  id         uuid primary key default gen_random_uuid(),
  slug       text        not null unique check (slug = lower(slug) and slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name       text        not null,          -- forma de presentación: 'New Balance'
  created_at timestamptz not null default now()
);
comment on column public.brands.slug is 'Clave canónica en minúsculas y con guiones (new-balance). Absorbe el casing sucio del CSV.';

create table if not exists public.categories (
  id         uuid primary key default gen_random_uuid(),
  slug       text        not null unique check (slug = lower(slug) and slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name       text        not null,          -- 'Running', 'Casual', 'Lifestyle'
  created_at timestamptz not null default now()
);

create table if not exists public.suppliers (
  id            uuid primary key default gen_random_uuid(),
  slug          text        not null unique check (slug = lower(slug) and slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name          text        not null,
  contact_email text,
  contact_phone text,
  is_active     boolean     not null default true,
  created_at    timestamptz not null default now()
);
comment on table public.suppliers is 'Proveedor como entidad: el CASO habla de "distintos proveedores que anuncian mercadería", así que una orden INBOUND apunta aquí, no a un texto suelto.';

-- -----------------------------------------------------------------------------
-- A.3 warehouses — almacén / edificio
-- -----------------------------------------------------------------------------
-- En el CSV, `ubicacion` ("Almacen A" / "Almacén A" / "Bodega B" / "Bodega C") es
-- el EDIFICIO, mientras que rack + posicion son la coordenada fina dentro de él.
-- Separarlos es lo que permite responder "¿qué espacio está ocupado?" por almacén.
-- El `code` es la clave canónica que resuelve el problema de la tilde inconsistente.
create table if not exists public.warehouses (
  id         uuid primary key default gen_random_uuid(),
  code       text        not null unique check (code ~ '^[A-Z0-9]{2,10}(-[A-Z0-9]{1,10})*$'),  -- 'ALM-A', 'BOD-B'
  name       text        not null,           -- 'Almacén A' (con tilde, forma correcta)
  address    text,
  is_active  boolean     not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- A.4 racks — estanterías dentro de un almacén
-- -----------------------------------------------------------------------------
-- El CSV trae 5 formatos para lo mismo: 'Rack-03', 'RACK 01', 'R-02', 'rack 04',
-- 'Rack 03'. El CHECK obliga al formato canónico RACK-NN y hace imposible volver
-- a insertar basura. Un rack pertenece a un único almacén (el código se repite
-- entre almacenes, por eso el UNIQUE es compuesto y no global).
create table if not exists public.racks (
  id           uuid        not null default gen_random_uuid() primary key,
  warehouse_id uuid        not null references public.warehouses (id) on delete restrict,
  code         text        not null check (code ~ '^RACK-[0-9]{2}$'),   -- 'RACK-01'
  aisle        text        check (aisle ~ '^[A-Z]$'),                    -- pasillo: A, B, C...
  description  text,
  is_active    boolean     not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint uq_racks_warehouse_code unique (warehouse_id, code)
);
-- ON DELETE RESTRICT: borrar un almacén que todavía tiene racks (y por tanto
-- stock ubicado) sería destruir el mapa físico. Se exige vaciarlo primero.

-- -----------------------------------------------------------------------------
-- A.5 positions — la posición/slot exacta: la unidad mínima del mapa
-- -----------------------------------------------------------------------------
-- El CSV mezcla 'A-03-02', 'A01-03', 'B04-02', 'C02-01'. Formato canónico
-- adoptado: <PASILLO>-<RACK 2 dígitos>-<SLOT 2 dígitos>  ->  'A-03-02'.
-- Esta tabla es EL MAPA DEL ALMACÉN: existe aunque esté vacía, lo que permite
-- responder "qué espacio está libre" (y no solo "qué espacio está usado").
create table if not exists public.positions (
  id           uuid primary key default gen_random_uuid(),
  rack_id      uuid        not null references public.racks (id) on delete restrict,
  code         text        not null check (code ~ '^[A-Z]-[0-9]{2}-[0-9]{2}$'),  -- 'A-03-02'
  level        smallint    check (level >= 1),        -- altura/nivel dentro del rack
  slot         smallint    check (slot  >= 1),        -- casillero dentro del nivel
  capacity_units integer   not null default 0 check (capacity_units >= 0),
  is_active    boolean     not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint uq_positions_rack_code unique (rack_id, code)
);
comment on table  public.positions is 'Mapa físico del almacén. Una fila = un espacio direccionable; existe libre u ocupado.';
comment on column public.positions.capacity_units is '0 = sin límite declarado. Permite validar que no se sobrecargue un slot.';


-- =============================================================================
--  BLOQUE B — PRODUCTO Y VARIANTE (TALLA)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- B.1 products — el MODELO de zapatilla (sin talla)
-- -----------------------------------------------------------------------------
-- Decisión clave: el README pedía una sola tabla `inventory_items`, pero en un
-- almacén de calzado real un mismo modelo existe en muchas tallas y CADA TALLA
-- tiene su propio stock, su propia ubicación y sus propios movimientos.
-- Meter la talla dentro de inventory_items sin un padre obligaría a repetir
-- nombre/marca/categoría/proveedor en 10 filas por modelo (anomalía de
-- actualización). Se parte en products (modelo) -> inventory_items (variante).
create table if not exists public.products (
  id          uuid primary key default gen_random_uuid(),
  model_code  text        not null unique check (model_code ~ '^[A-Z]{2,5}-[0-9]{3,5}$'),  -- 'ZAP-001' (el `sku` del CSV)
  name        text        not null check (length(btrim(name)) > 0),
  description text,
  brand_id    uuid        references public.brands (id)     on delete set null,
  category_id uuid        references public.categories (id) on delete set null,
  supplier_id uuid        references public.suppliers (id)  on delete set null,
  is_active   boolean     not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
-- ON DELETE SET NULL en los catálogos: borrar una marca no debe borrar productos
-- ni el histórico de movimientos asociado; solo deja el atributo sin clasificar.
comment on column public.products.model_code is 'Código del modelo = columna `sku` del CSV (ZAP-001). El SKU vendible vive en inventory_items.';

-- -----------------------------------------------------------------------------
-- B.2 inventory_items — LA VARIANTE VENDIBLE: modelo + talla (TABLA 2 del README)
-- -----------------------------------------------------------------------------
-- Se conserva el nombre exigido por el README. Aquí viven sku, precio, costo y
-- dimensiones porque en calzado varían por talla (una 44 pesa y ocupa más que
-- una 36) y el precio puede diferir por talla especial.
create table if not exists public.inventory_items (
  id          uuid primary key default gen_random_uuid(),
  product_id  uuid        not null references public.products (id) on delete restrict,
  sku         text        not null unique check (sku = upper(sku) and sku ~ '^[A-Z0-9]+(-[A-Z0-9]+)+$'),  -- 'ZAP-001-40'
  size_label  text        not null check (length(btrim(size_label)) > 0),   -- '40', '41.5'
  size_system text        not null default 'EU' check (size_system in ('EU', 'US', 'UK')),
  barcode     text        unique,
  weight      numeric(10,3) check (weight  is null or weight  >= 0),   -- kg
  length      numeric(10,2) check (length  is null or length  >= 0),   -- cm
  width       numeric(10,2) check (width   is null or width   >= 0),   -- cm
  height      numeric(10,2) check (height  is null or height  >= 0),   -- cm
  price       numeric(12,2) check (price is null or price >= 0),
  cost        numeric(12,2) check (cost  is null or cost  >= 0),
  is_active   boolean     not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint uq_items_product_size unique (product_id, size_label, size_system)
);
-- ON DELETE RESTRICT hacia products: un ítem con historial de movimientos no debe
-- desaparecer por borrar el modelo; se usa is_active = false para retirarlo.
comment on constraint uq_items_product_size on public.inventory_items is 'Impide duplicar la misma talla del mismo modelo (el error clásico al importar un CSV plano).';

-- -----------------------------------------------------------------------------
-- B.3 inventory — STOCK ACTUAL (TABLA 1 del README)
-- -----------------------------------------------------------------------------
-- El README dice "1 artículo -> 1 registro de inventario". Se respeta esa cardinalidad
-- POR ALMACÉN: un ítem tiene UNA sola fila de stock en cada almacén (con un solo
-- almacén, la relación es literalmente 1:1 como pide el README; con varios, sigue
-- habiendo un único saldo por edificio, que es lo que muestra el dashboard).
-- El detalle fino de "en qué slot está" NO va aquí: va en position_assignments,
-- porque un mismo ítem puede estar repartido en varias posiciones.
create table if not exists public.inventory (
  id              uuid primary key default gen_random_uuid(),
  item_id         uuid        not null references public.inventory_items (id) on delete cascade,
  warehouse_id    uuid        not null references public.warehouses (id)      on delete restrict,
  quantity        integer     not null default 0 check (quantity >= 0),        -- stock físico disponible
  qty_reserved    integer     not null default 0 check (qty_reserved >= 0),    -- comprometido por OUTBOUND aprobado y no ejecutado
  qty_incoming    integer     not null default 0 check (qty_incoming >= 0),    -- esperado por INBOUND aprobado y no ejecutado
  min_stock       integer     not null default 0 check (min_stock >= 0),
  max_stock       integer     check (max_stock is null or max_stock >= 0),
  updated_at      timestamptz not null default now(),
  created_at      timestamptz not null default now(),
  constraint uq_inventory_item_warehouse unique (item_id, warehouse_id),
  constraint ck_inventory_min_max        check (max_stock is null or max_stock >= min_stock),
  constraint ck_inventory_reserved       check (qty_reserved <= quantity)
);
-- ON DELETE CASCADE hacia inventory_items: si el ítem se borra de verdad, su saldo
-- deja de tener sentido. El histórico (stock_ledger) se conserva aparte.
comment on column public.inventory.qty_reserved is 'Stock físicamente presente pero ya comprometido a un OUTBOUND aprobado. Disponible real = quantity - qty_reserved.';
comment on column public.inventory.qty_incoming is 'Unidades anunciadas por un INBOUND aprobado que aún NO llegaron. No suma al stock hasta la ejecución.';


-- =============================================================================
--  BLOQUE C — OCUPACIÓN DEL ESPACIO (el corazón del CASO)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- C.1 position_assignments — qué ítem ocupa (o reserva) qué posición
-- -----------------------------------------------------------------------------
-- Responde tres preguntas del CASO con una sola tabla:
--   a) "qué ubicación ocupa cada producto"      -> fila con status = 'OCUPADA'
--   b) "cómo reservar espacio para un INBOUND"  -> fila con status = 'RESERVADA'
--      creada al aprobar la orden, ANTES de que la mercadería llegue
--   c) "cómo preparar una ubicación para un OUTBOUND" -> status = 'EN_PICKING',
--      el slot queda bloqueado mientras el operario arma el pedido
-- 'LIBERADA' cierra la fila y conserva el histórico de ocupación del espacio.
create table if not exists public.position_assignments (
  id            uuid primary key default gen_random_uuid(),
  position_id   uuid        not null references public.positions (id)       on delete restrict,
  item_id       uuid        not null references public.inventory_items (id) on delete restrict,
  quantity      integer     not null default 0 check (quantity >= 0),
  status        text        not null default 'RESERVADA'
                check (status in ('RESERVADA', 'OCUPADA', 'EN_PICKING', 'LIBERADA')),
  assigned_at   timestamptz not null default now(),
  released_at   timestamptz,
  assigned_by   uuid        references public.profiles (id) on delete set null,
  notes         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  -- Coherencia de estados: solo una fila LIBERADA puede tener released_at.
  constraint ck_assign_released check (
    (status = 'LIBERADA' and released_at is not null)
    or (status <> 'LIBERADA' and released_at is null)
  )
);

-- *** REGLA ANTI-DOBLE-OCUPACIÓN ***
-- Índice único PARCIAL: como máximo UNA asignación viva por posición. Impide
-- físicamente que dos productos distintos ocupen el mismo espacio y también que
-- se reserve un slot que ya está ocupado o en picking. Al liberar (status =
-- 'LIBERADA') la fila sale del índice y el espacio queda disponible otra vez,
-- sin borrar el histórico. Esto es una garantía de la BD, no una validación de la app.
create unique index if not exists ux_position_assignment_activa
  on public.position_assignments (position_id)
  where status in ('RESERVADA', 'OCUPADA', 'EN_PICKING');


-- =============================================================================
--  BLOQUE D — ÓRDENES (lo planificado) vs MOVIMIENTOS (lo ejecutado)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- D.1 inventory_orders — la ORDEN: INBOUND / OUTBOUND (cabecera)
-- -----------------------------------------------------------------------------
-- El CASO pide explícitamente "diferenciar una orden creada de un movimiento
-- realmente ejecutado". Esta tabla es la INTENCIÓN: el equipo logístico anuncia
-- que un proveedor va a entregar (INBOUND) o que hay un pedido por despachar
-- (OUTBOUND). No toca el stock jamás.
create table if not exists public.inventory_orders (
  id            uuid primary key default gen_random_uuid(),
  order_number  text        not null unique,             -- 'IN-2026-0001' / 'OUT-2026-0001'
  order_type    text        not null check (order_type in ('INBOUND', 'OUTBOUND')),
  status        text        not null default 'PENDIENTE'
                check (status in ('PENDIENTE', 'APROBADO', 'RECHAZADO', 'EJECUTADO', 'CANCELADO')),
  warehouse_id  uuid        not null references public.warehouses (id) on delete restrict,
  supplier_id   uuid        references public.suppliers (id) on delete set null,  -- solo INBOUND
  customer_name text,                                                             -- solo OUTBOUND (tienda o cliente)
  expected_date date,                                    -- fecha anunciada de llegada/despacho
  reason        text,
  notes         text,
  created_by    uuid        references public.profiles (id) on delete set null,
  approved_by   uuid        references public.profiles (id) on delete set null,
  created_at    timestamptz not null default now(),
  approved_at   timestamptz,
  executed_at   timestamptz,
  updated_at    timestamptz not null default now(),
  -- Una orden aprobada o rechazada DEBE tener sello de tiempo y responsable:
  -- sin esto el workflow de aprobación no es auditable.
  constraint ck_orders_aprobacion check (
    (status in ('APROBADO', 'EJECUTADO') and approved_at is not null and approved_by is not null)
    or (status = 'RECHAZADO' and approved_at is not null)
    or (status in ('PENDIENTE', 'CANCELADO'))
  ),
  constraint ck_orders_ejecucion check (
    (status = 'EJECUTADO' and executed_at is not null)
    or (status <> 'EJECUTADO')
  ),
  -- Un INBOUND exige proveedor; un OUTBOUND exige destinatario.
  constraint ck_orders_contraparte check (
    (order_type = 'INBOUND'  and supplier_id   is not null)
    or (order_type = 'OUTBOUND' and customer_name is not null)
  )
);
comment on table public.inventory_orders is 'La INTENCIÓN (orden creada). Nunca modifica stock. El stock cambia solo cuando un movimiento se ejecuta.';

-- -----------------------------------------------------------------------------
-- D.2 inventory_movements — EL MOVIMIENTO (TABLA 3 del README)
-- -----------------------------------------------------------------------------
-- Es la LÍNEA de la orden y a la vez el objeto del workflow de aprobación.
-- Ciclo de vida completo:
--   1) se crea             -> status = 'PENDIENTE', executed_at = NULL  (stock NO cambia)
--   2) se aprueba          -> status = 'APROBADO',  executed_at = NULL  (stock NO cambia todavía;
--                             solo se reserva espacio / se compromete stock)
--   3) se ejecuta físicamente -> executed_at = now() (el operario recibió o retiró);
--                             recién aquí cambia inventory.quantity y se escribe el ledger
--   x) se rechaza          -> status = 'RECHAZADO', executed_at siempre NULL (stock NO cambia)
-- La diferencia "orden creada" vs "movimiento ejecutado" queda en DOS columnas
-- independientes: `status` (decisión administrativa) y `executed_at` (hecho físico).
create table if not exists public.inventory_movements (
  id             uuid primary key default gen_random_uuid(),
  order_id       uuid        references public.inventory_orders (id) on delete cascade,
  item_id        uuid        not null references public.inventory_items (id) on delete restrict,
  inventory_id   uuid        references public.inventory (id) on delete set null,
  -- inventory_id es NULLABLE a propósito: un INBOUND puede anunciar un ítem que
  -- todavía no tiene fila de stock en ese almacén; la fila se crea/enlaza al ejecutar.
  position_id    uuid        references public.positions (id) on delete set null,
  -- posición destino (INBOUND) u origen (OUTBOUND). Nullable porque un AJUSTE
  -- contable puede no tener coordenada física.
  movement_type  text        not null check (movement_type in ('ENTRADA', 'SALIDA', 'AJUSTE')),
  -- ENTRADA <- INBOUND, SALIDA <- OUTBOUND (mapeo del CSV al vocabulario del README).
  quantity       integer     not null check (quantity > 0),
  -- Siempre positivo: el signo lo determina movement_type. Evita el bug clásico
  -- de una SALIDA con cantidad negativa que termina sumando stock.
  reason         text,
  status         text        not null default 'PENDIENTE'
                 check (status in ('PENDIENTE', 'APROBADO', 'RECHAZADO')),
  notes          text,
  created_by     uuid        references public.profiles (id) on delete set null,
  approved_by    uuid        references public.profiles (id) on delete set null,
  executed_by    uuid        references public.profiles (id) on delete set null,
  created_at     timestamptz not null default now(),
  approved_at    timestamptz,
  executed_at    timestamptz,
  updated_at     timestamptz not null default now(),
  -- Un movimiento rechazado nunca puede estar ejecutado.
  constraint ck_mov_rechazado_no_ejecutado check (
    status <> 'RECHAZADO' or executed_at is null
  ),
  -- Solo se ejecuta lo aprobado: garantía dura del workflow del README.
  constraint ck_mov_ejecucion_requiere_aprobacion check (
    executed_at is null or status = 'APROBADO'
  ),
  constraint ck_mov_aprobacion_sellada check (
    status = 'PENDIENTE' or approved_at is not null
  )
);
comment on column public.inventory_movements.executed_at is 'NULL = orden/línea creada pero NO ejecutada. NOT NULL = el movimiento físico ocurrió y el stock ya se afectó.';
comment on column public.inventory_movements.quantity  is 'Siempre > 0. El sentido (+/-) lo da movement_type.';

-- -----------------------------------------------------------------------------
-- D.3 stock_ledger — kardex inmutable: la prueba de lo realmente ejecutado
-- -----------------------------------------------------------------------------
-- inventory.quantity es un SALDO (se sobrescribe). El ledger es el HISTÓRICO
-- append-only que permite reconstruir cómo se llegó a ese saldo y auditar
-- diferencias de inventario. Guarda el antes/después, no solo el delta.
create table if not exists public.stock_ledger (
  id           bigserial primary key,
  movement_id  uuid        references public.inventory_movements (id) on delete set null,
  item_id      uuid        not null references public.inventory_items (id) on delete restrict,
  warehouse_id uuid        not null references public.warehouses (id) on delete restrict,
  position_id  uuid        references public.positions (id) on delete set null,
  qty_delta    integer     not null check (qty_delta <> 0),   -- +entrada / -salida
  qty_before   integer     not null check (qty_before >= 0),
  qty_after    integer     not null check (qty_after  >= 0),
  occurred_at  timestamptz not null default now(),
  executed_by  uuid        references public.profiles (id) on delete set null,
  notes        text,
  constraint ck_ledger_aritmetica check (qty_after = qty_before + qty_delta)
);
comment on table public.stock_ledger is 'Append-only. Nunca se hace UPDATE/DELETE aquí: es la trazabilidad exigida por el CASO.';


-- =============================================================================
--  BLOQUE E — ÍNDICES
-- =============================================================================
-- Postgres crea índice automático para PK y UNIQUE, pero NO para las FK.
-- Se indexan: (1) todas las FK usadas en joins, (2) las columnas que el dashboard
-- filtra u ordena (sku, categoría, proveedor, estado, fechas).

-- Mapa del almacén
create index if not exists ix_racks_warehouse            on public.racks (warehouse_id);
create index if not exists ix_positions_rack             on public.positions (rack_id);

-- Producto / variante
create index if not exists ix_products_brand             on public.products (brand_id);
create index if not exists ix_products_category          on public.products (category_id);
create index if not exists ix_products_supplier          on public.products (supplier_id);
create index if not exists ix_products_name_lower        on public.products (lower(name));  -- búsqueda por nombre en el dashboard
create index if not exists ix_items_product              on public.inventory_items (product_id);
create index if not exists ix_items_sku_lower            on public.inventory_items (lower(sku));

-- Stock
create index if not exists ix_inventory_item             on public.inventory (item_id);
create index if not exists ix_inventory_warehouse        on public.inventory (warehouse_id);
-- Índice parcial para el widget "alertas de stock bajo": solo indexa las filas
-- que realmente están por debajo del mínimo, así la consulta más usada del
-- dashboard no recorre toda la tabla.
create index if not exists ix_inventory_bajo_minimo      on public.inventory (warehouse_id, item_id)
  where quantity <= min_stock;

-- Ocupación
create index if not exists ix_assign_item                on public.position_assignments (item_id);
create index if not exists ix_assign_status              on public.position_assignments (status);
create index if not exists ix_assign_position            on public.position_assignments (position_id);

-- Órdenes y movimientos (filtros del dashboard: estado + tipo + fecha)
create index if not exists ix_orders_status              on public.inventory_orders (status);
create index if not exists ix_orders_type_status         on public.inventory_orders (order_type, status);
create index if not exists ix_orders_warehouse           on public.inventory_orders (warehouse_id);
create index if not exists ix_orders_supplier            on public.inventory_orders (supplier_id);
create index if not exists ix_orders_created_at          on public.inventory_orders (created_at desc);

create index if not exists ix_mov_order                  on public.inventory_movements (order_id);
create index if not exists ix_mov_item                   on public.inventory_movements (item_id);
create index if not exists ix_mov_inventory              on public.inventory_movements (inventory_id);
create index if not exists ix_mov_position               on public.inventory_movements (position_id);
create index if not exists ix_mov_status                 on public.inventory_movements (status);
create index if not exists ix_mov_type_status            on public.inventory_movements (movement_type, status);
create index if not exists ix_mov_created_at             on public.inventory_movements (created_at desc);
-- Cola de trabajo: movimientos aprobados pendientes de ejecutar físicamente.
create index if not exists ix_mov_pendientes_ejecucion   on public.inventory_movements (approved_at)
  where status = 'APROBADO' and executed_at is null;

create index if not exists ix_ledger_item_fecha          on public.stock_ledger (item_id, occurred_at desc);
create index if not exists ix_ledger_movement            on public.stock_ledger (movement_id);


-- =============================================================================
--  BLOQUE F — TRIGGERS updated_at
-- =============================================================================
drop trigger if exists trg_profiles_updated_at    on public.profiles;
create trigger trg_profiles_updated_at    before update on public.profiles
  for each row execute function public.fn_set_updated_at();

drop trigger if exists trg_warehouses_updated_at  on public.warehouses;
create trigger trg_warehouses_updated_at  before update on public.warehouses
  for each row execute function public.fn_set_updated_at();

drop trigger if exists trg_racks_updated_at       on public.racks;
create trigger trg_racks_updated_at       before update on public.racks
  for each row execute function public.fn_set_updated_at();

drop trigger if exists trg_positions_updated_at   on public.positions;
create trigger trg_positions_updated_at   before update on public.positions
  for each row execute function public.fn_set_updated_at();

drop trigger if exists trg_products_updated_at    on public.products;
create trigger trg_products_updated_at    before update on public.products
  for each row execute function public.fn_set_updated_at();

drop trigger if exists trg_items_updated_at       on public.inventory_items;
create trigger trg_items_updated_at       before update on public.inventory_items
  for each row execute function public.fn_set_updated_at();

drop trigger if exists trg_inventory_updated_at   on public.inventory;
create trigger trg_inventory_updated_at   before update on public.inventory
  for each row execute function public.fn_set_updated_at();

drop trigger if exists trg_assign_updated_at      on public.position_assignments;
create trigger trg_assign_updated_at      before update on public.position_assignments
  for each row execute function public.fn_set_updated_at();

drop trigger if exists trg_orders_updated_at      on public.inventory_orders;
create trigger trg_orders_updated_at      before update on public.inventory_orders
  for each row execute function public.fn_set_updated_at();

drop trigger if exists trg_movements_updated_at   on public.inventory_movements;
create trigger trg_movements_updated_at   before update on public.inventory_movements
  for each row execute function public.fn_set_updated_at();


-- =============================================================================
--  BLOQUE G — VISTAS DE LECTURA PARA EL DASHBOARD
-- =============================================================================

-- G.1 Vista "plana" compatible con la TABLA 2 del README (name/category/supplier
-- como texto en una sola fila). Permite que el frontend consulte un solo objeto
-- sin perder la normalización que hay debajo.
create or replace view public.v_items_detalle as
select
  i.id                as item_id,
  i.sku,
  p.model_code,
  p.name,
  p.description,
  b.name              as brand,
  c.name              as category,
  s.name              as supplier,
  i.size_label,
  i.size_system,
  i.weight, i.length, i.width, i.height,
  i.price, i.cost,
  i.is_active,
  i.created_at
from public.inventory_items i
join public.products   p on p.id = i.product_id
left join public.brands     b on b.id = p.brand_id
left join public.categories c on c.id = p.category_id
left join public.suppliers  s on s.id = p.supplier_id;

-- G.2 Stock consolidado con disponibilidad real y semáforo de reposición.
create or replace view public.v_stock_actual as
select
  inv.id                            as inventory_id,
  inv.item_id,
  it.sku,
  p.name                            as producto,
  it.size_label                     as talla,
  w.name                            as almacen,
  inv.quantity,
  inv.qty_reserved,
  inv.qty_incoming,
  (inv.quantity - inv.qty_reserved) as disponible,
  inv.min_stock,
  inv.max_stock,
  case
    when inv.quantity = 0                   then 'SIN_STOCK'
    when inv.quantity <= inv.min_stock      then 'BAJO_MINIMO'
    when inv.max_stock is not null
         and inv.quantity > inv.max_stock   then 'SOBRE_MAXIMO'
    else 'OK'
  end                               as estado_stock,
  inv.updated_at
from public.inventory inv
join public.inventory_items it on it.id = inv.item_id
join public.products        p  on p.id  = it.product_id
join public.warehouses      w  on w.id  = inv.warehouse_id;

-- G.3 Mapa de ocupación: TODAS las posiciones, ocupadas y libres.
-- Es la consulta que alimenta la vista "mapa del almacén" y la que responde
-- "qué espacio está libre para recibir el próximo INBOUND".
create or replace view public.v_mapa_almacen as
select
  w.code            as almacen_code,
  w.name            as almacen,
  r.code            as rack,
  pos.code          as posicion,
  pos.capacity_units,
  pa.status         as estado_ocupacion,   -- NULL = libre
  pa.quantity       as unidades,
  it.sku,
  pr.name           as producto,
  it.size_label     as talla,
  pa.assigned_at
from public.positions pos
join public.racks      r on r.id = pos.rack_id
join public.warehouses w on w.id = r.warehouse_id
left join public.position_assignments pa
       on pa.position_id = pos.id
      and pa.status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
left join public.inventory_items it on it.id = pa.item_id
left join public.products        pr on pr.id = it.product_id;


-- =============================================================================
--  BLOQUE H — RPC DE APROBACIÓN + EJECUCIÓN ATÓMICA
-- =============================================================================
-- El README exige que aprobar un movimiento actualice el stock en UNA operación
-- atómica. Se implementa como función de Postgres (llamable con supabase.rpc)
-- y no en el cliente: así aprobación, cambio de saldo, asiento del kardex y
-- liberación/ocupación de la posición ocurren dentro de la MISMA transacción.
-- El FOR UPDATE sobre la fila de inventario evita condiciones de carrera si dos
-- operarios aprueban a la vez.
create or replace function public.fn_aprobar_y_ejecutar_movimiento(
  p_movement_id uuid,
  p_user_id     uuid default null,
  p_ejecutar    boolean default true   -- false = solo aprobar (queda en cola de ejecución física)
)
returns public.inventory_movements
language plpgsql
security invoker           -- Fase 2: evaluar security definer + RLS por rol
as $$
declare
  v_mov   public.inventory_movements;
  v_inv   public.inventory;
  v_delta integer;
  v_wh    uuid;
begin
  select * into v_mov from public.inventory_movements
   where id = p_movement_id for update;
  if not found then
    raise exception 'Movimiento % no existe', p_movement_id;
  end if;
  if v_mov.status <> 'PENDIENTE' then
    raise exception 'El movimiento % ya fue resuelto (status=%)', p_movement_id, v_mov.status;
  end if;

  -- Almacén: de la orden si existe, si no del registro de inventario ligado.
  select coalesce(o.warehouse_id, inv.warehouse_id)
    into v_wh
    from public.inventory_movements m
    left join public.inventory_orders o on o.id = m.order_id
    left join public.inventory       inv on inv.id = m.inventory_id
   where m.id = p_movement_id;

  if p_ejecutar and v_wh is null then
    raise exception 'No se puede ejecutar el movimiento %: no está ligado a una orden ni a un registro de inventario, así que no se sabe en qué almacén aplicar el stock', p_movement_id;
  end if;

  update public.inventory_movements
     set status = 'APROBADO', approved_at = now(), approved_by = p_user_id
   where id = p_movement_id
  returning * into v_mov;

  if not p_ejecutar then
    return v_mov;   -- aprobado pero aún NO ejecutado: stock intacto
  end if;

  -- Fila de stock: se crea si el ítem aún no tenía saldo en ese almacén.
  insert into public.inventory (item_id, warehouse_id, quantity)
  values (v_mov.item_id, v_wh, 0)
  on conflict (item_id, warehouse_id) do nothing;

  select * into v_inv from public.inventory
   where item_id = v_mov.item_id and warehouse_id = v_wh for update;

  v_delta := case v_mov.movement_type
               when 'ENTRADA' then  v_mov.quantity
               when 'SALIDA'  then -v_mov.quantity
               else v_mov.quantity            -- AJUSTE: se registra como delta positivo declarado
             end;

  if v_inv.quantity + v_delta < 0 then
    raise exception 'Stock insuficiente: hay % y se intenta retirar %', v_inv.quantity, v_mov.quantity;
  end if;

  update public.inventory
     set quantity = quantity + v_delta
   where id = v_inv.id;

  insert into public.stock_ledger (movement_id, item_id, warehouse_id, position_id,
                                   qty_delta, qty_before, qty_after, executed_by)
  values (v_mov.id, v_mov.item_id, v_wh, v_mov.position_id,
          v_delta, v_inv.quantity, v_inv.quantity + v_delta, p_user_id);

  update public.inventory_movements
     set executed_at = now(), executed_by = p_user_id, inventory_id = v_inv.id
   where id = v_mov.id
  returning * into v_mov;

  return v_mov;
end;
$$;

-- Rechazo: cierra el movimiento sin tocar el stock (exigencia del README).
create or replace function public.fn_rechazar_movimiento(
  p_movement_id uuid,
  p_user_id     uuid default null,
  p_motivo      text default null
)
returns public.inventory_movements
language plpgsql
security invoker
as $$
declare v_mov public.inventory_movements;
begin
  update public.inventory_movements
     set status = 'RECHAZADO', approved_at = now(), approved_by = p_user_id,
         notes = coalesce(notes || ' | ', '') || coalesce(p_motivo, 'Rechazado')
   where id = p_movement_id and status = 'PENDIENTE'
  returning * into v_mov;
  if not found then
    raise exception 'El movimiento % no existe o ya fue resuelto', p_movement_id;
  end if;
  return v_mov;   -- stock sin cambios, por diseño
end;
$$;


-- =============================================================================
--  CONTINÚA EN LA MIGRACIÓN 02
-- =============================================================================
-- 02_mejoras_operativas.sql amplía este esquema con el control operativo que
-- exige trabajar con personas: auditoría, alertas, aprobaciones escaladas,
-- reversión de movimientos y conteo cíclico. También corrige cuatro huecos de
-- este archivo (qty_reserved/qty_incoming sin mantener, AJUSTE que solo podía
-- sumar, capacity_units sin validar, y ausencia de segregación de funciones).
-- Ver docs/ANALISIS-OPERATIVO.md para el catálogo completo de casos.
--
-- TODO Fase 2: RLS sobre la matriz de roles definida en la migración 02.
-- TODO Fase 3: carga (seed) del data.csv ya normalizado y datos de demo.
-- =============================================================================


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


-- =============================================================================
--  MIGRACIÓN 04 — CALZADO INFANTIL EN NIVELES INFERIORES, ADULTO EN SUPERIORES
--
--  Pedido del jefe de almacén: por seguridad y accesibilidad, el calzado de
--  niños debe quedar en los niveles bajos de los racks (a la mano de un niño o
--  de quien lo acompaña) y el de adultos en los niveles altos.
--
--  El esquema base YA tenía el campo `positions.level` pensado para esto
--  (Fase 1: "altura/nivel dentro del rack") pero nunca se usó. Esta migración:
--    1. Agrega `products.audience` (ADULTO/NINO/UNISEX) — el público es un
--       atributo del MODELO, no de la talla: en la práctica una marca saca una
--       línea infantil como producto aparte, no el mismo modelo en talla chica.
--    2. Rellena `positions.level` en lo que ya existe (todo hoy es ADULTO, así
--       que el nivel 2 es seguro para todo lo ya ubicado) y lo vuelve obligatorio.
--    3. Agrega la regla como TRIGGER, no como convención: un INSERT/UPDATE que
--       intente poner un artículo infantil en nivel != 1, o uno de adulto en
--       nivel 1, falla. Mismo patrón que ya usamos para capacidad y para
--       impedir doble ocupación — la garantía vive en la base, no en la UI.
--
--  Requiere 01, 02 y 03. Idempotente.
-- =============================================================================


-- =============================================================================
--  BLOQUE A — PÚBLICO DEL PRODUCTO
-- =============================================================================
alter table public.products
  add column if not exists audience text not null default 'ADULTO';

alter table public.products drop constraint if exists ck_products_audience;
alter table public.products
  add constraint ck_products_audience check (audience in ('ADULTO', 'NINO', 'UNISEX'));

comment on column public.products.audience is
  'A quién está dirigido el modelo. Determina en qué nivel del rack puede ubicarse (ver trg_assign_publico_nivel).';


-- =============================================================================
--  BLOQUE B — NIVEL DE CADA POSICIÓN (obligatorio de aquí en adelante)
-- =============================================================================
-- Todo lo que existe hoy es ADULTO (no hay artículos infantiles todavía), así
-- que retroactivamente es seguro poner nivel 2 (superior) en cualquier
-- posición que no tuviera nivel definido.
update public.positions set level = 2 where level is null;

alter table public.positions alter column level set not null;

comment on column public.positions.level is
  'Nivel físico dentro del rack. Convención del almacén: 1 = inferior (solo calzado infantil), 2+ = superior (adulto/unisex). Obligatorio: una posición sin nivel no se puede usar para asignar stock.';


-- =============================================================================
--  BLOQUE C — LA REGLA, COMO TRIGGER
-- =============================================================================
create or replace function public.fn_validar_publico_por_nivel()
returns trigger
language plpgsql
as $$
declare
  v_audience text;
  v_level    smallint;
begin
  -- Liberar un espacio no reubica nada: no hay nada que validar.
  if new.status = 'LIBERADA' then
    return new;
  end if;

  select p.audience into v_audience
    from public.inventory_items it
    join public.products        p  on p.id = it.product_id
   where it.id = new.item_id;

  select level into v_level from public.positions where id = new.position_id;

  if v_level is null then
    -- No debería pasar (level es NOT NULL desde el Bloque B), pero si en el
    -- futuro alguien crea una posición sin nivel, mejor un error claro aquí
    -- que dejar pasar un calzado infantil a un nivel sin validar.
    raise exception 'La posición % no tiene nivel definido.', new.position_id;
  end if;

  if v_audience = 'NINO' and v_level <> 1 then
    raise exception
      'Calzado infantil solo puede ubicarse en el nivel 1 (inferior). La posición elegida está en el nivel %.',
      v_level
      using errcode = 'check_violation';
  end if;

  if v_audience = 'ADULTO' and v_level = 1 then
    raise exception
      'Calzado de adulto no puede ubicarse en el nivel 1: está reservado para calzado infantil.'
      using errcode = 'check_violation';
  end if;

  -- UNISEX: sin restricción de nivel.
  return new;
end;
$$;

drop trigger if exists trg_assign_publico_nivel on public.position_assignments;
create trigger trg_assign_publico_nivel
  before insert or update on public.position_assignments
  for each row execute function public.fn_validar_publico_por_nivel();

comment on trigger trg_assign_publico_nivel on public.position_assignments is
  'Regla del jefe de almacén: infantil abajo (nivel 1), adulto arriba (nivel 2+). Se aplica en la base, no confía en que la UI la respete.';


-- =============================================================================
--  MIGRACIÓN 05 — PERMITIR EDITAR min_stock / max_stock SIN ABRIR quantity
--
--  La migración 03 le dio a `inventory` SOLO política de SELECT: a propósito,
--  para que nadie mueva `quantity` fuera del workflow de aprobación. Pero eso
--  también bloqueaba min_stock/max_stock, que son umbrales de configuración,
--  no stock físico — y el README pide explícitamente poder "modificar
--  información del inventario".
--
--  La solución no es abrir toda la fila: RLS es por FILA, no por columna, así
--  que una policy de UPDATE por sí sola no puede decir "sí a min_stock, no a
--  quantity". Para eso existe el GRANT por columna de Postgres — una capa
--  totalmente independiente de RLS. Con las dos juntas: la policy decide QUIÉN
--  puede tocar la fila, el grant decide QUÉ columnas puede tocar, y un intento
--  de UPDATE quantity falla con "permission denied for column quantity" así
--  la policy lo hubiera permitido.
--
--  Requiere 01-04. Idempotente.
-- =============================================================================

grant update (min_stock, max_stock) on public.inventory to authenticated;

drop policy if exists p_inventory_update_umbrales on public.inventory;
create policy p_inventory_update_umbrales on public.inventory
  for update to authenticated
  using ((select public.fn_es_al_menos_supervisor()))
  with check ((select public.fn_es_al_menos_supervisor()));

comment on policy p_inventory_update_umbrales on public.inventory is
  'Solo min_stock/max_stock son editables por columna (ver el GRANT de arriba). quantity/qty_reserved/qty_incoming siguen sin ningún grant de UPDATE: ni esta política los alcanza.';


-- =============================================================================
--  MIGRACIÓN 06 — CREAR EL PRIMER REGISTRO DE INVENTARIO DE UN ARTÍCULO
--
--  `inventory` solo tiene política de SELECT (migración 03) y ningún GRANT de
--  INSERT: a propósito, para que la única forma de que exista stock sea pasar
--  por una función revisada, nunca un INSERT/UPDATE suelto del cliente. Pero
--  el README pide poder "crear registros de inventario" para un artículo
--  nuevo, y hoy no hay ningún camino para eso desde el cliente.
--
--  La resuelve una función SECURITY DEFINER más — mismo patrón que aprobar,
--  ejecutar, rechazar. Si se carga una cantidad inicial mayor a cero (por
--  ejemplo, al digitalizar un artículo que físicamente ya está en el
--  almacén), queda su asiento en stock_ledger: ninguna unidad de stock existe
--  sin un origen auditable, tampoco esta.
--
--  Requiere 01-05. Idempotente.
-- =============================================================================

create or replace function public.crear_registro_inventario(
  p_item_id      uuid,
  p_warehouse_code text,
  p_quantity     integer default 0,
  p_min_stock    integer default 0,
  p_max_stock    integer default null
)
returns public.inventory
language plpgsql
security definer
set search_path = public
as $$
declare
  v_wh_id uuid;
  v_inv   public.inventory;
  v_actor uuid;
begin
  perform public.fn_exigir_rol('SUPERVISOR', 'JEFE');
  v_actor := public.actor_actual();

  if p_quantity < 0 then
    raise exception 'La cantidad inicial no puede ser negativa.';
  end if;

  select id into v_wh_id from public.warehouses where code = p_warehouse_code;
  if v_wh_id is null then
    raise exception 'No existe el almacén %.', p_warehouse_code;
  end if;

  if exists (select 1 from public.inventory where item_id = p_item_id and warehouse_id = v_wh_id) then
    raise exception 'Este artículo ya tiene un registro de inventario en ese almacén. Edítalo en vez de crear otro.';
  end if;

  insert into public.inventory (item_id, warehouse_id, quantity, min_stock, max_stock)
  values (p_item_id, v_wh_id, p_quantity, p_min_stock, p_max_stock)
  returning * into v_inv;

  -- Ninguna unidad de stock existe sin asiento en el kardex, tampoco la
  -- carga inicial: si el artículo ya tenía existencias físicas al
  -- digitalizarlo, esto lo deja igual de trazable que un movimiento normal.
  if p_quantity > 0 then
    insert into public.stock_ledger (item_id, warehouse_id, qty_delta, qty_before, qty_after, executed_by, notes)
    values (p_item_id, v_wh_id, p_quantity, 0, p_quantity, v_actor, 'Carga inicial de inventario (artículo nuevo)');
  end if;

  return v_inv;
end;
$$;

grant execute on function public.crear_registro_inventario(uuid, text, integer, integer, integer) to authenticated;

comment on function public.crear_registro_inventario is
  'Único camino para que exista una fila de inventory: SUPERVISOR+ , dispara un asiento en stock_ledger si arranca con cantidad > 0.';


-- =============================================================================
--  MIGRACIÓN 07 — v_mapa_almacen: exponer los IDs que la UI necesita
--
--  La vista original (Fase 1) traía todo lo necesario para LEER el mapa, pero
--  nada para ACTUAR sobre él: sin position.id no hay forma de decirle a
--  asignarPosicion() cuál posición usar, y sin position_assignments.id no hay
--  forma de decirle a liberarPosicion() cuál asignación cerrar. Se descubrió
--  al construir la pantalla de "Mapa del almacén" — la vista se quedó corta
--  para lo que el CASO realmente pedía (poder actuar sobre el mapa, no solo
--  mirarlo). También se agrega el nivel (regla infantil/adulto de la
--  migración 04) y el público del producto, para poder mostrar y validar esa
--  regla directamente en el mapa.
--
--  Requiere 01-06. Idempotente.
--
--  Nota: es DROP + CREATE, no CREATE OR REPLACE. Postgres solo permite
--  REPLACE si las columnas existentes conservan su nombre y su posición —
--  como position_id se agrega AL PRINCIPIO (no al final), REPLACE lo rechaza
--  con "cannot change name of view column". Ninguna otra migración depende de
--  esta vista (no hay FKs sobre vistas), así que recrearla es seguro.
-- =============================================================================

drop view if exists public.v_mapa_almacen;

create view public.v_mapa_almacen as
select
  pos.id            as position_id,
  w.code            as almacen_code,
  w.name            as almacen,
  r.code            as rack,
  pos.code          as posicion,
  pos.level,
  pos.capacity_units,
  pa.id             as assignment_id,
  pa.status         as estado_ocupacion,   -- NULL = libre
  pa.quantity       as unidades,
  pa.item_id,
  it.sku,
  pr.name           as producto,
  it.size_label     as talla,
  pr.audience,
  pa.assigned_at
from public.positions pos
join public.racks      r on r.id = pos.rack_id
join public.warehouses w on w.id = r.warehouse_id
left join public.position_assignments pa
       on pa.position_id = pos.id
      and pa.status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
left join public.inventory_items it on it.id = pa.item_id
left join public.products        pr on pr.id = it.product_id;

alter view public.v_mapa_almacen set (security_invoker = on);

comment on view public.v_mapa_almacen is
  'Mapa completo del almacén: todas las posiciones, libres y ocupadas, con los IDs necesarios para actuar (asignar/liberar), no solo para mostrar.';


-- =============================================================================
--  MIGRACIÓN 08 — GRAFO DEL ALMACÉN: COORDENADAS REALES Y RUTA MÁS CORTA
--
--  Pedido del jefe: posiciones exactas (no "tarjetas en fila") y poder
--  calcular la ruta más corta entre dos puntos. Se modela el almacén como un
--  GRAFO: cada rack (la unidad por la que realmente se camina, no cada
--  posición individual) es un nodo con coordenadas X/Y reales, más un nodo
--  "ENTRADA" por almacén. Los pasillos caminables son las aristas, con su
--  distancia. El algoritmo de ruta (Dijkstra) corre en el cliente — el grafo
--  es chico (≤7 nodos por almacén) y así queda visible/explicable en la
--  sustentación, no escondido en una función opaca.
--
--  Fuera de alcance a propósito: no se sube ninguna imagen/plano para que el
--  sistema "detecte" racks solo — eso es un problema de visión por
--  computadora, no de bases de datos, y no era razonable para el tiempo
--  disponible. Las coordenadas son reales pero se cargan a mano (como se
--  cargaría un plano en cualquier WMS real la primera vez).
--
--  Requiere 01-07. Idempotente.
-- =============================================================================


-- =============================================================================
--  BLOQUE A — TABLAS DEL GRAFO
-- =============================================================================
create table if not exists public.warehouse_nodes (
  id           uuid primary key default gen_random_uuid(),
  warehouse_id uuid        not null references public.warehouses (id) on delete cascade,
  rack_id      uuid        unique references public.racks (id) on delete cascade,
  node_type    text        not null check (node_type in ('ENTRADA', 'RACK')),
  code         text        not null,
  x_coord      numeric     not null,
  y_coord      numeric     not null,
  created_at   timestamptz not null default now(),
  constraint uq_node_almacen_code unique (warehouse_id, code),
  constraint ck_node_rack_consistente check (
    (node_type = 'RACK'    and rack_id is not null)
    or
    (node_type = 'ENTRADA' and rack_id is null)
  )
);
comment on table public.warehouse_nodes is
  'Nodos del grafo de ruteo: un nodo ENTRADA por almacén + un nodo por rack (el rack, no cada posición, es la unidad por la que se camina).';

-- Aristas NO dirigidas (un pasillo se camina en los dos sentidos): el par se
-- guarda siempre ordenado (least, greatest) y el índice único de abajo impide
-- cargar la misma arista dos veces sin importar en qué orden se inserte.
create table if not exists public.warehouse_edges (
  id          uuid primary key default gen_random_uuid(),
  node_a_id   uuid    not null references public.warehouse_nodes (id) on delete cascade,
  node_b_id   uuid    not null references public.warehouse_nodes (id) on delete cascade,
  distancia   numeric not null check (distancia > 0),
  created_at  timestamptz not null default now(),
  constraint ck_edge_no_autolazo check (node_a_id <> node_b_id)
);
create unique index if not exists uq_edge_par
  on public.warehouse_edges (least(node_a_id, node_b_id), greatest(node_a_id, node_b_id));

comment on table public.warehouse_edges is
  'Pasillos caminables entre dos nodos. La distancia es la que recorre una persona, no necesariamente la línea recta.';

create index if not exists ix_nodes_warehouse on public.warehouse_nodes (warehouse_id);
create index if not exists ix_edges_node_a    on public.warehouse_edges (node_a_id);
create index if not exists ix_edges_node_b    on public.warehouse_edges (node_b_id);


-- =============================================================================
--  BLOQUE B — RLS
-- =============================================================================
alter table public.warehouse_nodes enable row level security;
alter table public.warehouse_edges enable row level security;

-- Igual que el resto del mapa: cualquier perfil activo lo puede leer (hace
-- falta para calcular una ruta), pero definir la topología del almacén es
-- trabajo de SUPERVISOR+, no algo que un operario deba poder tocar.
drop policy if exists p_nodes_select on public.warehouse_nodes;
create policy p_nodes_select on public.warehouse_nodes
  for select to authenticated using ((select public.fn_rol_actual()) is not null);
drop policy if exists p_nodes_write on public.warehouse_nodes;
create policy p_nodes_write on public.warehouse_nodes
  for insert to authenticated with check ((select public.fn_es_al_menos_supervisor()));
drop policy if exists p_nodes_update on public.warehouse_nodes;
create policy p_nodes_update on public.warehouse_nodes
  for update to authenticated
  using ((select public.fn_es_al_menos_supervisor()))
  with check ((select public.fn_es_al_menos_supervisor()));

drop policy if exists p_edges_select on public.warehouse_edges;
create policy p_edges_select on public.warehouse_edges
  for select to authenticated using ((select public.fn_rol_actual()) is not null);
drop policy if exists p_edges_write on public.warehouse_edges;
create policy p_edges_write on public.warehouse_edges
  for insert to authenticated with check ((select public.fn_es_al_menos_supervisor()));

revoke all on public.warehouse_nodes from anon;
revoke all on public.warehouse_edges from anon;
-- Sin política de DELETE en ninguna de las dos: mismo criterio que el resto
-- del sistema — la topología no se borra, se corrige con un UPDATE.


-- =============================================================================
--  BLOQUE C — GRAFO DE LOS 3 ALMACENES (coordenadas reales de referencia)
-- =============================================================================
-- Layout de ALM-A: dos filas de racks con la entrada abajo al centro.
--
--     RACK-06   RACK-07   RACK-08          y=50
--     RACK-01   RACK-03   RACK-05          y=150
--              ENTRADA                     y=250
--     x=50      x=150     x=250
do $$
begin
  if exists (select 1 from public.warehouse_nodes) then
    raise notice 'El grafo de almacenes ya estaba cargado, no se duplica.';
    return;
  end if;

  insert into public.warehouse_nodes (warehouse_id, rack_id, node_type, code, x_coord, y_coord)
  select w.id, r.id, 'RACK', r.code, x.xc, x.yc
    from (values
      ('ALM-A','RACK-01', 50, 150), ('ALM-A','RACK-03',150, 150), ('ALM-A','RACK-05',250, 150),
      ('ALM-A','RACK-06', 50,  50), ('ALM-A','RACK-07',150,  50), ('ALM-A','RACK-08',250,  50),
      ('BOD-B','RACK-01',100,  50), ('BOD-B','RACK-02',200,  50), ('BOD-B','RACK-04',300,  50),
      ('BOD-B','RACK-07',200, 150),
      ('BOD-C','RACK-02',100,  50), ('BOD-C','RACK-06',200,  50), ('BOD-C','RACK-07',150, 150)
    ) as x(wh_code, rack_code, xc, yc)
    join public.warehouses w on w.code = x.wh_code
    join public.racks      r on r.warehouse_id = w.id and r.code = x.rack_code;

  insert into public.warehouse_nodes (warehouse_id, rack_id, node_type, code, x_coord, y_coord)
  select w.id, null, 'ENTRADA', 'ENTRADA', x.xc, x.yc
    from (values ('ALM-A',150,250), ('BOD-B',0,50), ('BOD-C',0,50)) as x(wh_code, xc, yc)
    join public.warehouses w on w.code = x.wh_code;

  raise notice 'Nodos del grafo cargados: % ', (select count(*) from public.warehouse_nodes);
end;
$$;

-- Aristas: se calcula la distancia real (euclidiana) entre los dos nodos en
-- vez de tipearla a mano, para que no se desincronice de las coordenadas de
-- arriba si alguna vez cambian.
do $$
begin
  if exists (select 1 from public.warehouse_edges) then
    raise notice 'Las aristas ya estaban cargadas, no se duplican.';
    return;
  end if;

  insert into public.warehouse_edges (node_a_id, node_b_id, distancia)
  select na.id, nb.id, sqrt(power(na.x_coord - nb.x_coord, 2) + power(na.y_coord - nb.y_coord, 2))
    from (values
      -- ALM-A: entrada a la fila de abajo, fila de abajo entre sí, y cada
      -- rack de abajo con el que tiene encima (pasillo vertical).
      ('ALM-A','ENTRADA','RACK-01'), ('ALM-A','ENTRADA','RACK-03'), ('ALM-A','ENTRADA','RACK-05'),
      ('ALM-A','RACK-01','RACK-03'), ('ALM-A','RACK-03','RACK-05'),
      ('ALM-A','RACK-01','RACK-06'), ('ALM-A','RACK-03','RACK-07'), ('ALM-A','RACK-05','RACK-08'),
      ('ALM-A','RACK-06','RACK-07'), ('ALM-A','RACK-07','RACK-08'),
      -- BOD-B: una fila principal + RACK-07 colgando de RACK-02.
      ('BOD-B','ENTRADA','RACK-01'), ('BOD-B','RACK-01','RACK-02'), ('BOD-B','RACK-02','RACK-04'),
      ('BOD-B','RACK-02','RACK-07'),
      -- BOD-C: triángulo simple, más de un camino posible (bueno para
      -- demostrar que Dijkstra elige el corto, no el primero que encuentra).
      ('BOD-C','ENTRADA','RACK-02'), ('BOD-C','RACK-02','RACK-06'),
      ('BOD-C','RACK-02','RACK-07'), ('BOD-C','RACK-06','RACK-07')
    ) as x(wh_code, code_a, code_b)
    join public.warehouses      w  on w.code = x.wh_code
    join public.warehouse_nodes na on na.warehouse_id = w.id and na.code = x.code_a
    join public.warehouse_nodes nb on nb.warehouse_id = w.id and nb.code = x.code_b;

  raise notice 'Aristas cargadas: %', (select count(*) from public.warehouse_edges);
end;
$$;


-- =============================================================================
--  VERIFICACIÓN
-- =============================================================================
select
  w.code as almacen,
  count(distinct n.id) as nodos,
  count(distinct e.id) as aristas
from public.warehouses w
left join public.warehouse_nodes n on n.warehouse_id = w.id
left join public.warehouse_edges e on e.node_a_id = n.id
group by w.code
order by w.code;
-- Esperado: ALM-A 7 nodos/10 aristas, BOD-B 5 nodos/4 aristas, BOD-C 4 nodos/4 aristas.


-- =============================================================================
--  MIGRACIÓN 09 — EL ALMACÉN COMO GEOMETRÍA: GRILLA, RACKS CON FORMA Y A*
--
--  Cambio de enfoque respecto de la migración 08. Ahí el grafo de pasillos se
--  declaraba a mano (el nodo A conecta con el nodo B). Eso funciona mientras
--  nadie mueva nada — pero si el layout se edita visualmente (arrastrar racks
--  para armar el almacén como es en la realidad), un grafo escrito a mano
--  queda desactualizado en el primer movimiento.
--
--  El modelo correcto para un layout editable es GEOMETRÍA, no topología:
--    - El almacén es una grilla de celdas (grid_ancho x grid_alto), 1 celda ≈ 1 m.
--    - Cada rack es un RECTÁNGULO sobre esa grilla: ocupa celdas y las bloquea.
--    - La ruta más corta se calcula con A* sobre las celdas libres, esquivando
--      los rectángulos. Al mover un rack las rutas cambian solas: no queda
--      ninguna topología que mantener sincronizada a mano.
--
--  Por eso esta migración ELIMINA warehouse_nodes y warehouse_edges. Solo
--  contenían la topología semilla que cargó la propia migración 08 — ningún
--  dato ingresado por un usuario.
--
--  Requiere 01-08. Idempotente.
-- =============================================================================


-- =============================================================================
--  BLOQUE A — DIMENSIONES DEL ALMACÉN Y GEOMETRÍA DE CADA RACK
-- =============================================================================
alter table public.warehouses
  add column if not exists grid_ancho integer not null default 40,
  add column if not exists grid_alto  integer not null default 30,
  add column if not exists entrada_x  integer not null default 20,
  add column if not exists entrada_y  integer not null default 28;

alter table public.racks
  add column if not exists grid_x     integer,
  add column if not exists grid_y     integer,
  add column if not exists grid_ancho integer not null default 14,
  add column if not exists grid_alto  integer not null default 2;

comment on column public.racks.grid_x is
  'Esquina superior izquierda del rack sobre la grilla del almacén. El rack ocupa (grid_ancho x grid_alto) celdas y las bloquea para el cálculo de rutas.';
comment on column public.warehouses.grid_ancho is
  'Ancho del piso en celdas (1 celda ≈ 1 metro). El editor de layout trabaja sobre esta grilla.';


-- =============================================================================
--  BLOQUE B — LAYOUT INICIAL REALISTA (dos columnas de racks con pasillos)
-- =============================================================================
-- Se aplica ANTES de crear el trigger anti-solape a propósito: mover los racks
-- de a uno los haría pisarse transitoriamente y el trigger abortaría la
-- migración. El layout que se escribe acá es válido por construcción:
--
--     x:  3────17    21────35        (racks de 14 celdas de ancho)
--     y:3  ███████    ███████        fila 1
--     y:9  ███████    ███████        fila 2   (pasillo horizontal entre filas)
--     y:15 ███████    ███████        fila 3
--     y:28        ▲ ENTRADA          (pasillo perimetral libre)
do $$
declare
  r record;
  v_i integer;
begin
  for r in
    select rk.id,
           (row_number() over (partition by rk.warehouse_id order by rk.code) - 1)::int as n
      from public.racks rk
  loop
    v_i := r.n;
    update public.racks
       set grid_x     = 3 + (v_i % 2) * 18,
           grid_y     = 3 + (v_i / 2) * 6,
           grid_ancho = 14,
           grid_alto  = 2
     where id = r.id;
  end loop;

  update public.warehouses set entrada_x = 20, entrada_y = 28;
  raise notice 'Layout inicial aplicado a % racks.', (select count(*) from public.racks);
end;
$$;

alter table public.racks
  alter column grid_x set not null,
  alter column grid_y set not null;

alter table public.racks drop constraint if exists ck_racks_geometria;
alter table public.racks
  add constraint ck_racks_geometria check (
    grid_x >= 0 and grid_y >= 0 and grid_ancho between 1 and 60 and grid_alto between 1 and 60
  );


-- =============================================================================
--  BLOQUE C — UN RACK NO PUEDE SALIRSE DEL PLANO NI PISAR A OTRO
-- =============================================================================
-- Mismo criterio que el resto del sistema: la regla vive en la base, no en el
-- editor. Si el arrastre del editor tiene un bug, la base no deja guardar un
-- layout imposible.
create or replace function public.fn_validar_geometria_rack()
returns trigger
language plpgsql
as $$
declare
  v_ancho_alm integer;
  v_alto_alm  integer;
  v_conflicto text;
begin
  select grid_ancho, grid_alto into v_ancho_alm, v_alto_alm
    from public.warehouses where id = new.warehouse_id;

  if new.grid_x + new.grid_ancho > v_ancho_alm or new.grid_y + new.grid_alto > v_alto_alm then
    raise exception 'El rack % no cabe: se sale del plano del almacén (% x % celdas).',
      new.code, v_ancho_alm, v_alto_alm
      using errcode = 'check_violation';
  end if;

  -- Dos rectángulos se pisan solo si se solapan en LOS DOS ejes a la vez.
  select code into v_conflicto
    from public.racks
   where warehouse_id = new.warehouse_id
     and id <> new.id
     and new.grid_x < grid_x + grid_ancho
     and grid_x     < new.grid_x + new.grid_ancho
     and new.grid_y < grid_y + grid_alto
     and grid_y     < new.grid_y + new.grid_alto
   limit 1;

  if v_conflicto is not null then
    raise exception 'El rack % se superpone con el rack %. Muévelo a un espacio libre.',
      new.code, v_conflicto
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_racks_geometria on public.racks;
create trigger trg_racks_geometria
  before insert or update of grid_x, grid_y, grid_ancho, grid_alto on public.racks
  for each row execute function public.fn_validar_geometria_rack();


-- =============================================================================
--  BLOQUE D — FUERA EL GRAFO DECLARADO A MANO
-- =============================================================================
drop table if exists public.warehouse_edges;
drop table if exists public.warehouse_nodes;


-- =============================================================================
--  VERIFICACIÓN
-- =============================================================================
select
  w.code as almacen,
  w.grid_ancho || ' x ' || w.grid_alto  as plano,
  w.entrada_x || ',' || w.entrada_y      as entrada,
  count(r.id)                            as racks,
  coalesce(max(r.grid_x + r.grid_ancho), 0) as borde_derecho,
  coalesce(max(r.grid_y + r.grid_alto), 0)  as borde_inferior
from public.warehouses w
left join public.racks r on r.warehouse_id = w.id
group by w.code, w.grid_ancho, w.grid_alto, w.entrada_x, w.entrada_y
order by w.code;
-- Esperado: 3 almacenes en 40x30, entrada 20,28, y ningún borde pasando de 40/30.


-- =============================================================================
--  MIGRACIÓN 10 — CREAR Y ELIMINAR RACKS DESDE EL EDITOR DE PLANO
--
--  Mover y redimensionar un rack ya funciona con un UPDATE normal (la
--  migración 09 puso el trigger que valida geometría). Crear y eliminar, no:
--    - Crear un rack "a secas" deja un rack sin posiciones, o sea un mueble
--      que no puede guardar nada. Debe crear también sus posiciones, con su
--      nivel — y el nivel es el que decide si ahí puede ir calzado infantil
--      (migración 04). Eso son dos tablas: va en una función, atómico.
--    - Eliminar un rack borraría posiciones que pueden tener historial. La
--      función revisa primero y se niega con un mensaje claro en vez de
--      dejar que reviente una FK.
--
--  Requiere 01-09. Idempotente.
-- =============================================================================


-- =============================================================================
--  BLOQUE A — CORRECCIÓN: LA LETRA DE LA POSICIÓN SALE DEL FINAL DEL ALMACÉN
-- =============================================================================
-- seed.sql escribió a mano 'C-02-03' para BOD-C (correcto), pero los seeds 02
-- y 03 generaron el prefijo con left(code,1), que para 'BOD-C' da 'B'. Quedaron
-- posiciones 'B-07-xx' dentro de BOD-C. No rompía nada (el código es único por
-- rack, no global) pero es engañoso al leer el mapa. La letra correcta es la
-- última del código de almacén: ALM-A→A, BOD-B→B, BOD-C→C.
update public.positions p
   set code = right(w.code, 1) || substring(p.code from 2)
  from public.racks r
  join public.warehouses w on w.id = r.warehouse_id
 where r.id = p.rack_id
   and left(p.code, 1) <> right(w.code, 1);


-- =============================================================================
--  BLOQUE B — CREAR UN RACK CON SUS POSICIONES
-- =============================================================================
create or replace function public.crear_rack(
  p_warehouse_code text,
  p_code           text,
  p_grid_x         integer,
  p_grid_y         integer,
  p_grid_ancho     integer,
  p_grid_alto      integer,
  p_nivel          integer default 2,
  p_num_posiciones integer default 0
)
returns public.racks
language plpgsql
security definer
set search_path = public
as $$
declare
  v_wh    public.warehouses;
  v_rack  public.racks;
  v_letra text;
  v_num   text;
  i       integer;
begin
  perform public.fn_exigir_rol('SUPERVISOR', 'JEFE');

  -- El código se exige con formato RACK-NN porque de ahí sale el número que
  -- va en el código de cada posición (A-07-01). Sin formato fijo, los códigos
  -- de posición dejarían de ser predecibles.
  if p_code !~ '^RACK-[0-9]{2}$' then
    raise exception 'El código del rack debe tener el formato RACK-NN (por ejemplo RACK-09). Recibido: %.', p_code;
  end if;

  if p_nivel < 1 or p_nivel > 9 then
    raise exception 'El nivel debe estar entre 1 y 9. Recuerda que el nivel 1 es exclusivo de calzado infantil.';
  end if;

  if p_num_posiciones < 0 or p_num_posiciones > 99 then
    raise exception 'El número de posiciones debe estar entre 0 y 99 (el código de posición solo tiene dos dígitos).';
  end if;

  select * into v_wh from public.warehouses where code = p_warehouse_code;
  if v_wh.id is null then
    raise exception 'No existe el almacén %.', p_warehouse_code;
  end if;

  -- El trigger trg_racks_geometria valida acá que quepa y que no pise a otro.
  insert into public.racks (warehouse_id, code, grid_x, grid_y, grid_ancho, grid_alto)
  values (v_wh.id, p_code, p_grid_x, p_grid_y, p_grid_ancho, p_grid_alto)
  returning * into v_rack;

  v_letra := right(v_wh.code, 1);
  v_num   := right(p_code, 2);

  for i in 1..p_num_posiciones loop
    insert into public.positions (rack_id, code, capacity_units, level, slot)
    values (v_rack.id, v_letra || '-' || v_num || '-' || lpad(i::text, 2, '0'), 200, p_nivel, i);
  end loop;

  return v_rack;
end;
$$;

grant execute on function public.crear_rack(text, text, integer, integer, integer, integer, integer, integer) to authenticated;


-- =============================================================================
--  BLOQUE C — ELIMINAR UN RACK (solo si no tiene historial que perder)
-- =============================================================================
-- Criterio, coherente con el resto del sistema: un rack recién creado por
-- error se borra sin drama; uno que ya guardó mercadería NO, porque borrar sus
-- posiciones dejaría movimientos y asientos del kardex apuntando a la nada.
create or replace function public.eliminar_rack(p_rack_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rack       public.racks;
  v_ocupadas   integer;
  v_historial  integer;
begin
  perform public.fn_exigir_rol('SUPERVISOR', 'JEFE');

  select * into v_rack from public.racks where id = p_rack_id;
  if v_rack.id is null then
    raise exception 'El rack no existe.';
  end if;

  select count(*) into v_ocupadas
    from public.position_assignments pa
    join public.positions p on p.id = pa.position_id
   where p.rack_id = p_rack_id
     and pa.status in ('RESERVADA', 'OCUPADA', 'EN_PICKING');

  if v_ocupadas > 0 then
    raise exception 'No se puede eliminar %: tiene % posición(es) con mercadería ubicada o reservada. Libéralas primero.',
      v_rack.code, v_ocupadas;
  end if;

  -- Historial: asignaciones ya liberadas, movimientos o asientos del kardex
  -- que apunten a alguna posición de este rack.
  select
    (select count(*) from public.position_assignments pa
       join public.positions p on p.id = pa.position_id where p.rack_id = p_rack_id)
  + (select count(*) from public.inventory_movements m
       join public.positions p on p.id = m.position_id where p.rack_id = p_rack_id)
  + (select count(*) from public.stock_ledger sl
       join public.positions p on p.id = sl.position_id where p.rack_id = p_rack_id)
  into v_historial;

  if v_historial > 0 then
    raise exception 'No se puede eliminar %: sus posiciones tienen historial de movimientos. Borrarlo dejaría el kardex sin rastro de dónde ocurrieron.',
      v_rack.code;
  end if;

  delete from public.positions where rack_id = p_rack_id;
  delete from public.racks where id = p_rack_id;

  return jsonb_build_object('estado', 'ELIMINADO', 'mensaje', 'Rack ' || v_rack.code || ' eliminado del plano.');
end;
$$;

grant execute on function public.eliminar_rack(uuid) to authenticated;


-- =============================================================================
--  VERIFICACIÓN
-- =============================================================================
select
  w.code as almacen,
  count(distinct r.id) as racks,
  count(p.id)          as posiciones,
  count(*) filter (where left(p.code, 1) <> right(w.code, 1)) as posiciones_con_letra_incorrecta
from public.warehouses w
left join public.racks     r on r.warehouse_id = w.id
left join public.positions p on p.rack_id = r.id
group by w.code
order by w.code;
-- Esperado: posiciones_con_letra_incorrecta = 0 en los tres almacenes.




-- =============================================================================
--  MIGRACIÓN 11 — EL PLANO REALISTA: TAMAÑO DEL ALMACÉN Y CAPACIDAD EN CAJAS
--
--  Dos huecos que quedaron del editor de plano (migraciones 09 y 10):
--
--  1. El almacén tenía un tamaño fijo (40 x 30, escritos por la migración 09).
--     Un almacén real se mide una vez y se carga; el editor no servía si el
--     local no medía exactamente eso.
--
--  2. `positions.capacity_units` era ficción: crear_rack escribía 200 en cada
--     posición y los seeds 200/150, números inventados. Pero el trigger de la
--     migración 02 YA valida contra ese número, así que la validación estaba
--     comparando stock real contra un dato imaginario.
--
--  Acá capacity_units pasa a salir de la geometría: un rack de N x M metros
--  con P niveles tiene un volumen de estantería concreto, y una caja de
--  zapatos tiene un tamaño concreto. Cuántas caben es una división, no una
--  opinión. El nivel 1 (infantil, migración 04) rinde más porque la caja de
--  niño es más chica: la regla de negocio y la física coinciden.
--
--  Requiere 01-10. Idempotente.
-- =============================================================================


-- =============================================================================
--  BLOQUE A — EL TAMAÑO DEL ALMACÉN ES UN DATO, NO UNA CONSTANTE
-- =============================================================================
-- El tope de 80 celdas por lado no es decorativo: la ruta más corta se calcula
-- con A* sobre la grilla (js/plano-editor.js) y su cola de prioridad es una
-- búsqueda lineal del mínimo. A 80 x 80 son 6 400 celdas, que sigue siendo
-- instantáneo; dejarlo abierto convertiría "calcular ruta" en un cuelgue del
-- navegador. El piso de 10 evita un almacén donde no entre ni un rack.
alter table public.warehouses drop constraint if exists ck_warehouses_grilla;
alter table public.warehouses
  add constraint ck_warehouses_grilla check (
    grid_ancho between 10 and 80
    and grid_alto between 10 and 80
    and entrada_x >= 0 and entrada_x < grid_ancho
    and entrada_y >= 0 and entrada_y < grid_alto
  );

create or replace function public.redimensionar_almacen(
  p_warehouse_code text,
  p_grid_ancho     integer,
  p_grid_alto      integer
)
returns public.warehouses
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_wh     public.warehouses;
  v_afuera text;
begin
  perform public.fn_exigir_rol('SUPERVISOR', 'JEFE');

  if p_grid_ancho not between 10 and 80 or p_grid_alto not between 10 and 80 then
    raise exception 'El almacén debe medir entre 10 y 80 m por lado. Se pidió % x %.',
      p_grid_ancho, p_grid_alto;
  end if;

  select * into v_wh from public.warehouses where code = p_warehouse_code;
  if v_wh.id is null then
    raise exception 'No existe el almacén %.', p_warehouse_code;
  end if;

  -- Achicar el plano por debajo de un rack existente lo dejaría "fuera del
  -- almacén". Mover racks solo para que quepan sería decidir por el usuario
  -- dónde va su mercadería: se rechaza y se dice cuáles estorban.
  select string_agg(code, ', ' order by code) into v_afuera
    from public.racks
   where warehouse_id = v_wh.id
     and (grid_x + grid_ancho > p_grid_ancho or grid_y + grid_alto > p_grid_alto);

  if v_afuera is not null then
    raise exception 'No se puede achicar % a % x % m: % quedaría(n) fuera del plano. Muévelos primero.',
      v_wh.code, p_grid_ancho, p_grid_alto, v_afuera;
  end if;

  -- La entrada sí se reacomoda sola: es un punto de referencia del plano, no
  -- mercadería de nadie.
  update public.warehouses
     set grid_ancho = p_grid_ancho,
         grid_alto  = p_grid_alto,
         entrada_x  = least(entrada_x, p_grid_ancho - 1),
         entrada_y  = least(entrada_y, p_grid_alto - 1),
         updated_at = now()
   where id = v_wh.id
  returning * into v_wh;

  return v_wh;
end;
$fn$;

grant execute on function public.redimensionar_almacen(text, integer, integer) to authenticated;


-- =============================================================================
--  BLOQUE B — CUÁNTAS CAJAS ENTRAN: LA FÍSICA DEL ESTANTE
-- =============================================================================
-- Medidas de caja de calzado reales (largo x ancho x alto, en metros):
--   adulto    0.33 x 0.20 x 0.13
--   infantil  0.25 x 0.15 x 0.10   -> por eso el nivel 1 rinde casi el doble
-- Altura útil entre estantes: 0.45 m. Factor de aprovechamiento 0.85, el que
-- se usa en planificación de almacenes para descontar montantes, holguras y
-- el espacio que necesita la mano para sacar la caja.
create or replace function public.fn_cajas_en_slot(
  p_frente_m numeric,
  p_fondo_m  numeric,
  p_nivel    integer
)
returns integer
language sql
immutable
as $fn$
  select greatest(0, floor(
           floor(p_frente_m / c.largo)
         * floor(p_fondo_m  / c.ancho)
         * floor(0.45       / c.alto)
         * 0.85
         )::integer)
    from (select
            case when p_nivel = 1 then 0.25 else 0.33 end as largo,
            case when p_nivel = 1 then 0.15 else 0.20 end as ancho,
            case when p_nivel = 1 then 0.10 else 0.13 end as alto
         ) c;
$fn$;

comment on function public.fn_cajas_en_slot is
  'Cajas de calzado que entran en un casillero de p_frente_m x p_fondo_m en el nivel dado. El nivel 1 usa medidas de caja infantil (migración 04).';

-- Lo que el editor necesita ANTES de crear nada: "un rack de 14 x 2 m con 3
-- niveles y 7 posiciones por nivel, ¿cuánto guarda?". Vive en la base y no en
-- el JS para que la cifra que se muestra sea la misma que se va a grabar.
create or replace function public.estimar_capacidad_rack(
  p_grid_ancho      integer,
  p_grid_alto       integer,
  p_niveles         integer,
  p_slots_por_nivel integer
)
returns jsonb
language sql
immutable
as $fn$
  with medidas as (
    -- El frente es el lado largo (por donde se camina); el fondo, la
    -- profundidad del estante.
    select greatest(p_grid_ancho, p_grid_alto)::numeric as frente,
           least(p_grid_ancho, p_grid_alto)::numeric    as fondo,
           greatest(p_slots_por_nivel, 1)               as slots
  ),
  niveles as (
    select n.nivel,
           public.fn_cajas_en_slot(m.frente / m.slots, m.fondo, n.nivel) * m.slots as cajas
      from medidas m
      cross join generate_series(1, greatest(p_niveles, 1)) as n(nivel)
  )
  select jsonb_build_object(
    'frente',     (select frente from medidas),
    'fondo',      (select fondo  from medidas),
    'posiciones', greatest(p_niveles, 1) * greatest(p_slots_por_nivel, 1),
    'cajas',      (select sum(cajas) from niveles),
    'por_nivel',  (select jsonb_agg(jsonb_build_object('nivel', nivel, 'cajas', cajas) order by nivel) from niveles)
  );
$fn$;

grant execute on function public.estimar_capacidad_rack(integer, integer, integer, integer) to authenticated;


-- =============================================================================
--  BLOQUE C — CUÁNTOS PISOS TIENE EL RACK
-- =============================================================================
alter table public.racks
  add column if not exists niveles integer not null default 3;

alter table public.racks drop constraint if exists ck_racks_niveles;
alter table public.racks add constraint ck_racks_niveles check (niveles between 1 and 8);

comment on column public.racks.niveles is
  'Pisos de estantería del mueble. Propiedad física: junto con grid_ancho/grid_alto determina cuántas cajas entran. Las posiciones se reparten entre estos niveles.';

-- Los racks que ya existían: el nivel real se deduce de sus posiciones. Las
-- posiciones sin nivel declarado (los seeds las dejaron en NULL) son estantes
-- de adulto, así que van al nivel 2, nunca al 1 — el 1 está reservado para
-- calzado infantil y hoy no hay nada de eso ubicado ahí.
update public.positions set level = 2 where level is null;

update public.positions p
   set slot = s.orden
  from (select id, row_number() over (partition by rack_id, level order by code) as orden
          from public.positions) s
 where s.id = p.id and p.slot is distinct from s.orden;

update public.racks r
   set niveles = least(8, greatest(1, coalesce((select max(p.level) from public.positions p where p.rack_id = r.id), 3)));


-- =============================================================================
--  BLOQUE D — RECALCULAR LA CAPACIDAD DECLARADA A PARTIR DE LA GEOMETRÍA
-- =============================================================================
-- SECURITY DEFINER porque escribe en positions, que no tiene política de
-- UPDATE para authenticated (mismo criterio que crear_rack): la capacidad no
-- es un campo que se edite a mano, se deduce.
create or replace function public.fn_recalcular_capacidades(p_rack_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_frente numeric;
  v_fondo  numeric;
begin
  select greatest(grid_ancho, grid_alto), least(grid_ancho, grid_alto)
    into v_frente, v_fondo
    from public.racks where id = p_rack_id;

  update public.positions p
     set capacity_units = greatest(
           public.fn_cajas_en_slot(v_frente / n.slots, v_fondo, p.level),
           n.ocupado   -- nunca declarar menos de lo que ya hay adentro
         ),
         updated_at = now()
    from (
      select pp.id,
             count(*) over (partition by pp.level) as slots,
             (select coalesce(sum(pa.quantity), 0)
                from public.position_assignments pa
               where pa.position_id = pp.id
                 and pa.status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')) as ocupado
        from public.positions pp
       where pp.rack_id = p_rack_id
    ) n
   where n.id = p.id;
end;
$fn$;

-- Redimensionar un rack en el editor cambia cuántas cajas entran. Recalcular
-- desde el trigger evita que la UI tenga que acordarse de pedirlo.
create or replace function public.fn_racks_recalcular_capacidad()
returns trigger
language plpgsql
as $fn$
begin
  perform public.fn_recalcular_capacidades(new.id);
  return null;
end;
$fn$;

drop trigger if exists trg_racks_capacidad on public.racks;
create trigger trg_racks_capacidad
  after update of grid_ancho, grid_alto on public.racks
  for each row
  when (old.grid_ancho is distinct from new.grid_ancho or old.grid_alto is distinct from new.grid_alto)
  execute function public.fn_racks_recalcular_capacidad();


-- =============================================================================
--  BLOQUE E — DECLARAR NIVELES Y POSICIONES DE UN RACK
-- =============================================================================
-- Regla de oro: NUNCA se renumera una posición existente. El código de una
-- posición aparece en el kardex y en los movimientos; si 'A-03-02' pasara a
-- señalar otro casillero, el historial estaría mintiendo. Por eso esta función
-- solo AGREGA los casilleros que faltan (con el primer índice libre) y BORRA
-- los de niveles que se eliminan, negándose si tienen historial.
create or replace function public.fn_configurar_posiciones(
  p_rack_id         uuid,
  p_niveles         integer,
  p_slots_por_nivel integer
)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_rack   public.racks;
  v_letra  text;
  v_num    text;
  v_pos    record;
  v_nivel  integer;
  v_faltan integer;
  v_idx    integer;
begin
  if p_niveles not between 1 and 8 then
    raise exception 'Un rack tiene entre 1 y 8 niveles. Se pidieron %.', p_niveles;
  end if;
  if p_slots_por_nivel not between 1 and 40 then
    raise exception 'Las posiciones por nivel deben estar entre 1 y 40. Se pidieron %.', p_slots_por_nivel;
  end if;
  if p_niveles * p_slots_por_nivel > 99 then
    raise exception '% niveles x % posiciones son % casilleros y el código de posición solo admite 99. Divídelo en dos racks.',
      p_niveles, p_slots_por_nivel, p_niveles * p_slots_por_nivel;
  end if;

  select * into v_rack from public.racks where id = p_rack_id;
  if v_rack.id is null then
    raise exception 'El rack no existe.';
  end if;

  select right(w.code, 1) into v_letra from public.warehouses w where w.id = v_rack.warehouse_id;
  v_num := right(v_rack.code, 2);

  -- Niveles que se van: solo si están vacíos de presente y de pasado.
  for v_pos in
    select p.id, p.code from public.positions p
     where p.rack_id = p_rack_id and p.level > p_niveles
  loop
    if exists (select 1 from public.position_assignments where position_id = v_pos.id)
       or exists (select 1 from public.inventory_movements where position_id = v_pos.id)
       or exists (select 1 from public.stock_ledger      where position_id = v_pos.id)
    then
      raise exception 'No se puede bajar % a % niveles: la posición % tiene historial de movimientos.',
        v_rack.code, p_niveles, v_pos.code;
    end if;
    delete from public.positions where id = v_pos.id;
  end loop;

  -- Niveles que faltan o están incompletos.
  for v_nivel in 1..p_niveles loop
    select p_slots_por_nivel - count(*) into v_faltan
      from public.positions where rack_id = p_rack_id and level = v_nivel;

    while v_faltan > 0 loop
      -- Primer índice libre del rack: así los códigos ya emitidos no se tocan.
      select min(g.n) into v_idx
        from generate_series(1, 99) as g(n)
       where not exists (
         select 1 from public.positions
          where rack_id = p_rack_id
            and code = v_letra || '-' || v_num || '-' || lpad(g.n::text, 2, '0')
       );

      if v_idx is null then
        raise exception 'El rack % ya usó los 99 códigos de posición disponibles.', v_rack.code;
      end if;

      insert into public.positions (rack_id, code, capacity_units, level, slot)
      values (p_rack_id,
              v_letra || '-' || v_num || '-' || lpad(v_idx::text, 2, '0'),
              0, v_nivel,
              p_slots_por_nivel - v_faltan + 1);

      v_faltan := v_faltan - 1;
    end loop;
  end loop;

  update public.racks set niveles = p_niveles, updated_at = now() where id = p_rack_id;
  perform public.fn_recalcular_capacidades(p_rack_id);
end;
$fn$;

-- Entrada pública: el panel del editor la llama al cambiar niveles/posiciones.
create or replace function public.configurar_rack(
  p_rack_id         uuid,
  p_niveles         integer,
  p_slots_por_nivel integer
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_rack  public.racks;
  v_total integer;
  v_cajas integer;
begin
  perform public.fn_exigir_rol('SUPERVISOR', 'JEFE');
  perform public.fn_configurar_posiciones(p_rack_id, p_niveles, p_slots_por_nivel);

  select * into v_rack from public.racks where id = p_rack_id;
  select count(*), coalesce(sum(capacity_units), 0) into v_total, v_cajas
    from public.positions where rack_id = p_rack_id;

  return jsonb_build_object(
    'estado',     'OK',
    'posiciones', v_total,
    'cajas',      v_cajas,
    'mensaje',    v_rack.code || ': ' || p_niveles || ' niveles, ' || v_total ||
                  ' posiciones, capacidad ' || v_cajas || ' cajas.'
  );
end;
$fn$;

grant execute on function public.configurar_rack(uuid, integer, integer) to authenticated;


-- =============================================================================
--  BLOQUE F — crear_rack AHORA PIENSA EN PISOS, NO EN UN NIVEL SUELTO
-- =============================================================================
-- La versión de la migración 10 recibía UN nivel y N posiciones sueltas: un
-- rack de un solo piso. Un rack real tiene varios, y el nivel 1 de cualquiera
-- de ellos es el que admite calzado infantil. Se cambian los nombres de los
-- parámetros, así que hay que soltar la función anterior (Postgres no permite
-- renombrar parámetros con CREATE OR REPLACE).
drop function if exists public.crear_rack(text, text, integer, integer, integer, integer, integer, integer);

create or replace function public.crear_rack(
  p_warehouse_code  text,
  p_code            text,
  p_grid_x          integer,
  p_grid_y          integer,
  p_grid_ancho      integer,
  p_grid_alto       integer,
  p_niveles         integer default 3,
  p_slots_por_nivel integer default 7
)
returns public.racks
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_wh   public.warehouses;
  v_rack public.racks;
begin
  perform public.fn_exigir_rol('SUPERVISOR', 'JEFE');

  -- El código se exige con formato RACK-NN porque de ahí sale el número que
  -- va en el código de cada posición (A-07-01). Sin formato fijo, los códigos
  -- de posición dejarían de ser predecibles.
  if p_code !~ '^RACK-[0-9]{2}$' then
    raise exception 'El código del rack debe tener el formato RACK-NN (por ejemplo RACK-09). Recibido: %.', p_code;
  end if;

  select * into v_wh from public.warehouses where code = p_warehouse_code;
  if v_wh.id is null then
    raise exception 'No existe el almacén %.', p_warehouse_code;
  end if;

  -- El trigger trg_racks_geometria valida acá que quepa y que no pise a otro.
  insert into public.racks (warehouse_id, code, grid_x, grid_y, grid_ancho, grid_alto, niveles)
  values (v_wh.id, p_code, p_grid_x, p_grid_y, p_grid_ancho, p_grid_alto, greatest(least(p_niveles, 8), 1))
  returning * into v_rack;

  -- Un rack sin posiciones es un mueble que no puede guardar nada: se crean
  -- junto con él, repartidas entre sus niveles y con la capacidad que su
  -- geometría permite.
  perform public.fn_configurar_posiciones(v_rack.id, p_niveles, p_slots_por_nivel);

  select * into v_rack from public.racks where id = v_rack.id;
  return v_rack;
end;
$fn$;

grant execute on function public.crear_rack(text, text, integer, integer, integer, integer, integer, integer) to authenticated;


-- =============================================================================
--  BLOQUE G — PONER AL DÍA LA CAPACIDAD DE TODO LO QUE YA EXISTÍA
-- =============================================================================
do $bloque$
declare
  r record;
begin
  for r in select id from public.racks loop
    perform public.fn_recalcular_capacidades(r.id);
  end loop;
end;
$bloque$;


-- =============================================================================
--  VERIFICACIÓN
-- =============================================================================
select
  w.code                                   as almacen,
  w.grid_ancho || ' x ' || w.grid_alto     as plano,
  r.code                                   as rack,
  r.grid_ancho || ' x ' || r.grid_alto     as medidas,
  r.niveles,
  count(p.id)                              as posiciones,
  sum(p.capacity_units)                    as capacidad_cajas
from public.warehouses w
join public.racks      r on r.warehouse_id = w.id
left join public.positions p on p.rack_id = r.id
group by w.code, w.grid_ancho, w.grid_alto, r.code, r.grid_ancho, r.grid_alto, r.niveles
order by w.code, r.code;
-- Esperado: capacidad_cajas ya no es un múltiplo de 200/150, sino un número
-- que cambia con las medidas del rack y sube en los racks de nivel 1.


-- =============================================================================
--  MIGRACIÓN 12 — LA ENTRADA VIVE EN UNA PARED
--
--  La entrada del almacén era un punto fijo que nadie podía mover: la
--  migración 09 la escribió en (20, 28) para los tres almacenes y ahí se quedó.
--  Peor: (20, 28) en un plano de 40 x 30 no está ni sobre la pared — está una
--  celda adentro, flotando en medio del pasillo perimetral. Una puerta que no
--  toca ninguna pared no es una puerta.
--
--  Dos cosas, entonces:
--    1. La entrada se puede mover, pero SOLO sobre el perímetro. La regla se
--       aplica acá y no en el editor, igual que la geometría de los racks.
--    2. La orientación NO se guarda. Que la entrada esté "vertical" es una
--       consecuencia de estar en la pared izquierda o derecha, no un dato
--       aparte que se pueda desincronizar — mismo criterio que el giro de un
--       rack, que es su ancho y su largo intercambiados y no una columna
--       "orientación".
--
--  Requiere 01-11. Idempotente.
-- =============================================================================


-- =============================================================================
--  BLOQUE A — PEGAR UN PUNTO A LA PARED MÁS CERCANA
-- =============================================================================
-- Se usa en los dos lados: al mover la entrada a mano y al redimensionar el
-- almacén (si el plano crece, la pared se aleja y la puerta se quedaría
-- flotando adentro). Devuelve [x, y] ya recortado al plano.
create or replace function public.fn_pegar_a_pared(
  p_x     integer,
  p_y     integer,
  p_ancho integer,
  p_alto  integer
)
returns integer[]
language sql
immutable
as $fn$
  with punto as (
    select least(greatest(p_x, 0), p_ancho - 1) as x,
           least(greatest(p_y, 0), p_alto  - 1) as y
  ),
  distancias as (
    select x, y,
           x                as izquierda,
           p_ancho - 1 - x  as derecha,
           y                as arriba,
           p_alto  - 1 - y  as abajo
      from punto
  )
  select case
           when izquierda <= least(derecha, arriba, abajo) then array[0, y]
           when derecha   <= least(arriba, abajo)          then array[p_ancho - 1, y]
           when arriba    <= abajo                         then array[x, 0]
           else                                                 array[x, p_alto - 1]
         end
    from distancias;
$fn$;

comment on function public.fn_pegar_a_pared is
  'Lleva un punto a la pared más cercana del plano. La entrada del almacén siempre pasa por acá: una puerta en medio del piso no existe.';

create or replace function public.fn_celda_tapada(
  p_warehouse_id uuid,
  p_x            integer,
  p_y            integer
)
returns boolean
language sql
stable
set search_path = public
as $fn$
  select exists (
    select 1 from public.racks
     where warehouse_id = p_warehouse_id
       and p_x >= grid_x and p_x < grid_x + grid_ancho
       and p_y >= grid_y and p_y < grid_y + grid_alto
  );
$fn$;

-- Pegar a la pared no alcanza: esa pared puede tener un rack apoyado encima.
-- Cuando la puerta se reacomoda sola (al redimensionar el almacén, o en el
-- backfill de acá abajo) no hay ningún gesto del usuario que rechazar, así que
-- se busca la celda libre más cercana del perímetro en vez de fallar.
create or replace function public.fn_puerta_libre(
  p_warehouse_id uuid,
  p_x            integer,
  p_y            integer,
  p_ancho        integer,
  p_alto         integer
)
returns integer[]
language plpgsql
stable
set search_path = public
as $fn$
declare
  v_punto integer[];
  v_libre record;
begin
  v_punto := public.fn_pegar_a_pared(p_x, p_y, p_ancho, p_alto);

  if not public.fn_celda_tapada(p_warehouse_id, v_punto[1], v_punto[2]) then
    return v_punto;
  end if;

  select c.x, c.y into v_libre
    from (
      select g.n as x, 0 as y            from generate_series(0, p_ancho - 1) g(n)
      union all
      select g.n,      p_alto - 1        from generate_series(0, p_ancho - 1) g(n)
      union all
      select 0,        g.n               from generate_series(1, p_alto - 2)  g(n)
      union all
      select p_ancho - 1, g.n            from generate_series(1, p_alto - 2)  g(n)
    ) c
   where not public.fn_celda_tapada(p_warehouse_id, c.x, c.y)
   order by (c.x - p_x) * (c.x - p_x) + (c.y - p_y) * (c.y - p_y)
   limit 1;

  -- Perímetro entero tapado (un almacén así no se puede operar de todos modos):
  -- se devuelve el borde natural y que lo resuelva quien mueva los racks.
  if v_libre.x is null then
    return v_punto;
  end if;

  return array[v_libre.x, v_libre.y];
end;
$fn$;


-- =============================================================================
--  BLOQUE B — LAS ENTRADAS QUE YA ESTABAN, A LA PARED
-- =============================================================================
-- El CHECK del perímetro no se puede agregar antes de esto: las tres entradas
-- que escribió la migración 09 lo violarían y la migración abortaría.
alter table public.warehouses drop constraint if exists ck_warehouses_grilla;

update public.warehouses w
   set entrada_x = p.punto[1],
       entrada_y = p.punto[2]
  from (select id, public.fn_puerta_libre(id, entrada_x, entrada_y, grid_ancho, grid_alto) as punto
          from public.warehouses) p
 where p.id = w.id;

alter table public.warehouses
  add constraint ck_warehouses_grilla check (
    grid_ancho between 10 and 80
    and grid_alto between 10 and 80
    and entrada_x >= 0 and entrada_x < grid_ancho
    and entrada_y >= 0 and entrada_y < grid_alto
    -- Sobre el perímetro: al menos una coordenada tocando un borde.
    and (entrada_x = 0 or entrada_x = grid_ancho - 1
      or entrada_y = 0 or entrada_y = grid_alto - 1)
  );


-- =============================================================================
--  BLOQUE C — MOVER LA ENTRADA
-- =============================================================================
create or replace function public.mover_entrada_almacen(
  p_warehouse_code text,
  p_x              integer,
  p_y              integer
)
returns public.warehouses
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_wh     public.warehouses;
  v_punto  integer[];
  v_tapada text;
begin
  perform public.fn_exigir_rol('SUPERVISOR', 'JEFE');

  select * into v_wh from public.warehouses where code = p_warehouse_code;
  if v_wh.id is null then
    raise exception 'No existe el almacén %.', p_warehouse_code;
  end if;

  -- No se exige que el punto llegue exacto: se lleva a la pared más cercana.
  -- Así el editor puede soltar la puerta "cerca" del borde y la base decide.
  v_punto := public.fn_pegar_a_pared(p_x, p_y, v_wh.grid_ancho, v_wh.grid_alto);

  select code into v_tapada
    from public.racks
   where warehouse_id = v_wh.id
     and v_punto[1] >= grid_x and v_punto[1] < grid_x + grid_ancho
     and v_punto[2] >= grid_y and v_punto[2] < grid_y + grid_alto
   limit 1;

  if v_tapada is not null then
    raise exception 'Ahí no se puede: el rack % está contra esa pared y taparía la puerta.', v_tapada;
  end if;

  update public.warehouses
     set entrada_x  = v_punto[1],
         entrada_y  = v_punto[2],
         updated_at = now()
   where id = v_wh.id
  returning * into v_wh;

  return v_wh;
end;
$fn$;

grant execute on function public.mover_entrada_almacen(text, integer, integer) to authenticated;


-- =============================================================================
--  BLOQUE D — REDIMENSIONAR TAMBIÉN REACOMODA LA PUERTA
-- =============================================================================
-- La versión de la migración 11 recortaba la entrada con least(). Eso alcanza
-- cuando el plano se achica, pero si CRECE la pared se aleja y la puerta queda
-- flotando en medio del piso. Ahora se vuelve a pegar a la pared más cercana.
create or replace function public.redimensionar_almacen(
  p_warehouse_code text,
  p_grid_ancho     integer,
  p_grid_alto      integer
)
returns public.warehouses
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_wh     public.warehouses;
  v_afuera text;
  v_punto  integer[];
begin
  perform public.fn_exigir_rol('SUPERVISOR', 'JEFE');

  if p_grid_ancho not between 10 and 80 or p_grid_alto not between 10 and 80 then
    raise exception 'El almacén debe medir entre 10 y 80 m por lado. Se pidió % x %.',
      p_grid_ancho, p_grid_alto;
  end if;

  select * into v_wh from public.warehouses where code = p_warehouse_code;
  if v_wh.id is null then
    raise exception 'No existe el almacén %.', p_warehouse_code;
  end if;

  -- Achicar el plano por debajo de un rack existente lo dejaría "fuera del
  -- almacén". Mover racks solo para que quepan sería decidir por el usuario
  -- dónde va su mercadería: se rechaza y se dice cuáles estorban.
  select string_agg(code, ', ' order by code) into v_afuera
    from public.racks
   where warehouse_id = v_wh.id
     and (grid_x + grid_ancho > p_grid_ancho or grid_y + grid_alto > p_grid_alto);

  if v_afuera is not null then
    raise exception 'No se puede achicar % a % x % m: % quedaría(n) fuera del plano. Muévelos primero.',
      v_wh.code, p_grid_ancho, p_grid_alto, v_afuera;
  end if;

  -- La entrada sí se reacomoda sola: es un punto de referencia del plano, no
  -- mercadería de nadie.
  v_punto := public.fn_puerta_libre(v_wh.id, v_wh.entrada_x, v_wh.entrada_y, p_grid_ancho, p_grid_alto);

  update public.warehouses
     set grid_ancho = p_grid_ancho,
         grid_alto  = p_grid_alto,
         entrada_x  = v_punto[1],
         entrada_y  = v_punto[2],
         updated_at = now()
   where id = v_wh.id
  returning * into v_wh;

  return v_wh;
end;
$fn$;


-- =============================================================================
--  BLOQUE E — UN RACK TAMPOCO PUEDE TAPAR LA PUERTA
-- =============================================================================
-- mover_entrada_almacen ya impide llevar la puerta encima de un rack. Pero la
-- misma superposición se puede armar desde el otro lado: arrastrando el rack
-- sobre la puerta. Es la misma regla dicha desde el otro extremo, y va donde
-- ya viven las demás reglas de geometría — el trigger de la migración 09.
--
-- No es cosmético: A* arranca en la celda de la entrada, y si está bloqueada
-- calcularRutaAEstrella devuelve null y la UI dice "el rack quedó encerrado",
-- que es un diagnóstico falso. El problema no era el rack de destino.
create or replace function public.fn_validar_geometria_rack()
returns trigger
language plpgsql
as $fn$
declare
  v_alm       public.warehouses;
  v_conflicto text;
begin
  select * into v_alm from public.warehouses where id = new.warehouse_id;

  if new.grid_x + new.grid_ancho > v_alm.grid_ancho
     or new.grid_y + new.grid_alto > v_alm.grid_alto then
    raise exception 'El rack % no cabe: se sale del plano del almacén (% x % celdas).',
      new.code, v_alm.grid_ancho, v_alm.grid_alto
      using errcode = 'check_violation';
  end if;

  -- Dos rectángulos se pisan solo si se solapan en LOS DOS ejes a la vez.
  select code into v_conflicto
    from public.racks
   where warehouse_id = new.warehouse_id
     and id <> new.id
     and new.grid_x < grid_x + grid_ancho
     and grid_x     < new.grid_x + new.grid_ancho
     and new.grid_y < grid_y + grid_alto
     and grid_y     < new.grid_y + new.grid_alto
   limit 1;

  if v_conflicto is not null then
    raise exception 'El rack % se superpone con el rack %. Muévelo a un espacio libre.',
      new.code, v_conflicto
      using errcode = 'check_violation';
  end if;

  if v_alm.entrada_x >= new.grid_x and v_alm.entrada_x < new.grid_x + new.grid_ancho
     and v_alm.entrada_y >= new.grid_y and v_alm.entrada_y < new.grid_y + new.grid_alto then
    raise exception 'El rack % taparía la entrada del almacén (celda %, %). Deja la puerta despejada.',
      new.code, v_alm.entrada_x, v_alm.entrada_y
      using errcode = 'check_violation';
  end if;

  return new;
end;
$fn$;


-- =============================================================================
--  VERIFICACIÓN
-- =============================================================================
select
  code                                     as almacen,
  grid_ancho || ' x ' || grid_alto         as plano,
  entrada_x || ',' || entrada_y            as entrada,
  case
    when entrada_x = 0                then 'pared izquierda (vertical)'
    when entrada_x = grid_ancho - 1   then 'pared derecha (vertical)'
    when entrada_y = 0                then 'pared superior (horizontal)'
    when entrada_y = grid_alto - 1    then 'pared inferior (horizontal)'
  end                                      as pared
from public.warehouses
order by code;
-- Esperado: ninguna fila con pared NULL — todas las entradas tocan un borde.


-- =============================================================================
-- =============================================================================
--  MIGRACIÓN 13 — CREAR Y ELIMINAR ALMACENES
--
--  Los tres almacenes venían del seed y no había forma de agregar un cuarto ni
--  de borrar uno creado por error. Eliminar sigue el criterio de eliminar_rack:
--  se borra el que está vacío, nunca el que ya guardó mercadería.
-- =============================================================================
-- =============================================================================

-- =============================================================================
--  BLOQUE A — EL DEFAULT DE LA ENTRADA VIOLABA SU PROPIO CHECK
-- =============================================================================
-- La migración 09 puso entrada (20, 28) por default sobre un plano de 40 x 30.
-- La 12 agregó el CHECK que exige que la entrada toque una pared: con alto 30
-- la pared de abajo es y = 29, así que 28 queda una celda adentro. Nadie lo
-- notó porque hasta ahora ningún INSERT creaba almacenes — el primero habría
-- reventado contra ck_warehouses_grilla sin explicar por qué.
alter table public.warehouses
  alter column entrada_y set default 29;


-- =============================================================================
--  BLOQUE A.2 — TEXTO CON LÍMITE
-- =============================================================================
-- name y address eran text sin tope. Un maxlength en el formulario no es una
-- garantía — se salta con las herramientas del navegador o llamando a la RPC
-- directo — y un nombre de mil caracteres rompe el <select> de almacenes y
-- todas las tablas que lo muestran. El tope va donde sí manda.
-- Los límites son los mismos que declara el formulario (index.html).
alter table public.warehouses drop constraint if exists ck_warehouses_texto;
alter table public.warehouses
  add constraint ck_warehouses_texto check (
    length(code) <= 12
    and length(btrim(name)) between 1 and 40
    and (address is null or length(btrim(address)) <= 120)
  );


-- =============================================================================
--  BLOQUE B — CREAR UN ALMACÉN
-- =============================================================================
create or replace function public.crear_almacen(
  p_code       text,
  p_name       text,
  p_grid_ancho integer default 40,
  p_grid_alto  integer default 30,
  p_address    text    default null
)
returns public.warehouses
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_code text;
  v_wh   public.warehouses;
begin
  perform public.fn_exigir_rol('SUPERVISOR', 'JEFE');

  v_code := upper(trim(p_code));

  -- Mismo formato que el CHECK de la tabla, validado acá para poder decir qué
  -- se espera en vez de devolver una violación de constraint en crudo.
  if v_code !~ '^[A-Z0-9]{2,10}(-[A-Z0-9]{1,10})*$' then
    raise exception 'El código % no sirve: usa letras y números en mayúscula, separados por guiones (por ejemplo ALM-D o BOD-02).', v_code;
  end if;

  if coalesce(trim(p_name), '') = '' then
    raise exception 'El almacén necesita un nombre.';
  end if;

  -- Se revisan acá además del CHECK para poder decir cuál campo se pasó y de
  -- cuánto; el constraint solo diría "ck_warehouses_texto".
  if length(v_code) > 12 then
    raise exception 'El código no puede pasar de 12 caracteres (tiene %).', length(v_code);
  end if;

  if length(trim(p_name)) > 40 then
    raise exception 'El nombre no puede pasar de 40 caracteres (tiene %).', length(trim(p_name));
  end if;

  if length(coalesce(trim(p_address), '')) > 120 then
    raise exception 'La dirección no puede pasar de 120 caracteres (tiene %).', length(trim(p_address));
  end if;

  if p_grid_ancho not between 10 and 80 or p_grid_alto not between 10 and 80 then
    raise exception 'El almacén debe medir entre 10 y 80 m por lado. Se pidió % x %.',
      p_grid_ancho, p_grid_alto;
  end if;

  if exists (select 1 from public.warehouses where code = v_code) then
    raise exception 'Ya existe un almacén con el código %.', v_code;
  end if;

  -- El último carácter del código encabeza los códigos de posición de sus
  -- racks (ALM-D -> D-07-01, ALM-04 -> 4-07-01; ver crear_rack). Dos almacenes
  -- que terminen igual generarían posiciones que se leen idénticas en el mapa
  -- aunque estén en edificios distintos. Puede ser letra o dígito: lo que
  -- importa es que no se repita (positions.code lo admite desde la 14).
  if exists (select 1 from public.warehouses where right(code, 1) = right(v_code, 1)) then
    raise exception 'El código % termina en "%", igual que un almacén que ya existe. De ese carácter salen los códigos de posición, así que debe ser único.',
      v_code, right(v_code, 1);
  end if;

  -- Puerta al centro de la pared de abajo: es la única pared que con seguridad
  -- está libre, porque el almacén nace sin un solo rack.
  insert into public.warehouses (code, name, address, grid_ancho, grid_alto, entrada_x, entrada_y)
  values (v_code, trim(p_name), nullif(trim(p_address), ''),
          p_grid_ancho, p_grid_alto, p_grid_ancho / 2, p_grid_alto - 1)
  returning * into v_wh;

  return v_wh;
end;
$fn$;

grant execute on function public.crear_almacen(text, text, integer, integer, text) to authenticated;

comment on function public.crear_almacen is
  'Da de alta un almacén vacío con la puerta al centro de la pared inferior. Exige que el último carácter del código sea único: de ahí salen los códigos de posición.';


-- =============================================================================
--  BLOQUE C — ELIMINAR UN ALMACÉN (solo si está realmente vacío)
-- =============================================================================
-- Las tablas que apuntan a warehouses están en on delete restrict menos
-- warehouse_nodes, que va en cascade (el grafo de ruteo se regenera solo). Un
-- DELETE a secas fallaría con un error de FK que no dice cuál estorba; acá se
-- revisa una por una y se nombra el problema.
create or replace function public.eliminar_almacen(p_warehouse_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_wh        public.warehouses;
  v_racks     text;
  v_articulos integer;
  v_historial integer;
begin
  perform public.fn_exigir_rol('SUPERVISOR', 'JEFE');

  select * into v_wh from public.warehouses where code = p_warehouse_code;
  if v_wh.id is null then
    raise exception 'No existe el almacén %.', p_warehouse_code;
  end if;

  select string_agg(code, ', ' order by code) into v_racks
    from public.racks where warehouse_id = v_wh.id;

  if v_racks is not null then
    raise exception 'No se puede eliminar %: todavía tiene racks (%). Bórralos primero desde el editor de plano.',
      v_wh.name, v_racks;
  end if;

  select count(*) into v_articulos
    from public.inventory where warehouse_id = v_wh.id;

  if v_articulos > 0 then
    raise exception 'No se puede eliminar %: hay % artículo(s) registrados en él. Muévelos a otro almacén primero.',
      v_wh.name, v_articulos;
  end if;

  -- Sin racks ni inventario todavía puede quedar historial: órdenes, asientos
  -- del kardex o conteos de un stock que ya se dio de baja. Borrar el almacén
  -- dejaría esos registros apuntando a la nada.
  select
    (select count(*) from public.inventory_orders  where warehouse_id = v_wh.id)
  + (select count(*) from public.stock_ledger      where warehouse_id = v_wh.id)
  + (select count(*) from public.inventory_counts  where warehouse_id = v_wh.id)
  into v_historial;

  if v_historial > 0 then
    raise exception 'No se puede eliminar %: tiene % registro(s) de historial (órdenes, kardex o conteos). Borrarlo dejaría el kardex sin rastro de dónde ocurrieron.',
      v_wh.name, v_historial;
  end if;

  delete from public.warehouses where id = v_wh.id;

  return jsonb_build_object(
    'estado',  'ELIMINADO',
    'mensaje', v_wh.name || ' eliminado.'
  );
end;
$fn$;

grant execute on function public.eliminar_almacen(text) to authenticated;

comment on function public.eliminar_almacen is
  'Borra un almacén solo si está vacío: sin racks, sin inventario y sin historial. Nombra qué estorba en vez de devolver una violación de FK.';


-- =============================================================================
--  BLOQUE D — RLS: FALTABA LA POLÍTICA DE DELETE
-- =============================================================================
-- Las funciones de arriba son security definer y no la necesitan, pero sin
-- política de delete la tabla queda con una regla implícita "nadie borra
-- nunca", que contradice lo que el sistema ahora sí permite.
drop policy if exists p_warehouses_delete on public.warehouses;
create policy p_warehouses_delete on public.warehouses
  for delete to authenticated using ((select public.fn_es_al_menos_supervisor()));


-- =============================================================================
--  VERIFICACIÓN
-- =============================================================================
select
  code                             as almacen,
  name                             as nombre,
  grid_ancho || ' x ' || grid_alto as plano,
  entrada_x || ',' || entrada_y    as entrada,
  (select count(*) from public.racks r where r.warehouse_id = w.id) as racks
from public.warehouses w
order by code;


-- =============================================================================
-- =============================================================================
--  MIGRACIÓN 14 — EL PREFIJO DE UNA POSICIÓN TAMBIÉN PUEDE SER UN DÍGITO
--
--  El prefijo del código de posición es el último carácter del código del
--  almacén. warehouses.code siempre admitió dígitos, positions.code exigía
--  letra: crear un rack en 'ALM-04' reventaba. Se relaja positions.
-- =============================================================================
-- =============================================================================

-- =============================================================================
--  BLOQUE A — positions.code ACEPTA UN PREFIJO ALFANUMÉRICO
-- =============================================================================
alter table public.positions drop constraint if exists positions_code_check;
alter table public.positions
  add constraint positions_code_check check (code ~ '^[A-Z0-9]-[0-9]{2}-[0-9]{2}$');

comment on column public.positions.code is
  'Dirección física: <PREFIJO DEL ALMACÉN>-<RACK 2 dígitos>-<SLOT 2 dígitos>, por ejemplo A-03-02 o 4-01-07. El prefijo es el último carácter del código del almacén y crear_almacen lo exige único.';


-- =============================================================================
--  VERIFICACIÓN
-- =============================================================================
-- Cada almacén con su prefijo y cuántas posiciones cuelgan de él. Ninguna fila
-- debe salir con prefijo repetido: ahí es donde dos almacenes distintos
-- generarían códigos de posición que se leen idénticos.
select
  w.code                                   as almacen,
  right(w.code, 1)                         as prefijo,
  count(distinct r.id)                     as racks,
  count(p.id)                              as posiciones
from public.warehouses w
left join public.racks r     on r.warehouse_id = w.id
left join public.positions p on p.rack_id      = r.id
group by w.code
order by w.code;


-- =============================================================================
-- =============================================================================
--  MIGRACIÓN 15 — CAJAS REALES, INFANTIL EN DOS NIVELES Y MÍNIMO DE 3 POR RACK
--
--  Las cajas eran números a ojo; ahora son las medidas comerciales. El
--  calzado infantil pasa de un nivel a dos, y como un rack de 2 niveles se
--  quedaría sin sitio para adulto, el mínimo por rack sube a 3.
-- =============================================================================
-- =============================================================================

-- =============================================================================
--  BLOQUE A — DÓNDE VIVE EL LÍMITE DE LO INFANTIL
-- =============================================================================
-- El número aparece en el cálculo de capacidad y en la validación de ubicación.
-- Escrito dos veces, tarde o temprano una se queda vieja y el sistema calcula
-- la capacidad con una regla y valida con otra.
create or replace function public.fn_niveles_infantiles()
returns integer
language sql
immutable
as $fn$ select 2 $fn$;

comment on function public.fn_niveles_infantiles is
  'Hasta qué nivel llega el calzado infantil. Del siguiente en adelante es de adulto, y la exclusión vale en los dos sentidos: adulto no baja, infantil no sube. De acá sale también el mínimo de niveles de un rack (este número + 1).';


-- =============================================================================
--  BLOQUE B — LAS CAJAS, CON MEDIDAS COMERCIALES
-- =============================================================================
-- Adulto usa la caja de HOMBRE (35 x 25 x 13) y no la de mujer (33 x 19 x 11)
-- a propósito: es la mayor de las dos, y la capacidad se calcula al configurar
-- el rack, cuando todavía no se sabe qué par va a entrar ahí. Con la caja
-- grande como referencia, lo que el sistema promete siempre cabe; con la chica
-- prometería huecos que dejan de existir en cuanto llega un 44 de hombre.
create or replace function public.fn_cajas_en_slot(
  p_frente_m numeric,
  p_fondo_m  numeric,
  p_nivel    integer
)
returns integer
language sql
immutable
set search_path = public
as $fn$
  select greatest(0, floor(
           floor(p_frente_m / c.largo)
         * floor(p_fondo_m  / c.ancho)
         * floor(0.45       / c.alto)   -- 45 cm de luz entre estantes
         * 0.85                          -- holgura de maniobra y cajas mal puestas
         )::integer)
    from (select
            case when p_nivel <= public.fn_niveles_infantiles() then 0.22 else 0.35 end as largo,
            case when p_nivel <= public.fn_niveles_infantiles() then 0.15 else 0.25 end as ancho,
            case when p_nivel <= public.fn_niveles_infantiles() then 0.09 else 0.13 end as alto
         ) c;
$fn$;

comment on function public.fn_cajas_en_slot is
  'Cajas que entran en un casillero de p_frente_m x p_fondo_m según su nivel. Infantil 22x15x9 cm en los niveles bajos; adulto 35x25x13 (caja de hombre, la mayor) del resto.';


-- =============================================================================
--  BLOQUE C — INFANTIL ABAJO, ADULTO ARRIBA (AHORA CON DOS NIVELES ABAJO)
-- =============================================================================
-- La exclusión sigue valiendo en los dos sentidos. Que el adulto no pueda bajar
-- es lo que garantiza que el infantil tenga dónde ir: si pudiera ocupar
-- cualquier nivel, la línea infantil se quedaría sin sitio el día que el
-- almacén se llene, que es justo el día en que importa.
create or replace function public.fn_validar_publico_por_nivel()
returns trigger
language plpgsql
set search_path = public
as $fn$
declare
  v_audience text;
  v_level    smallint;
  v_tope     integer := public.fn_niveles_infantiles();
begin
  -- Liberar un espacio no reubica nada: no hay nada que validar.
  if new.status = 'LIBERADA' then
    return new;
  end if;

  select p.audience into v_audience
    from public.inventory_items it
    join public.products        p  on p.id = it.product_id
   where it.id = new.item_id;

  select level into v_level from public.positions where id = new.position_id;

  if v_level is null then
    raise exception 'La posición % no tiene nivel definido.', new.position_id;
  end if;

  if v_audience = 'NINO' and v_level > v_tope then
    raise exception
      'Calzado infantil solo puede ubicarse hasta el nivel % (los de abajo). La posición elegida está en el nivel %.',
      v_tope, v_level
      using errcode = 'check_violation';
  end if;

  if v_audience = 'ADULTO' and v_level <= v_tope then
    raise exception
      'Calzado de adulto no puede ubicarse en el nivel %: los niveles 1 a % están reservados para calzado infantil.',
      v_level, v_tope
      using errcode = 'check_violation';
  end if;

  -- UNISEX: sin restricción de nivel.
  return new;
end;
$fn$;

comment on trigger trg_assign_publico_nivel on public.position_assignments is
  'Regla del jefe de almacén: infantil en los niveles bajos, adulto por encima. El corte lo decide fn_niveles_infantiles(). Se aplica en la base, no confía en que la UI la respete.';


-- =============================================================================
--  BLOQUE D — EL NIVEL TIENE TECHO
-- =============================================================================
-- 8 niveles de 45 cm son 3,6 m de estantería, lo que se alcanza con escalera de
-- almacén. El tope ya existía en racks.niveles y en fn_configurar_posiciones,
-- pero no en positions.level, que es la columna donde de verdad se escribe.
alter table public.positions drop constraint if exists ck_positions_level;
alter table public.positions
  add constraint ck_positions_level check (level is null or level between 1 and 8);

comment on column public.positions.level is
  'Altura dentro del rack, de 1 (piso) a 8. El mismo tope que racks.niveles: son el mismo número visto desde la posición y desde el mueble.';


-- =============================================================================
--  BLOQUE E — UN RACK NO PUEDE TENER MENOS DE TRES NIVELES
-- =============================================================================
-- Con infantil ocupando dos niveles, un rack de dos no deja ni un estante para
-- adulto: sería un mueble donde la mayor parte del catálogo no puede entrar. El
-- mínimo sale de la propia regla (niveles infantiles + 1), no de un número
-- suelto, para que mover el corte de lo infantil arrastre el mínimo con él.
create or replace function public.fn_configurar_posiciones(
  p_rack_id         uuid,
  p_niveles         integer,
  p_slots_por_nivel integer
)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_rack   public.racks;
  v_letra  text;
  v_num    text;
  v_pos    record;
  v_nivel  integer;
  v_faltan integer;
  v_idx    integer;
  v_donde  text;
  v_min    integer := public.fn_niveles_infantiles() + 1;
begin
  if p_niveles not between v_min and 8 then
    raise exception 'Un rack tiene entre % y 8 niveles: los % de abajo son para calzado infantil y hace falta al menos uno encima para el de adulto. Se pidieron %.',
      v_min, public.fn_niveles_infantiles(), p_niveles;
  end if;
  if p_slots_por_nivel not between 1 and 40 then
    raise exception 'Las posiciones por nivel deben estar entre 1 y 40. Se pidieron %.', p_slots_por_nivel;
  end if;
  if p_niveles * p_slots_por_nivel > 99 then
    raise exception '% niveles x % posiciones son % casilleros y el código de posición solo admite 99. Divídelo en dos racks.',
      p_niveles, p_slots_por_nivel, p_niveles * p_slots_por_nivel;
  end if;

  select * into v_rack from public.racks where id = p_rack_id;
  if v_rack.id is null then
    raise exception 'El rack no existe.';
  end if;

  -- El código de almacén se trae junto a la letra para que los errores puedan
  -- decir de qué RACK-07 hablan: el código de rack se repite entre almacenes.
  select right(w.code, 1), w.code || ' · ' || v_rack.code
    into v_letra, v_donde
    from public.warehouses w where w.id = v_rack.warehouse_id;
  v_num := right(v_rack.code, 2);

  -- Niveles que se van: solo si están vacíos de presente y de pasado.
  for v_pos in
    select p.id, p.code from public.positions p
     where p.rack_id = p_rack_id and p.level > p_niveles
  loop
    if exists (select 1 from public.position_assignments where position_id = v_pos.id)
       or exists (select 1 from public.inventory_movements where position_id = v_pos.id)
       or exists (select 1 from public.stock_ledger      where position_id = v_pos.id)
    then
      raise exception 'No se puede bajar % a % niveles: la posición % tiene historial de movimientos.',
        v_donde, p_niveles, v_pos.code;
    end if;
    delete from public.positions where id = v_pos.id;
  end loop;

  -- Niveles que faltan o están incompletos.
  for v_nivel in 1..p_niveles loop
    select p_slots_por_nivel - count(*) into v_faltan
      from public.positions where rack_id = p_rack_id and level = v_nivel;

    while v_faltan > 0 loop
      -- Primer índice libre del rack: así los códigos ya emitidos no se tocan.
      select min(g.n) into v_idx
        from generate_series(1, 99) as g(n)
       where not exists (
         select 1 from public.positions
          where rack_id = p_rack_id
            and code = v_letra || '-' || v_num || '-' || lpad(g.n::text, 2, '0')
       );

      if v_idx is null then
        raise exception 'El rack % ya usó los 99 códigos de posición disponibles.', v_donde;
      end if;

      insert into public.positions (rack_id, code, capacity_units, level, slot)
      values (p_rack_id,
              v_letra || '-' || v_num || '-' || lpad(v_idx::text, 2, '0'),
              0, v_nivel,
              p_slots_por_nivel - v_faltan + 1);

      v_faltan := v_faltan - 1;
    end loop;
  end loop;

  update public.racks set niveles = p_niveles, updated_at = now() where id = p_rack_id;
  perform public.fn_recalcular_capacidades(p_rack_id);
end;
$fn$;


-- =============================================================================
--  BLOQUE F — AMPLIAR LOS RACKS QUE SE QUEDARON CORTOS
-- =============================================================================
-- Sube a 3 niveles los que tienen menos, conservando su cantidad de casilleros
-- por nivel. No renumera nada: fn_configurar_posiciones solo agrega los códigos
-- que faltan, y los que ya están emitidos aparecen en el kardex.
--
-- Sin `exception when others` a propósito. Un intento anterior lo tenía, y lo
-- único que consiguió fue que el fallo de los 15 racks pasara desapercibido
-- hasta que el ALTER de abajo se estrelló sin decir contra qué. Si acá algo
-- falla, tiene que salir a la cara y detener la migración.
do $bloque$
declare
  r     record;
  v_min integer := public.fn_niveles_infantiles() + 1;
begin
  -- La lista se arma completa antes de tocar nada: fn_configurar_posiciones
  -- escribe en racks, y recorrer con un cursor la misma tabla que se está
  -- modificando es pedir problemas.
  for r in
    select id, code, slots from (
      select rk.id,
             w.code || ' · ' || rk.code as code,
             -- El nivel más poblado manda: si quedaron desparejos, ampliar al
             -- mayor completa los huecos en vez de dejarlos a medias.
             -- El ::integer no es decorativo: count(*) devuelve bigint y
             -- fn_configurar_posiciones recibe integer, así que sin el cast no
             -- hay sobrecarga que coincida y la llamada ni siquiera resuelve.
             coalesce(max(p.cuantas), 1)::integer as slots
        from public.racks rk
        join public.warehouses w on w.id = rk.warehouse_id
        left join (
          select rack_id, level, count(*) as cuantas
            from public.positions
           where level is not null
           group by rack_id, level
        ) p on p.rack_id = rk.id
       where rk.niveles < v_min
       group by rk.id, w.code, rk.code
    ) pendientes
  loop
    raise notice 'Ampliando % a % niveles con % casilleros por nivel', r.code, v_min, r.slots;
    perform public.fn_configurar_posiciones(r.id, v_min, r.slots);
  end loop;
end;
$bloque$;

-- Antes de exigir el mínimo, comprobar que no quedó ninguno corto. Sin esto, el
-- ALTER de abajo aborta con "check constraint ck_racks_niveles is violated by
-- some row" — que no dice qué fila, ni de qué almacén, ni por qué. Diez
-- segundos de guarda ahorran una hora de buscar a ciegas.
do $bloque$
declare
  v_cortos text;
begin
  select string_agg(w.code || ' · ' || r.code || ' (' || r.niveles || ')', ', ' order by w.code, r.code)
    into v_cortos
    from public.racks r
    join public.warehouses w on w.id = r.warehouse_id
   where r.niveles < public.fn_niveles_infantiles() + 1;

  if v_cortos is not null then
    raise exception 'Estos racks siguen por debajo de % niveles y el bloque anterior no pudo ampliarlos: %. Revisa el error que dio arriba antes de reintentar.',
      public.fn_niveles_infantiles() + 1, v_cortos;
  end if;
end;
$bloque$;

-- Recién ahora, con todos los racks ampliados, el mínimo se puede exigir: antes
-- el ALTER fallaría contra los racks que tenían 1 o 2 niveles.
alter table public.racks drop constraint if exists ck_racks_niveles;
alter table public.racks
  add constraint ck_racks_niveles check (niveles between 3 and 8);

comment on column public.racks.niveles is
  'Estantes del rack, de 3 a 8. El mínimo no es arbitrario: los dos de abajo son para calzado infantil y hace falta al menos uno encima para el de adulto.';


-- =============================================================================
--  BLOQUE F.2 — crear_rack AVISA ANTES DE INSERTAR
-- =============================================================================
-- La versión de la migración 11 inserta el rack con greatest(least(p_niveles,8),1)
-- y recién después llama a fn_configurar_posiciones. Con el mínimo de 3, pedir
-- un rack de 2 niveles ya no rebota en la función —con su mensaje explicando el
-- porqué— sino en el CHECK de la tabla, que solo dice "violates check constraint
-- ck_racks_niveles". Se valida antes de tocar nada.
create or replace function public.crear_rack(
  p_warehouse_code  text,
  p_code            text,
  p_grid_x          integer,
  p_grid_y          integer,
  p_grid_ancho      integer,
  p_grid_alto       integer,
  p_niveles         integer default 3,
  p_slots_por_nivel integer default 7
)
returns public.racks
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_wh   public.warehouses;
  v_rack public.racks;
  v_min  integer := public.fn_niveles_infantiles() + 1;
begin
  perform public.fn_exigir_rol('SUPERVISOR', 'JEFE');

  -- El código se exige con formato RACK-NN porque de ahí sale el número que va
  -- en el código de cada posición (A-07-01). Sin formato fijo, los códigos de
  -- posición dejarían de ser predecibles.
  if p_code !~ '^RACK-[0-9]{2}$' then
    raise exception 'El código del rack debe tener el formato RACK-NN (por ejemplo RACK-09). Recibido: %.', p_code;
  end if;

  if p_niveles not between v_min and 8 then
    raise exception 'Un rack tiene entre % y 8 niveles: los % de abajo son para calzado infantil y hace falta al menos uno encima para el de adulto. Se pidieron %.',
      v_min, public.fn_niveles_infantiles(), p_niveles;
  end if;

  select * into v_wh from public.warehouses where code = p_warehouse_code;
  if v_wh.id is null then
    raise exception 'No existe el almacén %.', p_warehouse_code;
  end if;

  -- El trigger trg_racks_geometria valida acá que quepa y que no pise a otro.
  insert into public.racks (warehouse_id, code, grid_x, grid_y, grid_ancho, grid_alto, niveles)
  values (v_wh.id, p_code, p_grid_x, p_grid_y, p_grid_ancho, p_grid_alto, p_niveles)
  returning * into v_rack;

  -- Un rack sin posiciones es un mueble que no puede guardar nada: se crean
  -- junto con él, repartidas entre sus niveles y con la capacidad que su
  -- geometría permite.
  perform public.fn_configurar_posiciones(v_rack.id, p_niveles, p_slots_por_nivel);

  select * into v_rack from public.racks where id = v_rack.id;
  return v_rack;
end;
$fn$;

grant execute on function public.crear_rack(text, text, integer, integer, integer, integer, integer, integer) to authenticated;


-- =============================================================================
--  BLOQUE G — RECALCULAR LO YA DECLARADO CON LAS CAJAS NUEVAS
-- =============================================================================
-- fn_recalcular_capacidades (migración 11) reparte el frente entre los
-- casilleros del nivel y nunca declara menos de lo que la posición tiene
-- adentro: declarar 40 donde hay 60 dejaría el rack en sobrecarga permanente.
do $bloque$
declare
  r record;
begin
  for r in select id from public.racks loop
    perform public.fn_recalcular_capacidades(r.id);
  end loop;
end;
$bloque$;


-- =============================================================================
--  VERIFICACIÓN
-- =============================================================================
-- 1. Qué caja asume cada nivel y cuánto rinde.
select
  nivel,
  case when nivel <= public.fn_niveles_infantiles()
       then 'infantil 22x15x9' else 'adulto 35x25x13' end as caja,
  public.fn_cajas_en_slot(2, 2, nivel)                     as cajas_en_un_slot_de_2x2_m
from generate_series(1, 8) as g(nivel)
order by nivel;

-- 2. Ningún rack debe quedar por debajo del mínimo. Si sale alguno, es uno que
--    el bloque F no pudo ampliar (lo dijo con un warning) y hay que dividirlo.
select code, niveles
  from public.racks
 where niveles < public.fn_niveles_infantiles() + 1
 order by code;

-- 3. Mercadería que quedó fuera de sitio. La migración NO la movió a propósito:
--    cambiarla de posición en la base no la mueve del estante. Estas son las
--    cajas que hay que bajar o subir físicamente y reubicar después en el
--    sistema. Sin filas, no hay nada pendiente.
select
  w.code      as almacen,
  r.code      as rack,
  pos.code    as posicion,
  pos.level   as nivel,
  pr.audience as publico,
  it.sku,
  pa.quantity as unidades
from public.position_assignments pa
join public.positions       pos on pos.id = pa.position_id
join public.racks           r   on r.id   = pos.rack_id
join public.warehouses      w   on w.id   = r.warehouse_id
join public.inventory_items it  on it.id  = pa.item_id
join public.products        pr  on pr.id  = it.product_id
where pa.status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
  and (
    (pr.audience = 'NINO'   and pos.level >  public.fn_niveles_infantiles())
 or (pr.audience = 'ADULTO' and pos.level <= public.fn_niveles_infantiles())
  )
order by w.code, r.code, pos.code;


-- =============================================================================
-- =============================================================================
--  MIGRACIÓN 16 — LOS MOVIMIENTOS DICEN DÓNDE OCURRIERON
--
--  position_id existía desde la 01 pero la vista no lo exponía: la pantalla
--  de movimientos decía qué entró, no a qué rack.
-- =============================================================================
-- =============================================================================

-- =============================================================================
--  BLOQUE A — LA VISTA EXPONE LA UBICACIÓN
-- =============================================================================
-- Las columnas nuevas van al final: create or replace view exige que las que ya
-- existen conserven nombre, tipo y orden.
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
  eb.full_name                       as ejecutado_por,
  -- Dónde ocurrió.
  w.code                             as almacen_code,
  w.name                             as almacen,
  rk.code                            as rack,
  pos.code                           as posicion,
  pos.level                          as nivel,
  case
    when pos.id is null              then null
    when m.movement_type = 'ENTRADA' then 'DESTINO'
    when m.movement_type = 'SALIDA'  then 'ORIGEN'
    else                                  'AFECTADA'
  end                                as ubicacion_rol
from public.inventory_movements m
join public.inventory_items it on it.id = m.item_id
join public.products        p  on p.id  = it.product_id
left join public.inventory_movements r on r.reversal_of_id = m.id
left join public.profiles  cb on cb.id = m.created_by
left join public.profiles  ab on ab.id = m.approved_by
left join public.profiles  eb on eb.id = m.executed_by
left join public.positions  pos on pos.id = m.position_id
left join public.racks      rk  on rk.id  = pos.rack_id
left join public.warehouses w   on w.id   = rk.warehouse_id;

-- La vista lee tablas con RLS: sin security_invoker correría con los permisos
-- del dueño y se saltaría las políticas. create or replace view no garantiza
-- conservar la opción, así que se reafirma.
alter view public.v_movimientos_detalle set (security_invoker = on);

comment on view public.v_movimientos_detalle is
  'Movimientos con su artículo, su situación real y dónde ocurrieron. ubicacion_rol dice si la posición es el origen o el destino: la columna position_id significa una cosa u otra según el tipo de movimiento.';


-- =============================================================================
--  VERIFICACIÓN
-- =============================================================================
-- Cuántos movimientos tienen coordenada física y cuántos no. Los AJUSTE sin
-- posición son normales (un ajuste contable no ocurre en ningún estante); una
-- ENTRADA o SALIDA sin posición significa que se ejecutó sin ubicar, que es
-- justo lo que esta columna deja ver.
select
  movement_type,
  coalesce(ubicacion_rol, 'SIN UBICACION') as ubicacion,
  count(*)                                 as movimientos
from public.v_movimientos_detalle
group by movement_type, ubicacion_rol
order by movement_type, ubicacion;


-- =============================================================================
-- =============================================================================
--  MIGRACIÓN 17 — REUBICAR LO QUE QUEDÓ EN EL NIVEL EQUIVOCADO
--
--  La 15 dejó a propósito donde estaba la mercadería que quedó fuera de
--  regla. Esto es la herramienta para saldarla a medida que alguien la
--  mueve de verdad: la lista y un liberar+ubicar atómico.
-- =============================================================================
-- =============================================================================

-- =============================================================================
--  BLOQUE A — QUÉ ESTÁ FUERA DE SITIO
-- =============================================================================
-- Sirve para las dos direcciones: adulto que quedó abajo (el caso de la 15) e
-- infantil que quedó arriba. La columna nivel_sugerido dice adónde tendría que
-- ir, que es lo que la pantalla ofrece con un clic.
create or replace view public.v_reubicaciones_pendientes as
select
  pa.id                       as assignment_id,
  pa.quantity                 as unidades,
  pa.status,
  it.id                       as item_id,
  it.sku,
  pr.name                     as producto,
  it.size_label               as talla,
  pr.audience                 as publico,
  w.code                      as almacen_code,
  w.name                      as almacen,
  r.id                        as rack_id,
  r.code                      as rack,
  pos.id                      as position_id,
  pos.code                    as posicion,
  pos.level                   as nivel,
  case when pr.audience = 'NINO' then 1 else public.fn_niveles_infantiles() + 1 end
                              as nivel_sugerido
from public.position_assignments pa
join public.positions       pos on pos.id = pa.position_id
join public.racks           r   on r.id   = pos.rack_id
join public.warehouses      w   on w.id   = r.warehouse_id
join public.inventory_items it  on it.id  = pa.item_id
join public.products        pr  on pr.id  = it.product_id
where pa.status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
  and (
    (pr.audience = 'NINO'   and pos.level >  public.fn_niveles_infantiles())
 or (pr.audience = 'ADULTO' and pos.level <= public.fn_niveles_infantiles())
  );

alter view public.v_reubicaciones_pendientes set (security_invoker = on);

comment on view public.v_reubicaciones_pendientes is
  'Mercadería ubicada en un nivel que la regla de público ya no admite. Es una lista de trabajo físico pendiente, no un error del sistema: se salda moviendo la caja y confirmando con reubicar_asignacion().';


-- =============================================================================
--  BLOQUE B — MOVER UNA ASIGNACIÓN DE UNA POSICIÓN A OTRA
-- =============================================================================
-- p_position_id opcional: si no viene, se busca el primer hueco válido del
-- MISMO rack. Que sea el mismo mueble no es un detalle — quien sube una caja
-- del estante 2 al 4 la deja donde estaba parado, y proponerle un rack al otro
-- lado del almacén sería inventarle trabajo.
create or replace function public.reubicar_asignacion(
  p_assignment_id uuid,
  p_position_id   uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_asg     public.position_assignments;
  v_origen  public.positions;
  v_destino public.positions;
  v_tope    integer := public.fn_niveles_infantiles();
  v_publico text;
  v_nueva   uuid;
begin
  perform public.fn_exigir_rol('OPERARIO', 'SUPERVISOR', 'JEFE');

  select * into v_asg from public.position_assignments where id = p_assignment_id;
  if v_asg.id is null then
    raise exception 'Esa ubicación ya no existe.';
  end if;
  if v_asg.status = 'LIBERADA' then
    raise exception 'Esa ubicación ya fue liberada: no hay nada que mover.';
  end if;

  select * into v_origen from public.positions where id = v_asg.position_id;

  select pr.audience into v_publico
    from public.inventory_items it
    join public.products pr on pr.id = it.product_id
   where it.id = v_asg.item_id;

  if p_position_id is not null then
    select * into v_destino from public.positions where id = p_position_id;
    if v_destino.id is null then
      raise exception 'La posición de destino no existe.';
    end if;
  else
    -- Primer hueco libre del mismo rack en un nivel que sí admita este público,
    -- y con sitio declarado para las unidades que se mueven.
    select p.* into v_destino
      from public.positions p
     where p.rack_id = v_origen.rack_id
       and p.id <> v_origen.id
       and p.is_active
       and case when v_publico = 'NINO' then p.level <= v_tope
                when v_publico = 'ADULTO' then p.level > v_tope
                else true end
       and p.capacity_units >= v_asg.quantity
                            + coalesce((select sum(a.quantity)
                                          from public.position_assignments a
                                         where a.position_id = p.id
                                           and a.status in ('RESERVADA','OCUPADA','EN_PICKING')), 0)
     order by p.level, p.slot
     limit 1;

    if v_destino.id is null then
      raise exception 'No hay ningún hueco libre en % para % unidades de %. Amplía el rack o libera espacio.',
        (select code from public.racks where id = v_origen.rack_id),
        v_asg.quantity,
        (select sku from public.inventory_items where id = v_asg.item_id);
    end if;
  end if;

  -- Las dos escrituras van juntas: la función es una sola transacción, así que
  -- o la caja termina ubicada en el destino o se queda donde estaba. Nunca en
  -- el limbo.
  update public.position_assignments
     set status = 'LIBERADA', released_at = now(), updated_at = now()
   where id = p_assignment_id;

  -- El trigger trg_assign_publico_nivel valida acá que el nivel de destino
  -- admita este público, y el de capacidad que quepa. Si algo no cuadra, la
  -- excepción revierte también el LIBERADA de arriba.
  insert into public.position_assignments (position_id, item_id, quantity, status, notes)
  values (v_destino.id, v_asg.item_id, v_asg.quantity, v_asg.status,
          'Reubicada desde ' || v_origen.code || ' (nivel ' || v_origen.level || ')')
  returning id into v_nueva;

  return jsonb_build_object(
    'estado',         'REUBICADA',
    'assignment_id',  v_nueva,
    'desde',          v_origen.code,
    'hasta',          v_destino.code,
    'nivel_anterior', v_origen.level,
    'nivel_nuevo',    v_destino.level,
    'mensaje',        'Movida de ' || v_origen.code || ' (nivel ' || v_origen.level ||
                      ') a ' || v_destino.code || ' (nivel ' || v_destino.level || ').'
  );
end;
$fn$;

grant execute on function public.reubicar_asignacion(uuid, uuid) to authenticated;

comment on function public.reubicar_asignacion is
  'Mueve una asignación a otra posición en una sola transacción. Sin destino explícito, busca el primer hueco válido del mismo rack. Se llama DESPUÉS de mover la caja de verdad: registra un movimiento físico, no lo ordena.';


-- =============================================================================
--  VERIFICACIÓN
-- =============================================================================
-- Cuánto queda por reubicar y adónde iría. Si el nivel sugerido no tiene huecos
-- en ese rack, reubicar_asignacion lo dirá al intentarlo.
select
  almacen_code,
  rack,
  publico,
  nivel          as nivel_actual,
  nivel_sugerido,
  count(*)       as asignaciones,
  sum(unidades)  as unidades
from public.v_reubicaciones_pendientes
group by almacen_code, rack, publico, nivel, nivel_sugerido
order by almacen_code, rack;


-- =============================================================================
-- =============================================================================
--  MIGRACIÓN 18 — REUBICAR REPARTIENDO, Y SIN PELEARSE CON EL ÍNDICE ÚNICO
--
--  Un casillero admite UNA sola asignación viva (ux_position_assignment_activa),
--  y en el nivel de adulto cabe menos que abajo porque la caja es mayor.
--  Reubicar reparte entre casilleros libres en vez de exigir uno solo.
-- =============================================================================
-- =============================================================================

-- =============================================================================
--  BLOQUE A — REUBICAR PUDIENDO REPARTIR EN VARIOS CASILLEROS
-- =============================================================================
create or replace function public.reubicar_asignacion(
  p_assignment_id uuid,
  p_position_id   uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_asg      public.position_assignments;
  v_origen   public.positions;
  v_rack     text;
  v_destino  record;
  v_tope     integer := public.fn_niveles_infantiles();
  v_publico  text;
  v_restante integer;
  v_cuanto   integer;
  v_usadas   integer := 0;
  v_sitio    integer;
  v_huecos   integer;
  v_donde    text := '';
begin
  perform public.fn_exigir_rol('OPERARIO', 'SUPERVISOR', 'JEFE');

  select * into v_asg from public.position_assignments where id = p_assignment_id;
  if v_asg.id is null then
    raise exception 'Esa ubicación ya no existe.';
  end if;
  if v_asg.status = 'LIBERADA' then
    raise exception 'Esa ubicación ya fue liberada: no hay nada que mover.';
  end if;

  select * into v_origen from public.positions where id = v_asg.position_id;
  -- Con el almacén delante: los códigos de rack se repiten entre almacenes
  -- (hay un RACK-01 en cada uno), así que "no cabe en RACK-07" a secas no dice
  -- a cuál de los tres ir.
  select w.code || ' · ' || r.code into v_rack
    from public.racks r
    join public.warehouses w on w.id = r.warehouse_id
   where r.id = v_origen.rack_id;

  select pr.audience into v_publico
    from public.inventory_items it
    join public.products pr on pr.id = it.product_id
   where it.id = v_asg.item_id;

  -- Se libera primero: la posición de origen sale del índice único y, si algo
  -- falla más abajo, la excepción revierte también esto. La función es una
  -- sola transacción, así que la caja nunca queda en el limbo.
  update public.position_assignments
     set status = 'LIBERADA', released_at = now(), updated_at = now()
   where id = p_assignment_id;

  v_restante := v_asg.quantity;

  -- Destino explícito: va todo ahí y que el trigger de capacidad opine.
  if p_position_id is not null then
    select * into v_destino from public.positions where id = p_position_id;
    if v_destino.id is null then
      raise exception 'La posición de destino no existe.';
    end if;
    insert into public.position_assignments (position_id, item_id, quantity, status, notes)
    values (v_destino.id, v_asg.item_id, v_restante, v_asg.status,
            'Reubicada desde ' || v_origen.code || ' (nivel ' || v_origen.level || ')');

    return jsonb_build_object(
      'estado', 'REUBICADA', 'casilleros', 1,
      'mensaje', 'Movida de ' || v_origen.code || ' a ' || v_destino.code || '.'
    );
  end if;

  -- Sin destino: se reparte entre los casilleros LIBRES del mismo rack cuyo
  -- nivel admita este público. Libres de verdad — sin ninguna asignación viva —
  -- porque el índice ux_position_assignment_activa no permite dos.
  for v_destino in
    select p.*
      from public.positions p
     where p.rack_id = v_origen.rack_id
       and p.id <> v_origen.id
       and p.is_active
       and p.capacity_units > 0
       and case when v_publico = 'NINO'   then p.level <= v_tope
                when v_publico = 'ADULTO' then p.level >  v_tope
                else true end
       and not exists (
         select 1 from public.position_assignments a
          where a.position_id = p.id
            and a.status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
       )
     order by p.capacity_units desc, p.level, p.slot
  loop
    exit when v_restante <= 0;

    v_cuanto := least(v_restante, v_destino.capacity_units);
    insert into public.position_assignments (position_id, item_id, quantity, status, notes)
    values (v_destino.id, v_asg.item_id, v_cuanto, v_asg.status,
            'Reubicada desde ' || v_origen.code || ' (nivel ' || v_origen.level || ')');

    v_restante := v_restante - v_cuanto;
    v_usadas   := v_usadas + 1;
    v_donde    := v_donde || case when v_donde = '' then '' else ', ' end
                          || v_destino.code || ' (' || v_cuanto || ')';
  end loop;

  if v_restante > 0 then
    -- Cuánto habría hecho falta, para que el mensaje diga qué resolver y no
    -- solo que no se pudo.
    select coalesce(sum(p.capacity_units), 0), count(*)
      into v_sitio, v_huecos
      from public.positions p
     where p.rack_id = v_origen.rack_id
       and p.id <> v_origen.id
       and p.is_active
       and p.capacity_units > 0
       and case when v_publico = 'NINO'   then p.level <= v_tope
                when v_publico = 'ADULTO' then p.level >  v_tope
                else true end
       and not exists (
         select 1 from public.position_assignments a
          where a.position_id = p.id
            and a.status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
       );

    if v_huecos = 0 then
      raise exception 'En % no queda ningún casillero libre donde pueda ir calzado de %. O están todos ocupados, o sus casilleros son más angostos que la caja (revisa cuántas posiciones por nivel tiene el rack: a más casilleros, más chico cada uno).',
        v_rack, lower(coalesce(v_publico, 'ese público'));
    end if;

    raise exception 'En % caben % cajas en los % casilleros libres, y hay que mover %. Faltan % — reparte el resto en otro rack o quítale casilleros a este para que cada uno sea más ancho.',
      v_rack, v_sitio, v_huecos, v_asg.quantity, v_asg.quantity - v_sitio;
  end if;

  return jsonb_build_object(
    'estado',     'REUBICADA',
    'casilleros', v_usadas,
    'desde',      v_origen.code,
    'mensaje',    case when v_usadas = 1
                    then 'Movida de ' || v_origen.code || ' a ' || v_donde || '.'
                    else v_asg.quantity || ' unidades de ' || v_origen.code ||
                         ' repartidas en ' || v_usadas || ' casilleros: ' || v_donde || '.'
                  end
  );
end;
$fn$;

grant execute on function public.reubicar_asignacion(uuid, uuid) to authenticated;

comment on function public.reubicar_asignacion is
  'Mueve una asignación al nivel que le corresponde, repartiéndola en varios casilleros si no cabe en uno. Un casillero admite una sola asignación viva (ux_position_assignment_activa), así que reparte entre los que estén libres. Se llama DESPUÉS de mover la caja de verdad.';


-- =============================================================================
--  VERIFICACIÓN
-- =============================================================================
-- Qué hay pendiente y si el rack tiene sitio para ello. Una fila con
-- faltan > 0 es un rack que no puede absorber lo suyo: hay que quitarle
-- casilleros (para que cada uno sea más ancho) o llevar el resto a otro.
with pend as (
  select rp.rack_id, rp.rack, rp.almacen_code, rp.publico,
         sum(rp.unidades) as hay_que_mover
    from public.v_reubicaciones_pendientes rp
   group by rp.rack_id, rp.rack, rp.almacen_code, rp.publico
),
sitio as (
  select p.rack_id,
         sum(p.capacity_units) filter (where p.level > public.fn_niveles_infantiles()) as cabe_arriba,
         sum(p.capacity_units) filter (where p.level <= public.fn_niveles_infantiles()) as cabe_abajo
    from public.positions p
   where p.is_active
     and not exists (
       select 1 from public.position_assignments a
        where a.position_id = p.id
          and a.status in ('RESERVADA', 'OCUPADA', 'EN_PICKING'))
   group by p.rack_id
)
select
  pend.almacen_code,
  pend.rack,
  pend.publico,
  pend.hay_que_mover,
  case when pend.publico = 'NINO' then coalesce(sitio.cabe_abajo, 0)
       else coalesce(sitio.cabe_arriba, 0) end                        as cabe_en_los_libres,
  greatest(0, pend.hay_que_mover
             - case when pend.publico = 'NINO' then coalesce(sitio.cabe_abajo, 0)
                    else coalesce(sitio.cabe_arriba, 0) end)          as faltan
from pend
left join sitio on sitio.rack_id = pend.rack_id
order by faltan desc, pend.almacen_code, pend.rack;


-- =============================================================================
-- =============================================================================
--  MIGRACIÓN 19 — LA CAJA SE PUEDE GIRAR
--
--  El cálculo probaba la caja en una sola orientación, con el lado largo
--  siempre contra el frente. En un casillero de 29 cm daba 0 cajas de adulto;
--  girada 90 grados entran 12. Se prueban las dos y gana la mejor.
-- =============================================================================
-- =============================================================================

-- =============================================================================
--  BLOQUE A — PROBAR LAS DOS ORIENTACIONES Y QUEDARSE CON LA MEJOR
-- =============================================================================
-- La caja siempre apoya sobre su base (el alto es siempre el alto); lo que rota
-- es el rectángulo de abajo. Son dos formas de poner la misma caja en el mismo
-- estante, así que se calcula cuántas entran de cada una y gana la mayor.
create or replace function public.fn_cajas_en_slot(
  p_frente_m numeric,
  p_fondo_m  numeric,
  p_nivel    integer
)
returns integer
language sql
immutable
set search_path = public
as $fn$
  with caja as (
    select
      case when p_nivel <= public.fn_niveles_infantiles() then 0.22 else 0.35 end as largo,
      case when p_nivel <= public.fn_niveles_infantiles() then 0.15 else 0.25 end as ancho,
      case when p_nivel <= public.fn_niveles_infantiles() then 0.09 else 0.13 end as alto
  ),
  -- Las dos formas de apoyarla: a lo largo del frente, o girada 90 grados.
  orientaciones as (
    select largo as x, ancho as y, alto from caja
    union all
    select ancho as x, largo as y, alto from caja
  ),
  cuentan as (
    select floor(p_frente_m / x) * floor(p_fondo_m / y) * floor(0.45 / alto) as cajas
      from orientaciones
  )
  select greatest(0, floor(max(cajas) * 0.85)::integer) from cuentan;
$fn$;

comment on function public.fn_cajas_en_slot is
  'Cajas que entran en un casillero de p_frente_m x p_fondo_m según su nivel, probando la caja en sus dos orientaciones horizontales. Infantil 22x15x9 cm en los niveles bajos; adulto 35x25x13 (caja de hombre, la mayor) del resto. 45 cm de luz entre estantes y 15% de holgura de maniobra.';


-- =============================================================================
--  BLOQUE B — VOLVER A MEDIR TODO LO YA DECLARADO
-- =============================================================================
-- Las capacidades vigentes se calcularon sin girar la caja: las de casillero
-- angosto están subestimadas, y una de ellas en 0. fn_recalcular_capacidades
-- nunca declara menos de lo que la posición ya tiene adentro.
do $bloque$
declare
  r record;
begin
  for r in select id from public.racks loop
    perform public.fn_recalcular_capacidades(r.id);
  end loop;
end;
$bloque$;


-- =============================================================================
--  VERIFICACIÓN
-- =============================================================================
-- 1. Un casillero angosto ya no da 0. Con 29 cm de frente y 2 m de fondo, una
--    caja de adulto solo entra girada.
select
  '29 cm de frente (ALM-04/RACK-01)' as caso,
  public.fn_cajas_en_slot(0.29, 2, 3)  as adulto,
  public.fn_cajas_en_slot(0.29, 2, 1)  as infantil
union all
select
  '56 cm de frente (RACK-07)',
  public.fn_cajas_en_slot(0.56, 2, 3),
  public.fn_cajas_en_slot(0.56, 2, 1);
-- Esperado: adulto 12 y 25 (antes 0 y 20).

-- 2. Ningún nivel debería quedar en capacidad 0. Si sale alguno, su casillero
--    es más angosto que la caja incluso girada: hay que darle menos posiciones
--    por nivel a ese rack para que cada una sea más ancha.
select
  w.code           as almacen,
  r.code           as rack,
  p.level          as nivel,
  count(*)         as casilleros,
  max(p.capacity_units) as capacidad
from public.positions p
join public.racks      r on r.id = p.rack_id
join public.warehouses w on w.id = r.warehouse_id
where p.capacity_units = 0
group by w.code, r.code, p.level
order by w.code, r.code, p.level;


-- =============================================================================
-- =============================================================================
--  MIGRACIÓN 20 — CASILLEROS POR MODELO, ESTANTES SINCRONIZADOS CON EL STOCK
--                 Y RACKS CON FORMA DE ESTANTERÍA
--
--  Un casillero guarda un modelo con todas sus tallas; ejecutar un movimiento
--  mueve cajas en los estantes y no solo en el stock; la capacidad deja de
--  inflarse; y un rack tiene 1 o 2 m de fondo con frente del doble.
-- =============================================================================
-- =============================================================================

-- =============================================================================
--  BLOQUE A — LA CAPACIDAD DICE LO QUE CABE, NO LO QUE HAY
-- =============================================================================
-- Sin el greatest(calculado, ocupado): un casillero pasado de cajas queda con
-- su capacidad física y se ve sobrecargado. Esconderlo inflando el número era
-- la forma más segura de que nadie lo arreglara nunca.
create or replace function public.fn_recalcular_capacidades(p_rack_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_frente numeric;
  v_fondo  numeric;
begin
  select greatest(grid_ancho, grid_alto), least(grid_ancho, grid_alto)
    into v_frente, v_fondo
    from public.racks where id = p_rack_id;

  update public.positions p
     set capacity_units = public.fn_cajas_en_slot(v_frente / n.slots, v_fondo, p.level),
         updated_at     = now()
    from (
      select pp.id, count(*) over (partition by pp.level) as slots
        from public.positions pp
       where pp.rack_id = p_rack_id
    ) n
   where n.id = p.id;
end;
$fn$;


-- =============================================================================
--  BLOQUE B — EL TRIGGER DE CAPACIDAD, SIN "0 = SIN LÍMITE" Y SIN TRABAR SALIDAS
-- =============================================================================
create or replace function public.fn_validar_capacidad_posicion()
returns trigger
language plpgsql
set search_path = public
as $fn$
declare
  v_capacidad integer;
  v_ocupado   integer;
  v_codigo    text;
begin
  if new.status = 'LIBERADA' then
    return new;
  end if;

  -- Sacar cajas nunca se bloquea, ni siquiera de un casillero sobrecargado: es
  -- justamente como se lo descarga.
  if tg_op = 'UPDATE' and old.status <> 'LIBERADA' and new.quantity <= old.quantity then
    return new;
  end if;

  -- Dos operarios ubicando en el mismo casillero a la vez sumarían cada uno
  -- sobre lo que vio antes que el otro. El candado serializa por casillero y
  -- cubre también el trigger de modelo, que corre después de este.
  perform pg_advisory_xact_lock(hashtext(new.position_id::text));

  select capacity_units, code into v_capacidad, v_codigo
    from public.positions where id = new.position_id;

  select coalesce(sum(quantity), 0) into v_ocupado
    from public.position_assignments
   where position_id = new.position_id
     and status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
     and id <> coalesce(new.id, '00000000-0000-0000-0000-000000000000'::uuid);

  -- Toda capacidad sale ahora de fn_cajas_en_slot: 0 no es "sin límite
  -- declarado" sino un casillero donde no entra ni una caja.
  if v_ocupado + new.quantity > coalesce(v_capacidad, 0) then
    raise exception 'El casillero % no tiene espacio: caben %, ya hay %, se intenta dejar %.',
      v_codigo, coalesce(v_capacidad, 0), v_ocupado, new.quantity
      using errcode = 'check_violation';
  end if;

  return new;
end;
$fn$;


-- =============================================================================
--  BLOQUE C — UN CASILLERO, UN MODELO (CON TODAS SUS TALLAS)
-- =============================================================================
-- El índice de la 01 decía "una asignación viva por casillero". Ahora es una
-- por talla y casillero: la misma talla dos veces en el mismo sitio sería la
-- misma caja contada dos veces, así que se suma a su fila en vez de duplicarla.
drop index if exists public.ux_position_assignment_activa;
create unique index if not exists ux_position_item_activa
  on public.position_assignments (position_id, item_id)
  where status in ('RESERVADA', 'OCUPADA', 'EN_PICKING');

create or replace function public.fn_validar_un_modelo_por_casillero()
returns trigger
language plpgsql
set search_path = public
as $fn$
declare
  v_modelo uuid;
  v_otro   text;
  v_codigo text;
begin
  if new.status = 'LIBERADA' then
    return new;
  end if;

  select product_id into v_modelo from public.inventory_items where id = new.item_id;

  select pr.model_code || ' ' || pr.name into v_otro
    from public.position_assignments pa
    join public.inventory_items it on it.id = pa.item_id
    join public.products        pr on pr.id = it.product_id
   where pa.position_id = new.position_id
     and pa.status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
     and pa.id <> coalesce(new.id, '00000000-0000-0000-0000-000000000000'::uuid)
     and it.product_id <> v_modelo
   limit 1;

  if v_otro is not null then
    select code into v_codigo from public.positions where id = new.position_id;
    raise exception 'El casillero % ya guarda %: un casillero admite un solo modelo, con todas sus tallas juntas. Usa otro casillero.',
      v_codigo, v_otro
      using errcode = 'check_violation';
  end if;

  return new;
end;
$fn$;

drop trigger if exists trg_assign_un_modelo on public.position_assignments;
create trigger trg_assign_un_modelo
  before insert or update on public.position_assignments
  for each row execute function public.fn_validar_un_modelo_por_casillero();

comment on trigger trg_assign_un_modelo on public.position_assignments is
  'Un casillero guarda un solo modelo, con cualquier combinación de sus tallas. Es lo que evita confundir un modelo con otro al hacer picking sin inmovilizar un casillero entero por una caja.';


-- =============================================================================
--  BLOQUE D — LA REGLA DE NIVEL NO TRABA SACAR CAJAS
-- =============================================================================
-- Con las salidas descontando del casillero (bloque F), una SALIDA de las
-- cajas de adulto que quedaron en el nivel 2 tras la migración 15 reescribe su
-- fila, y el trigger de público la rechazaba por estar en un nivel infantil.
-- Sacar cajas de donde ya están no ubica nada nuevo: se valida solo cuando se
-- ubica o se agrega.
create or replace function public.fn_validar_publico_por_nivel()
returns trigger
language plpgsql
set search_path = public
as $fn$
declare
  v_audience text;
  v_level    smallint;
  v_tope     integer := public.fn_niveles_infantiles();
begin
  if new.status = 'LIBERADA' then
    return new;
  end if;

  if tg_op = 'UPDATE'
     and new.position_id = old.position_id
     and new.item_id     = old.item_id
     and new.quantity   <= old.quantity then
    return new;
  end if;

  select p.audience into v_audience
    from public.inventory_items it
    join public.products        p  on p.id = it.product_id
   where it.id = new.item_id;

  select level into v_level from public.positions where id = new.position_id;

  if v_level is null then
    raise exception 'La posición % no tiene nivel definido.', new.position_id;
  end if;

  if v_audience = 'NINO' and v_level > v_tope then
    raise exception
      'Calzado infantil solo puede ubicarse hasta el nivel % (los de abajo). La posición elegida está en el nivel %.',
      v_tope, v_level
      using errcode = 'check_violation';
  end if;

  if v_audience = 'ADULTO' and v_level <= v_tope then
    raise exception
      'Calzado de adulto no puede ubicarse en el nivel %: los niveles 1 a % están reservados para calzado infantil.',
      v_level, v_tope
      using errcode = 'check_violation';
  end if;

  return new;
end;
$fn$;


-- =============================================================================
--  BLOQUE E — LAS VISTAS, AL DÍA CON LOS CASILLEROS COMPARTIDOS
-- =============================================================================
-- v_mapa_almacen ya devolvía una fila por asignación viva: con varias tallas en
-- un casillero, devuelve una por talla. Se agrega el modelo al final (create or
-- replace view solo permite sumar columnas detrás) para que la pantalla sepa
-- dónde puede ir cada artículo.
create or replace view public.v_mapa_almacen as
select
  pos.id            as position_id,
  w.code            as almacen_code,
  w.name            as almacen,
  r.code            as rack,
  pos.code          as posicion,
  pos.level,
  pos.capacity_units,
  pa.id             as assignment_id,
  pa.status         as estado_ocupacion,   -- NULL = libre
  pa.quantity       as unidades,
  pa.item_id,
  it.sku,
  pr.name           as producto,
  it.size_label     as talla,
  pr.audience,
  pa.assigned_at,
  it.product_id,
  pr.model_code
from public.positions pos
join public.racks      r on r.id = pos.rack_id
join public.warehouses w on w.id = r.warehouse_id
left join public.position_assignments pa
       on pa.position_id = pos.id
      and pa.status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
left join public.inventory_items it on it.id = pa.item_id
left join public.products        pr on pr.id = it.product_id;

alter view public.v_mapa_almacen set (security_invoker = on);

-- Parcial y por almacén: lo que falta ubicar es el stock menos lo que ya está
-- en estantes de ESE almacén, no "¿tiene alguna caja en algún lado?".
create or replace view public.v_stock_sin_ubicar as
with en_estantes as (
  select pa.item_id, r.warehouse_id, sum(pa.quantity) as ubicado
    from public.position_assignments pa
    join public.positions pos on pos.id = pa.position_id
    join public.racks     r   on r.id   = pos.rack_id
   where pa.status in ('OCUPADA', 'EN_PICKING')
   group by pa.item_id, r.warehouse_id
)
select
  inv.id                               as inventory_id,
  it.sku,
  p.name                               as producto,
  it.size_label                        as talla,
  w.name                               as almacen,
  inv.quantity,
  coalesce(e.ubicado, 0)               as ubicado,
  inv.quantity - coalesce(e.ubicado, 0) as sin_ubicar
from public.inventory inv
join public.inventory_items it on it.id = inv.item_id
join public.products        p  on p.id  = it.product_id
join public.warehouses      w  on w.id  = inv.warehouse_id
left join en_estantes e on e.item_id = inv.item_id and e.warehouse_id = inv.warehouse_id
where inv.quantity > coalesce(e.ubicado, 0);

alter view public.v_stock_sin_ubicar set (security_invoker = on);


-- =============================================================================
--  BLOQUE F — LOS MOVIMIENTOS MUEVEN CAJAS EN LOS ESTANTES
-- =============================================================================
-- F.1 El casillero de un movimiento tiene que estar en el almacén de su stock.
-- Es lo único que no cambia entre crear y ejecutar, así que se revisa al crear;
-- cuántas cajas hay en el casillero se revisa al ejecutar, que es cuando importa.
create or replace function public.fn_validar_casillero_del_movimiento()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_wh_pos uuid;
  v_wh_inv uuid;
  v_codigo text;
begin
  if new.position_id is null or new.inventory_id is null then
    return new;
  end if;

  select r.warehouse_id, pos.code into v_wh_pos, v_codigo
    from public.positions pos
    join public.racks r on r.id = pos.rack_id
   where pos.id = new.position_id;

  select warehouse_id into v_wh_inv from public.inventory where id = new.inventory_id;

  if v_wh_pos is distinct from v_wh_inv then
    raise exception 'El casillero % está en otro almacén que el stock de este artículo.', v_codigo
      using errcode = 'check_violation';
  end if;

  return new;
end;
$fn$;

drop trigger if exists trg_mov_casillero on public.inventory_movements;
create trigger trg_mov_casillero
  before insert on public.inventory_movements
  for each row execute function public.fn_validar_casillero_del_movimiento();

-- F.2 Ejecutar: igual que en la 02, más el bloque "los estantes siguen al
-- stock". Como la reversión (fn_revertir_movimiento) inserta un contra-asiento
-- con el mismo position_id y lo ejecuta por acá, revertir también devuelve o
-- retira las cajas del casillero sin código adicional.
create or replace function public.fn_ejecutar_movimiento(
  p_movement_id   uuid,
  p_user_id       uuid    default null,
  p_cantidad_real integer default null,   -- NULL = llegó/salió exactamente lo aprobado
  p_quality       text    default 'BUENO'
)
returns public.inventory_movements
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_mov     public.inventory_movements;
  v_inv     public.inventory;
  v_real    integer;
  v_delta   integer;
  v_before  integer;
  v_pos     public.positions;
  v_pos_wh  uuid;
  v_asg     public.position_assignments;
  v_ubicado integer;
  v_donde   text;
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
    if p_quality = 'BUENO' then
      update public.inventory
         set qty_incoming = greatest(qty_incoming - v_mov.quantity, 0),
             quantity     = quantity + v_real
       where id = v_inv.id;
      v_delta := v_real;
    else
      -- Dañada o en cuarentena: entra al almacén pero NO al stock vendible
      -- (E-05), y por lo mismo tampoco a un estante de venta.
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
    -- Reserva y stock en la MISMA sentencia: evita que qty_reserved <= quantity
    -- reviente a mitad.
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

  -- ---------------------------------------------------------------------------
  -- LOS ESTANTES SIGUEN AL STOCK. v_delta ya es exactamente cuántas cajas
  -- entran (+) o salen (-) de circulación. Con casillero, se suman o restan
  -- ahí. Sin casillero, entrar deja las cajas en recepción; salir solo puede
  -- tomar de lo que no está en ningún estante, porque si no los estantes
  -- terminarían mostrando pares que ya no existen.
  -- ---------------------------------------------------------------------------
  if v_delta <> 0 and v_mov.position_id is not null then
    select * into v_pos from public.positions where id = v_mov.position_id;
    select warehouse_id into v_pos_wh from public.racks where id = v_pos.rack_id;
    if v_pos_wh is distinct from v_inv.warehouse_id then
      raise exception 'El casillero % está en otro almacén que el stock de este artículo.', v_pos.code;
    end if;

    select * into v_asg
      from public.position_assignments
     where position_id = v_mov.position_id
       and item_id     = v_mov.item_id
       and status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
     for update;

    if v_delta > 0 then
      -- Los triggers de capacidad, modelo y nivel opinan acá: si el casillero
      -- no admite estas cajas, la ejecución entera se revierte con el motivo.
      if v_asg.id is null then
        insert into public.position_assignments (position_id, item_id, quantity, status, assigned_by, notes)
        values (v_mov.position_id, v_mov.item_id, v_delta, 'OCUPADA', p_user_id,
                'Ubicada al ejecutar el movimiento ' || v_mov.id::text);
      else
        update public.position_assignments
           set quantity = quantity + v_delta, updated_at = now()
         where id = v_asg.id;
      end if;
    else
      if v_asg.id is null or v_asg.quantity < -v_delta then
        raise exception 'En el casillero % hay % de este artículo y se quieren sacar %.',
          v_pos.code, coalesce(v_asg.quantity, 0), -v_delta;
      end if;
      if v_asg.quantity = -v_delta then
        update public.position_assignments
           set quantity = 0, status = 'LIBERADA', released_at = now(), updated_at = now()
         where id = v_asg.id;
      else
        update public.position_assignments
           set quantity = quantity + v_delta, updated_at = now()
         where id = v_asg.id;
      end if;
    end if;

  elsif v_delta < 0 then
    select coalesce(sum(pa.quantity), 0) into v_ubicado
      from public.position_assignments pa
      join public.positions pos on pos.id = pa.position_id
      join public.racks     r   on r.id   = pos.rack_id
     where pa.item_id = v_mov.item_id
       and r.warehouse_id = v_inv.warehouse_id
       and pa.status in ('OCUPADA', 'EN_PICKING');

    if v_before - v_ubicado < -v_delta then
      select string_agg(pos.code || ' (' || pa.quantity || ')', ', ' order by pos.code)
        into v_donde
        from public.position_assignments pa
        join public.positions pos on pos.id = pa.position_id
        join public.racks     r   on r.id   = pos.rack_id
       where pa.item_id = v_mov.item_id
         and r.warehouse_id = v_inv.warehouse_id
         and pa.status in ('OCUPADA', 'EN_PICKING');

      raise exception 'Solo % de estos pares están fuera de los estantes y se quieren sacar % sin decir de qué casillero. Indica el casillero de origen: %.',
        greatest(v_before - v_ubicado, 0), -v_delta, coalesce(v_donde, 'ninguno');
    end if;
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
$fn$;


-- =============================================================================
--  BLOQUE G — UBICAR Y REUBICAR, CON CASILLEROS COMPARTIDOS
-- =============================================================================
-- G.1 Ubicar: por RPC y no con un INSERT desde el cliente. Si el casillero ya
-- guarda esta talla se suma a su fila (el índice admite una por talla), y no se
-- puede poner en un estante más pares de los que el almacén tiene: ese era el
-- otro camino por el que los estantes terminaban teniendo más que el stock.
create or replace function public.ubicar_en_casillero(
  p_position_id uuid,
  p_item_id     uuid,
  p_quantity    integer,
  p_status      text default 'OCUPADA',
  p_notes       text default null
)
returns public.position_assignments
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_asg     public.position_assignments;
  v_wh      uuid;
  v_codigo  text;
  v_stock   integer;
  v_ubicado integer;
  v_status  text := coalesce(p_status, 'OCUPADA');
begin
  perform public.fn_exigir_rol('OPERARIO', 'SUPERVISOR', 'JEFE');

  if p_quantity is null or p_quantity <= 0 then
    raise exception 'La cantidad debe ser mayor que cero.';
  end if;

  select r.warehouse_id, pos.code into v_wh, v_codigo
    from public.positions pos
    join public.racks r on r.id = pos.rack_id
   where pos.id = p_position_id;
  if v_wh is null then
    raise exception 'Ese casillero no existe.';
  end if;

  -- RESERVADA aparta sitio para un INBOUND que todavía no llegó: ahí no tiene
  -- sentido pedir stock. Lo demás son cajas físicas.
  if v_status <> 'RESERVADA' then
    select quantity into v_stock
      from public.inventory
     where item_id = p_item_id and warehouse_id = v_wh;
    if v_stock is null then
      raise exception 'Este artículo no tiene stock registrado en el almacén del casillero %.', v_codigo;
    end if;

    select coalesce(sum(pa.quantity), 0) into v_ubicado
      from public.position_assignments pa
      join public.positions pos on pos.id = pa.position_id
      join public.racks     r   on r.id   = pos.rack_id
     where pa.item_id = p_item_id
       and r.warehouse_id = v_wh
       and pa.status in ('OCUPADA', 'EN_PICKING');

    if v_ubicado + p_quantity > v_stock then
      raise exception 'Hay % pares en stock y % ya están en estantes: quedan % por ubicar y se intenta ubicar %.',
        v_stock, v_ubicado, greatest(v_stock - v_ubicado, 0), p_quantity;
    end if;
  end if;

  select * into v_asg
    from public.position_assignments
   where position_id = p_position_id
     and item_id     = p_item_id
     and status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
   for update;

  if v_asg.id is null then
    insert into public.position_assignments (position_id, item_id, quantity, status, assigned_by, notes)
    values (p_position_id, p_item_id, p_quantity, v_status, public.actor_actual(), p_notes)
    returning * into v_asg;
  else
    update public.position_assignments
       set quantity = quantity + p_quantity,
           updated_at = now(),
           notes = coalesce(p_notes, notes)
     where id = v_asg.id
    returning * into v_asg;
  end if;

  return v_asg;
end;
$fn$;

grant execute on function public.ubicar_en_casillero(uuid, uuid, integer, text, text) to authenticated;

-- G.2 Reubicar: ahora también a casilleros que ya guardan el mismo modelo y
-- tienen sitio, empezando por los que ya tienen esa misma talla (se suma a su
-- fila) y después los del mismo modelo, para juntar las tallas antes de
-- estrenar un casillero vacío.
create or replace function public.reubicar_asignacion(
  p_assignment_id uuid,
  p_position_id   uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_asg      public.position_assignments;
  v_origen   public.positions;
  v_rack     text;
  v_destino  record;
  v_tope     integer := public.fn_niveles_infantiles();
  v_publico  text;
  v_modelo   uuid;
  v_restante integer;
  v_cuanto   integer;
  v_usadas   integer := 0;
  v_donde    text := '';
begin
  perform public.fn_exigir_rol('OPERARIO', 'SUPERVISOR', 'JEFE');

  select * into v_asg from public.position_assignments where id = p_assignment_id;
  if v_asg.id is null then
    raise exception 'Esa ubicación ya no existe.';
  end if;
  if v_asg.status = 'LIBERADA' then
    raise exception 'Esa ubicación ya fue liberada: no hay nada que mover.';
  end if;

  select * into v_origen from public.positions where id = v_asg.position_id;
  -- Con el almacén delante: los códigos de rack se repiten entre almacenes.
  select w.code || ' · ' || r.code into v_rack
    from public.racks r
    join public.warehouses w on w.id = r.warehouse_id
   where r.id = v_origen.rack_id;

  select pr.audience, pr.id into v_publico, v_modelo
    from public.inventory_items it
    join public.products pr on pr.id = it.product_id
   where it.id = v_asg.item_id;

  -- Se libera primero; si algo falla más abajo, la excepción revierte también
  -- esto. La caja nunca queda en el limbo.
  update public.position_assignments
     set status = 'LIBERADA', released_at = now(), updated_at = now()
   where id = p_assignment_id;

  v_restante := v_asg.quantity;

  for v_destino in
    select p.id, p.code, p.level, p.slot,
           p.capacity_units - coalesce(oc.ocupado, 0) as libre,
           coalesce(oc.misma_talla, false)            as misma_talla,
           oc.ocupado is not null                     as mismo_modelo
      from public.positions p
      left join lateral (
        select sum(a.quantity)                    as ocupado,
               bool_or(a.item_id = v_asg.item_id) as misma_talla,
               bool_or(it.product_id <> v_modelo) as otro_modelo
          from public.position_assignments a
          join public.inventory_items it on it.id = a.item_id
         where a.position_id = p.id
           and a.status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
      ) oc on true
     where (p_position_id is null or p.id = p_position_id)
       and (p_position_id is not null or p.rack_id = v_origen.rack_id)
       and p.id <> v_origen.id
       and p.is_active
       and case when v_publico = 'NINO'   then p.level <= v_tope
                when v_publico = 'ADULTO' then p.level >  v_tope
                else true end
       and not coalesce(oc.otro_modelo, false)
       and p.capacity_units - coalesce(oc.ocupado, 0) > 0
     order by misma_talla desc, mismo_modelo desc, libre desc, p.level, p.slot
  loop
    exit when v_restante <= 0;

    v_cuanto := least(v_restante, v_destino.libre);

    update public.position_assignments
       set quantity = quantity + v_cuanto, updated_at = now()
     where position_id = v_destino.id
       and item_id     = v_asg.item_id
       and status in ('RESERVADA', 'OCUPADA', 'EN_PICKING');
    if not found then
      insert into public.position_assignments (position_id, item_id, quantity, status, notes)
      values (v_destino.id, v_asg.item_id, v_cuanto, v_asg.status,
              'Reubicada desde ' || v_origen.code || ' (nivel ' || v_origen.level || ')');
    end if;

    v_restante := v_restante - v_cuanto;
    v_usadas   := v_usadas + 1;
    v_donde    := v_donde || case when v_donde = '' then '' else ', ' end
                          || v_destino.code || ' (' || v_cuanto || ')';
  end loop;

  if v_restante > 0 then
    if v_usadas = 0 then
      raise exception 'En % no queda ningún casillero donde pueda ir este modelo de %: están ocupados por otros modelos, llenos, o son más angostos que la caja.',
        v_rack, lower(coalesce(v_publico, 'ese público'));
    end if;
    raise exception 'En % caben % de las % cajas en los % casilleros con sitio para este modelo. Faltan % — reparte el resto en otro rack.',
      v_rack, v_asg.quantity - v_restante, v_asg.quantity, v_usadas, v_restante;
  end if;

  return jsonb_build_object(
    'estado',     'REUBICADA',
    'casilleros', v_usadas,
    'desde',      v_origen.code,
    'mensaje',    case when v_usadas = 1
                    then 'Movida de ' || v_origen.code || ' a ' || v_donde || '.'
                    else v_asg.quantity || ' cajas de ' || v_origen.code ||
                         ' repartidas en ' || v_usadas || ' casilleros: ' || v_donde || '.'
                  end
  );
end;
$fn$;

grant execute on function public.reubicar_asignacion(uuid, uuid) to authenticated;


-- =============================================================================
--  BLOQUE H — UN RACK TIENE FORMA DE ESTANTERÍA
-- =============================================================================
-- H.1 La regla va en el trigger de geometría (con su porqué) además del CHECK:
-- los BEFORE triggers corren antes que los CHECK, así que quien arrastra un
-- rack en el editor lee esta explicación y no "violates ck_racks_geometria".
create or replace function public.fn_validar_geometria_rack()
returns trigger
language plpgsql
set search_path = public
as $fn$
declare
  v_alm       public.warehouses;
  v_conflicto text;
begin
  select * into v_alm from public.warehouses where id = new.warehouse_id;

  if least(new.grid_ancho, new.grid_alto) > 2 then
    raise exception 'El rack % tendría % m de fondo. Una estantería se usa desde el pasillo y el brazo no llega tan adentro: el fondo va de 1 m (una cara) a 2 m (dos estanterías espalda con espalda).',
      new.code, least(new.grid_ancho, new.grid_alto)
      using errcode = 'check_violation';
  end if;

  if greatest(new.grid_ancho, new.grid_alto) < 2 * least(new.grid_ancho, new.grid_alto) then
    raise exception 'El rack % sería de % x % m: una estantería es larga y angosta, y su frente tiene que medir al menos el doble que su fondo.',
      new.code, new.grid_ancho, new.grid_alto
      using errcode = 'check_violation';
  end if;

  if new.grid_x + new.grid_ancho > v_alm.grid_ancho
     or new.grid_y + new.grid_alto > v_alm.grid_alto then
    raise exception 'El rack % no cabe: se sale del plano del almacén (% x % celdas).',
      new.code, v_alm.grid_ancho, v_alm.grid_alto
      using errcode = 'check_violation';
  end if;

  -- Dos rectángulos se pisan solo si se solapan en LOS DOS ejes a la vez.
  select code into v_conflicto
    from public.racks
   where warehouse_id = new.warehouse_id
     and id <> new.id
     and new.grid_x < grid_x + grid_ancho
     and grid_x     < new.grid_x + new.grid_ancho
     and new.grid_y < grid_y + grid_alto
     and grid_y     < new.grid_y + new.grid_alto
   limit 1;

  if v_conflicto is not null then
    raise exception 'El rack % se superpone con el rack %. Muévelo a un espacio libre.',
      new.code, v_conflicto
      using errcode = 'check_violation';
  end if;

  if v_alm.entrada_x >= new.grid_x and v_alm.entrada_x < new.grid_x + new.grid_ancho
     and v_alm.entrada_y >= new.grid_y and v_alm.entrada_y < new.grid_y + new.grid_alto then
    raise exception 'El rack % taparía la entrada del almacén (celda %, %). Deja la puerta despejada.',
      new.code, v_alm.entrada_x, v_alm.entrada_y
      using errcode = 'check_violation';
  end if;

  return new;
end;
$fn$;

-- H.2 Los racks que no tienen forma de estantería se ACHICAN por el fondo.
-- Achicar nunca pisa otro rack ni tapa la puerta; agrandar podría, y decidir
-- hacia dónde crece un mueble es decidir por el usuario. Hoy son dos:
-- ALM-A · RACK-03 (12 x 3 -> 12 x 2) y ALM-04 · RACK-01 (2 x 2 -> 1 x 2).
-- El trigger trg_racks_capacidad recalcula la capacidad con la versión honesta
-- del bloque A: si quedan casilleros pasados de cajas, se verán.
update public.racks r
   set grid_ancho = case when r.grid_ancho <= r.grid_alto then s.fondo else r.grid_ancho end,
       grid_alto  = case when r.grid_ancho >  r.grid_alto then s.fondo else r.grid_alto  end
  from (
    select id,
           greatest(1, least(least(grid_ancho, grid_alto), 2, greatest(grid_ancho, grid_alto) / 2)) as fondo
      from public.racks
  ) s
 where s.id = r.id
   and (least(r.grid_ancho, r.grid_alto) > 2
        or greatest(r.grid_ancho, r.grid_alto) < 2 * least(r.grid_ancho, r.grid_alto));

-- H.3 Si alguno no se pudo arreglar achicándolo (un 1 x 1, por ejemplo), se
-- nombra acá en vez de dejar que el ALTER de abajo falle sin decir cuál.
do $bloque$
declare
  v_mal text;
begin
  select string_agg(w.code || ' · ' || r.code || ' (' || r.grid_ancho || ' x ' || r.grid_alto || ')', ', ')
    into v_mal
    from public.racks r
    join public.warehouses w on w.id = r.warehouse_id
   where least(r.grid_ancho, r.grid_alto) > 2
      or greatest(r.grid_ancho, r.grid_alto) < 2 * least(r.grid_ancho, r.grid_alto);

  if v_mal is not null then
    raise exception 'Estos racks no se pudieron llevar a forma de estantería achicándolos: %. Agrándalos a mano en el editor (el frente tiene que medir al menos el doble que el fondo) y vuelve a correr la migración.', v_mal;
  end if;
end;
$bloque$;

alter table public.racks drop constraint if exists ck_racks_geometria;
alter table public.racks
  add constraint ck_racks_geometria check (
    grid_x >= 0 and grid_y >= 0
    and least(grid_ancho, grid_alto) between 1 and 2
    and greatest(grid_ancho, grid_alto) between 2 and 60
    and greatest(grid_ancho, grid_alto) >= 2 * least(grid_ancho, grid_alto)
  );


-- =============================================================================
--  BLOQUE I — RECALCULAR TODO CON LA CAPACIDAD HONESTA
-- =============================================================================
do $bloque$
declare
  r record;
begin
  for r in select id from public.racks loop
    perform public.fn_recalcular_capacidades(r.id);
  end loop;
end;
$bloque$;


-- =============================================================================
--  VERIFICACIÓN
-- =============================================================================
-- 1. Casilleros con más cajas de las que caben. Antes la capacidad se inflaba
--    para taparlos; ahora quedan a la vista. Se descargan con una SALIDA desde
--    ese casillero o reubicando.
select w.code as almacen, r.code as rack, pos.code as casillero, pos.level as nivel,
       pos.capacity_units as caben, sum(pa.quantity) as hay
  from public.positions pos
  join public.racks      r on r.id = pos.rack_id
  join public.warehouses w on w.id = r.warehouse_id
  join public.position_assignments pa
    on pa.position_id = pos.id and pa.status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
 group by w.code, r.code, pos.code, pos.level, pos.capacity_units
having sum(pa.quantity) > pos.capacity_units
 order by 1, 2, 3;

-- 2. Artículos con más pares en estantes que en stock: el rastro que dejaron
--    las SALIDAS que no descontaban del casillero. Son cajas fantasma: se
--    corrigen liberando en el mapa lo que ya no está físicamente.
select w.code as almacen, it.sku, inv.quantity as stock, u.ubicado as en_estantes,
       u.ubicado - inv.quantity as sobran
  from public.inventory inv
  join public.inventory_items it on it.id = inv.item_id
  join public.warehouses      w  on w.id  = inv.warehouse_id
  join (
    select pa.item_id, r.warehouse_id, sum(pa.quantity) as ubicado
      from public.position_assignments pa
      join public.positions pos on pos.id = pa.position_id
      join public.racks     r   on r.id   = pos.rack_id
     where pa.status in ('OCUPADA', 'EN_PICKING')
     group by pa.item_id, r.warehouse_id
  ) u on u.item_id = inv.item_id and u.warehouse_id = inv.warehouse_id
 where u.ubicado > inv.quantity
 order by sobran desc;

-- 3. Todos los racks con forma de estantería.
select w.code as almacen, r.code as rack, r.grid_ancho || ' x ' || r.grid_alto as medida
  from public.racks r
  join public.warehouses w on w.id = r.warehouse_id
 order by 1, 2;


-- =============================================================================
-- =============================================================================
--  MIGRACIÓN 21 — CASILLEROS A MEDIDA DE UN MODELO Y REVISIÓN DE UBICACIONES
--
--  El sistema calcula cuántos casilleros tiene cada nivel para que cada uno
--  mida lo que ocupa un modelo (mediana del stock real); el código de posición
--  admite 3 dígitos; y una vista con su corrección por tipo revisa todo lo
--  que está fuera de lugar.
-- =============================================================================
-- =============================================================================

-- =============================================================================
--  BLOQUE A — EL CÓDIGO DE POSICIÓN ADMITE 3 DÍGITOS AL FINAL
-- =============================================================================
alter table public.positions drop constraint if exists positions_code_check;
alter table public.positions
  add constraint positions_code_check check (code ~ '^[A-Z0-9]-[0-9]{2}-[0-9]{2,3}$');


-- El comentario de la columna seguía diciendo "0 = sin límite declarado", falso
-- desde la migración 20: toda capacidad sale de fn_cajas_en_slot.
comment on column public.positions.capacity_units is
  'Cajas que entran en el casillero según fn_cajas_en_slot. 0 significa que no entra ninguna (el casillero es más angosto que la caja), no "sin límite".';


-- =============================================================================
--  BLOQUE B — LAS MEDIDAS DE LA CAJA, EN UN SOLO LUGAR
-- =============================================================================
-- El cálculo de casilleros necesita las medidas para saber cuánto sobra, y
-- fn_cajas_en_slot las tenía escritas adentro. Dos copias de los mismos
-- centímetros terminan divergiendo; ahora ambas leen de acá.
create or replace function public.fn_medidas_caja(p_nivel integer)
returns numeric[]
language sql
immutable
set search_path = public
as $fn$
  select case when p_nivel <= public.fn_niveles_infantiles()
              then array[0.22, 0.15, 0.09]::numeric[]    -- infantil
              else array[0.35, 0.25, 0.13]::numeric[]    -- adulto (caja de hombre, la mayor)
         end;
$fn$;

-- Mismo resultado que la migración 19 (las dos orientaciones, gana la mejor),
-- leyendo las medidas de fn_medidas_caja.
create or replace function public.fn_cajas_en_slot(
  p_frente_m numeric,
  p_fondo_m  numeric,
  p_nivel    integer
)
returns integer
language sql
immutable
set search_path = public
as $fn$
  with c as (select public.fn_medidas_caja(p_nivel) as m),
  orientaciones as (
    select m[1] as x, m[2] as y, m[3] as alto from c
    union all
    select m[2] as x, m[1] as y, m[3] as alto from c
  )
  select greatest(0, floor(
           max(floor(p_frente_m / x) * floor(p_fondo_m / y) * floor(0.45 / alto)) * 0.85
         )::integer)
    from orientaciones;
$fn$;


-- =============================================================================
--  BLOQUE C — CUÁNTO OCUPA UN MODELO
-- =============================================================================
-- La mediana de cajas en stock por modelo, por separado para infantil y
-- adulto. Mediana y no promedio: un modelo estrella con 600 pares arrastraría
-- el promedio y haría casilleros enormes para todos los demás. Acotada entre
-- 20 y 80: menos de 20 llenaría el rack de códigos para modelos casi agotados,
-- más de 80 es un casillero donde el operario ya no encuentra la talla.
create or replace function public.fn_cajas_por_modelo(p_infantil boolean)
returns integer
language sql
stable
set search_path = public
as $fn$
  with por_modelo as (
    select pr.id, sum(inv.quantity) as cajas
      from public.products        pr
      join public.inventory_items it  on it.product_id = pr.id
      join public.inventory       inv on inv.item_id   = it.id
     where (pr.audience = 'NINO') = p_infantil
     group by pr.id
    having sum(inv.quantity) > 0
  )
  select coalesce(
           least(80, greatest(20, round(percentile_cont(0.5) within group (order by cajas))::integer)),
           40)
    from por_modelo;
$fn$;

comment on function public.fn_cajas_por_modelo is
  'Mediana de cajas en stock por modelo (infantil o adulto), acotada entre 20 y 80. Es el tamaño objetivo de un casillero: un casillero guarda un modelo.';


-- =============================================================================
--  BLOQUE D — CUÁNTOS CASILLEROS LE TOCAN A UN NIVEL
-- =============================================================================
-- Se prueba cada cantidad posible y gana la que deja cada casillero más cerca
-- de lo que ocupa un modelo. A igual distancia, la que desperdicia menos frente
-- (menos centímetros donde no entra una caja entera) y, después, la de más
-- casilleros: en el mismo estante caben más modelos distintos.
create or replace function public.fn_casilleros_para(
  p_frente_m numeric,
  p_fondo_m  numeric,
  p_nivel    integer
)
returns integer
language plpgsql
stable
set search_path = public
as $fn$
declare
  v_caja     numeric[] := public.fn_medidas_caja(p_nivel);
  v_objetivo integer   := public.fn_cajas_por_modelo(p_nivel <= public.fn_niveles_infantiles());
  v_mejor    integer   := 1;
  v_mejor_d  numeric;
  v_mejor_s  numeric;
  v_w        numeric;
  v_cap      integer;
  v_d        numeric;
  v_s        numeric;
  n          integer;
begin
  for n in 1..greatest(1, least(200, floor(p_frente_m / v_caja[2])::integer)) loop
    v_w   := p_frente_m / n;
    v_cap := public.fn_cajas_en_slot(v_w, p_fondo_m, p_nivel);
    exit when v_cap = 0;   -- más angosto que la caja: de acá en adelante todo es 0

    v_d := abs(v_cap - v_objetivo);
    v_s := least(v_w - v_caja[1] * floor(v_w / v_caja[1]),
                 v_w - v_caja[2] * floor(v_w / v_caja[2]));

    if v_mejor_d is null or v_d < v_mejor_d or (v_d = v_mejor_d and v_s <= v_mejor_s) then
      v_mejor   := n;
      v_mejor_d := v_d;
      v_mejor_s := v_s;
    end if;
  end loop;

  return v_mejor;
end;
$fn$;


-- =============================================================================
--  BLOQUE E — AJUSTAR LOS CASILLEROS DE UN RACK A ESA MEDIDA
-- =============================================================================
create or replace function public.fn_posicion_con_historia(p_position_id uuid)
returns boolean
language sql
stable
set search_path = public
as $fn$
  select exists (select 1 from public.position_assignments  where position_id = p_position_id)
      or exists (select 1 from public.inventory_movements   where position_id = p_position_id)
      or exists (select 1 from public.stock_ledger          where position_id = p_position_id)
      or exists (select 1 from public.inventory_count_lines where position_id = p_position_id);
$fn$;

-- Nunca renumera: los códigos emitidos están en el kardex. Agrega los que
-- faltan con el primer código libre y quita los que sobran desde el final del
-- nivel, pero solo si están vacíos de presente y de pasado; los que tienen
-- historia se quedan y se informan como "trabados".
create or replace function public.fn_ajustar_casilleros(p_rack_id uuid, p_niveles integer)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_rack     public.racks;
  v_letra    text;
  v_num      text;
  v_donde    text;
  v_frente   numeric;
  v_fondo    numeric;
  v_min      integer := public.fn_niveles_infantiles() + 1;
  v_nivel    integer;
  v_quiero   integer;
  v_hay      integer;
  v_trabados integer;
  v_idx      integer;
  v_pos      record;
  v_detalle  jsonb := '[]'::jsonb;
begin
  if p_niveles not between v_min and 8 then
    raise exception 'Un rack tiene entre % y 8 niveles: los % de abajo son para calzado infantil y hace falta al menos uno encima para el de adulto. Se pidieron %.',
      v_min, public.fn_niveles_infantiles(), p_niveles;
  end if;

  select * into v_rack from public.racks where id = p_rack_id;
  if v_rack.id is null then
    raise exception 'El rack no existe.';
  end if;

  select right(w.code, 1), w.code || ' · ' || v_rack.code
    into v_letra, v_donde
    from public.warehouses w where w.id = v_rack.warehouse_id;
  v_num    := right(v_rack.code, 2);
  v_frente := greatest(v_rack.grid_ancho, v_rack.grid_alto);
  v_fondo  := least(v_rack.grid_ancho, v_rack.grid_alto);

  -- Niveles que se van: solo si están vacíos de presente y de pasado.
  for v_pos in
    select p.id, p.code from public.positions p
     where p.rack_id = p_rack_id and p.level > p_niveles
  loop
    if public.fn_posicion_con_historia(v_pos.id) then
      raise exception 'No se puede bajar % a % niveles: la posición % tiene historial de movimientos.',
        v_donde, p_niveles, v_pos.code;
    end if;
    delete from public.positions where id = v_pos.id;
  end loop;

  for v_nivel in 1..p_niveles loop
    v_quiero   := public.fn_casilleros_para(v_frente, v_fondo, v_nivel);
    v_trabados := 0;
    select count(*) into v_hay from public.positions where rack_id = p_rack_id and level = v_nivel;

    if v_hay > v_quiero then
      for v_pos in
        select p.id from public.positions p
         where p.rack_id = p_rack_id and p.level = v_nivel
         order by p.slot desc nulls last, p.code desc
      loop
        exit when v_hay <= v_quiero;
        if public.fn_posicion_con_historia(v_pos.id) then
          v_trabados := v_trabados + 1;
        else
          delete from public.positions where id = v_pos.id;
          v_hay := v_hay - 1;
        end if;
      end loop;
    end if;

    while v_hay < v_quiero loop
      select min(g.n) into v_idx
        from generate_series(1, 999) as g(n)
       where not exists (
         select 1 from public.positions
          where rack_id = p_rack_id
            and code = v_letra || '-' || v_num || '-' || lpad(g.n::text, greatest(2, length(g.n::text)), '0')
       );
      if v_idx is null then
        raise exception 'El rack % ya usó los 999 códigos de posición disponibles.', v_donde;
      end if;

      insert into public.positions (rack_id, code, capacity_units, level, slot)
      values (p_rack_id,
              v_letra || '-' || v_num || '-' || lpad(v_idx::text, greatest(2, length(v_idx::text)), '0'),
              0, v_nivel, v_hay + 1);
      v_hay := v_hay + 1;
    end loop;

    v_detalle := v_detalle || jsonb_build_object(
      'nivel', v_nivel, 'casilleros', v_hay, 'sugeridos', v_quiero, 'trabados', v_trabados);
  end loop;

  update public.racks set niveles = p_niveles, updated_at = now() where id = p_rack_id;
  perform public.fn_recalcular_capacidades(p_rack_id);
  return v_detalle;
end;
$fn$;

-- Es security definer y no pide rol: se llama solo desde configurar_rack y
-- crear_rack, que sí lo piden. Sin este revoke, cualquiera la invocaría por
-- /rpc/ y reconfiguraría racks ajenos.
revoke execute on function public.fn_ajustar_casilleros(uuid, integer) from public, anon, authenticated;


-- =============================================================================
--  BLOQUE F — CONFIGURAR, CREAR Y ESTIMAR, EN MODO AUTOMÁTICO
-- =============================================================================
-- p_slots_por_nivel = NULL significa "a medida de un modelo". Con un número se
-- mantiene el modo manual de siempre. Las firmas no cambian.
create or replace function public.configurar_rack(
  p_rack_id         uuid,
  p_niveles         integer,
  p_slots_por_nivel integer
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_rack     public.racks;
  v_total    integer;
  v_cajas    integer;
  v_detalle  jsonb;
  v_trabados integer := 0;
  v_texto    text;
begin
  perform public.fn_exigir_rol('SUPERVISOR', 'JEFE');

  if p_slots_por_nivel is null then
    v_detalle := public.fn_ajustar_casilleros(p_rack_id, p_niveles);
    select coalesce(sum((e->>'trabados')::integer), 0),
           string_agg('n' || (e->>'nivel') || ': ' || (e->>'casilleros'), ' · ')
      into v_trabados, v_texto
      from jsonb_array_elements(v_detalle) e;
  else
    perform public.fn_configurar_posiciones(p_rack_id, p_niveles, p_slots_por_nivel);
  end if;

  select * into v_rack from public.racks where id = p_rack_id;
  select count(*), coalesce(sum(capacity_units), 0) into v_total, v_cajas
    from public.positions where rack_id = p_rack_id;

  return jsonb_build_object(
    'estado',     'OK',
    'posiciones', v_total,
    'cajas',      v_cajas,
    'por_nivel',  v_detalle,
    'mensaje',    v_rack.code || ': ' || p_niveles || ' niveles, ' || v_total || ' casilleros' ||
                  coalesce(' (' || v_texto || ')', '') || ', capacidad ' || v_cajas || ' cajas.' ||
                  case when v_trabados > 0
                       then ' ' || v_trabados || ' casillero(s) que sobraban no se quitaron porque tienen historial.'
                       else '' end
  );
end;
$fn$;

grant execute on function public.configurar_rack(uuid, integer, integer) to authenticated;

create or replace function public.crear_rack(
  p_warehouse_code  text,
  p_code            text,
  p_grid_x          integer,
  p_grid_y          integer,
  p_grid_ancho      integer,
  p_grid_alto       integer,
  p_niveles         integer default 3,
  p_slots_por_nivel integer default 7
)
returns public.racks
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_wh   public.warehouses;
  v_rack public.racks;
  v_min  integer := public.fn_niveles_infantiles() + 1;
begin
  perform public.fn_exigir_rol('SUPERVISOR', 'JEFE');

  if p_code !~ '^RACK-[0-9]{2}$' then
    raise exception 'El código del rack debe tener el formato RACK-NN (por ejemplo RACK-09). Recibido: %.', p_code;
  end if;

  if p_niveles not between v_min and 8 then
    raise exception 'Un rack tiene entre % y 8 niveles: los % de abajo son para calzado infantil y hace falta al menos uno encima para el de adulto. Se pidieron %.',
      v_min, public.fn_niveles_infantiles(), p_niveles;
  end if;

  select * into v_wh from public.warehouses where code = p_warehouse_code;
  if v_wh.id is null then
    raise exception 'No existe el almacén %.', p_warehouse_code;
  end if;

  -- El trigger trg_racks_geometria valida acá forma, plano, solapes y puerta.
  insert into public.racks (warehouse_id, code, grid_x, grid_y, grid_ancho, grid_alto, niveles)
  values (v_wh.id, p_code, p_grid_x, p_grid_y, p_grid_ancho, p_grid_alto, p_niveles)
  returning * into v_rack;

  if p_slots_por_nivel is null then
    perform public.fn_ajustar_casilleros(v_rack.id, p_niveles);
  else
    perform public.fn_configurar_posiciones(v_rack.id, p_niveles, p_slots_por_nivel);
  end if;

  select * into v_rack from public.racks where id = v_rack.id;
  return v_rack;
end;
$fn$;

grant execute on function public.crear_rack(text, text, integer, integer, integer, integer, integer, integer) to authenticated;

-- Lo que el editor muestra ANTES de crear o reconfigurar: con cuántos
-- casilleros quedaría cada nivel, cuánto mide cada uno y cuánto guarda. Pasa
-- de sql immutable a plpgsql stable porque ahora lee el stock real.
create or replace function public.estimar_capacidad_rack(
  p_grid_ancho      integer,
  p_grid_alto       integer,
  p_niveles         integer,
  p_slots_por_nivel integer
)
returns jsonb
language plpgsql
stable
set search_path = public
as $fn$
declare
  v_frente numeric := greatest(p_grid_ancho, p_grid_alto);
  v_fondo  numeric := least(p_grid_ancho, p_grid_alto);
  v_n      integer;
  v_cap    integer;
  v_pos    integer := 0;
  v_cajas  integer := 0;
  v_por    jsonb   := '[]'::jsonb;
  v_nivel  integer;
begin
  for v_nivel in 1..greatest(p_niveles, 1) loop
    v_n   := coalesce(nullif(p_slots_por_nivel, 0), public.fn_casilleros_para(v_frente, v_fondo, v_nivel));
    v_cap := public.fn_cajas_en_slot(v_frente / v_n, v_fondo, v_nivel);
    v_pos   := v_pos + v_n;
    v_cajas := v_cajas + v_cap * v_n;
    v_por   := v_por || jsonb_build_object(
      'nivel',               v_nivel,
      'casilleros',          v_n,
      'ancho_cm',            round(v_frente / v_n * 100),
      'cajas_por_casillero', v_cap,
      'cajas',               v_cap * v_n);
  end loop;

  return jsonb_build_object(
    'frente', v_frente, 'fondo', v_fondo,
    'posiciones', v_pos, 'cajas', v_cajas, 'por_nivel', v_por);
end;
$fn$;

grant execute on function public.estimar_capacidad_rack(integer, integer, integer, integer) to authenticated;


-- =============================================================================
--  BLOQUE G — LA REVISIÓN: TODO LO QUE ESTÁ FUERA DE LUGAR
-- =============================================================================
create or replace view public.v_revision_ubicaciones as
with en_estantes as (
  select pa.item_id, r.warehouse_id, sum(pa.quantity) as ubicado
    from public.position_assignments pa
    join public.positions pos on pos.id = pa.position_id
    join public.racks     r   on r.id   = pos.rack_id
   where pa.status in ('OCUPADA', 'EN_PICKING')
   group by pa.item_id, r.warehouse_id
)
-- 1. Calzado en un nivel que no es el de su público.
select 'NIVEL'::text                 as tipo,
       rp.almacen_code,
       rp.rack,
       rp.posicion                   as casillero,
       rp.sku,
       rp.producto,
       rp.unidades                   as cantidad,
       format('%s en el nivel %s: va al nivel %s',
              case when rp.publico = 'NINO' then 'Infantil' else 'Adulto' end,
              rp.nivel, rp.nivel_sugerido) as detalle,
       rp.assignment_id,
       rp.position_id,
       null::uuid                    as inventory_id,
       rp.item_id,
       null::uuid                    as warehouse_id
  from public.v_reubicaciones_pendientes rp
union all
-- 2. Casillero con más cajas de las que caben.
select 'SOBRECARGA', w.code, r.code, pos.code, null, null,
       (sum(pa.quantity) - pos.capacity_units)::integer,
       format('Hay %s cajas donde caben %s', sum(pa.quantity), pos.capacity_units),
       null, pos.id, null, null, w.id
  from public.positions pos
  join public.racks      r on r.id = pos.rack_id
  join public.warehouses w on w.id = r.warehouse_id
  join public.position_assignments pa
    on pa.position_id = pos.id and pa.status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
 group by w.code, w.id, r.code, pos.code, pos.id, pos.capacity_units
having sum(pa.quantity) > pos.capacity_units
union all
-- 3. Stock que no está en ningún estante.
select 'RECEPCION', w.code, null, null, it.sku, pr.name,
       (inv.quantity - coalesce(e.ubicado, 0))::integer,
       format('%s pares en stock sin ubicar', inv.quantity - coalesce(e.ubicado, 0)),
       null, null, inv.id, it.id, w.id
  from public.inventory inv
  join public.inventory_items it on it.id = inv.item_id
  join public.products        pr on pr.id = it.product_id
  join public.warehouses      w  on w.id  = inv.warehouse_id
  left join en_estantes e on e.item_id = inv.item_id and e.warehouse_id = inv.warehouse_id
 where inv.quantity > coalesce(e.ubicado, 0)
union all
-- 4. Más pares en los estantes que en el stock (o estantes en un almacén donde
--    el artículo ni siquiera tiene stock registrado).
select 'FANTASMA', w.code, null, null, it.sku, pr.name,
       (e.ubicado - coalesce(inv.quantity, 0))::integer,
       format('%s en estantes y %s en stock', e.ubicado, coalesce(inv.quantity, 0)),
       null, null, inv.id, it.id, w.id
  from en_estantes e
  join public.inventory_items it on it.id = e.item_id
  join public.products        pr on pr.id = it.product_id
  join public.warehouses      w  on w.id  = e.warehouse_id
  left join public.inventory inv on inv.item_id = e.item_id and inv.warehouse_id = e.warehouse_id
 where e.ubicado > coalesce(inv.quantity, 0);

alter view public.v_revision_ubicaciones set (security_invoker = on);
grant select on public.v_revision_ubicaciones to authenticated;

comment on view public.v_revision_ubicaciones is
  'Todo lo que está fuera de lugar, por tipo: NIVEL (público equivocado), SOBRECARGA (más cajas de las que caben), RECEPCION (stock sin ubicar), FANTASMA (más en estantes que en stock).';


-- =============================================================================
--  BLOQUE H — COLOCAR CAJAS EN EL ALMACÉN
-- =============================================================================
-- El reparto que usan todas las correcciones. Busca en todo el almacén: primero
-- el rack preferido (donde ya está parado quien mueve la caja), después los
-- casilleros que ya tienen esa talla o ese modelo —para juntar las tallas—, y
-- recién después uno vacío. Si no entra todo, se niega entero: la función que
-- la llama es una transacción y nada queda a medio mover.
create or replace function public.fn_colocar(
  p_warehouse_id   uuid,
  p_rack_preferido uuid,
  p_item_id        uuid,
  p_cantidad       integer,
  p_status         text,
  p_excluir        uuid,
  p_nota           text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_tope     integer := public.fn_niveles_infantiles();
  v_publico  text;
  v_modelo   uuid;
  v_sku      text;
  v_almacen  text;
  v_destino  record;
  v_restante integer := p_cantidad;
  v_cuanto   integer;
  v_usadas   integer := 0;
  v_donde    text := '';
begin
  select pr.audience, pr.id, it.sku into v_publico, v_modelo, v_sku
    from public.inventory_items it
    join public.products pr on pr.id = it.product_id
   where it.id = p_item_id;
  select code into v_almacen from public.warehouses where id = p_warehouse_id;

  for v_destino in
    select p.id, p.code, r.code as rack_code,
           p.capacity_units - coalesce(oc.ocupado, 0)     as libre,
           coalesce(oc.misma_talla, false)                as misma_talla,
           oc.ocupado is not null                         as mismo_modelo,
           coalesce(p.rack_id = p_rack_preferido, false)  as preferido
      from public.positions p
      join public.racks r on r.id = p.rack_id
      left join lateral (
        select sum(a.quantity)                    as ocupado,
               bool_or(a.item_id = p_item_id)     as misma_talla,
               bool_or(it.product_id <> v_modelo) as otro_modelo
          from public.position_assignments a
          join public.inventory_items it on it.id = a.item_id
         where a.position_id = p.id
           and a.status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
      ) oc on true
     where r.warehouse_id = p_warehouse_id
       and (p_excluir is null or p.id <> p_excluir)
       and p.is_active
       and case when v_publico = 'NINO'   then p.level <= v_tope
                when v_publico = 'ADULTO' then p.level >  v_tope
                else true end
       and not coalesce(oc.otro_modelo, false)
       and p.capacity_units - coalesce(oc.ocupado, 0) > 0
     order by preferido desc, misma_talla desc, mismo_modelo desc, libre desc, r.code, p.level, p.code
  loop
    exit when v_restante <= 0;

    v_cuanto := least(v_restante, v_destino.libre);

    update public.position_assignments
       set quantity = quantity + v_cuanto, updated_at = now()
     where position_id = v_destino.id
       and item_id     = p_item_id
       and status in ('RESERVADA', 'OCUPADA', 'EN_PICKING');
    if not found then
      insert into public.position_assignments (position_id, item_id, quantity, status, assigned_by, notes)
      values (v_destino.id, p_item_id, v_cuanto, coalesce(p_status, 'OCUPADA'), public.actor_actual(), p_nota);
    end if;

    v_restante := v_restante - v_cuanto;
    v_usadas   := v_usadas + 1;
    v_donde    := v_donde || case when v_donde = '' then '' else ', ' end
                          || v_destino.rack_code || ' ' || v_destino.code || ' (' || v_cuanto || ')';
  end loop;

  if v_restante > 0 then
    raise exception 'En % no queda sitio para % de las % cajas de %: los casilleros donde podría ir están llenos o guardan otro modelo. Amplía un rack o crea otro.',
      v_almacen, v_restante, p_cantidad, v_sku;
  end if;

  return jsonb_build_object('casilleros', v_usadas, 'donde', v_donde);
end;
$fn$;

revoke execute on function public.fn_colocar(uuid, uuid, uuid, integer, text, uuid, text) from public, anon, authenticated;


-- =============================================================================
--  BLOQUE I — UNA CORRECCIÓN POR TIPO DE PROBLEMA
-- =============================================================================
-- I.1 Nivel equivocado: reubicar. Ahora puede derramar a otro rack del mismo
-- almacén si en el suyo no hay sitio, en vez de negarse.
create or replace function public.reubicar_asignacion(
  p_assignment_id uuid,
  p_position_id   uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_asg    public.position_assignments;
  v_origen public.positions;
  v_wh     uuid;
  v_rack   text;
  v_res    jsonb;
begin
  perform public.fn_exigir_rol('OPERARIO', 'SUPERVISOR', 'JEFE');

  select * into v_asg from public.position_assignments where id = p_assignment_id;
  if v_asg.id is null then
    raise exception 'Esa ubicación ya no existe.';
  end if;
  if v_asg.status = 'LIBERADA' then
    raise exception 'Esa ubicación ya fue liberada: no hay nada que mover.';
  end if;

  select * into v_origen from public.positions where id = v_asg.position_id;
  select r.warehouse_id, w.code || ' · ' || r.code into v_wh, v_rack
    from public.racks r
    join public.warehouses w on w.id = r.warehouse_id
   where r.id = v_origen.rack_id;

  update public.position_assignments
     set status = 'LIBERADA', released_at = now(), updated_at = now()
   where id = p_assignment_id;

  if p_position_id is not null then
    update public.position_assignments
       set quantity = quantity + v_asg.quantity, updated_at = now()
     where position_id = p_position_id
       and item_id     = v_asg.item_id
       and status in ('RESERVADA', 'OCUPADA', 'EN_PICKING');
    if not found then
      insert into public.position_assignments (position_id, item_id, quantity, status, assigned_by, notes)
      values (p_position_id, v_asg.item_id, v_asg.quantity, v_asg.status, public.actor_actual(),
              'Reubicada desde ' || v_origen.code);
    end if;
    return jsonb_build_object('estado', 'REUBICADA', 'mensaje', 'Movida de ' || v_origen.code || '.');
  end if;

  v_res := public.fn_colocar(v_wh, v_origen.rack_id, v_asg.item_id, v_asg.quantity, v_asg.status,
                             v_origen.id, 'Reubicada desde ' || v_origen.code || ' (nivel ' || v_origen.level || ')');

  return jsonb_build_object(
    'estado',     'REUBICADA',
    'casilleros', v_res->'casilleros',
    'mensaje',    v_asg.quantity || ' cajas de ' || v_rack || ' ' || v_origen.code || ' a ' || (v_res->>'donde') || '.'
  );
end;
$fn$;

grant execute on function public.reubicar_asignacion(uuid, uuid) to authenticated;

-- I.2 Casillero sobrecargado: sacar el sobrante y repartirlo. Se saca de la
-- talla con más cajas, que es la que más fácil encuentra sitio.
create or replace function public.repartir_sobrecarga(p_position_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_pos    public.positions;
  v_wh     uuid;
  v_hay    integer;
  v_exceso integer;
  v_asg    record;
  v_sacar  integer;
  v_res    jsonb;
  v_donde  text := '';
begin
  perform public.fn_exigir_rol('OPERARIO', 'SUPERVISOR', 'JEFE');

  select * into v_pos from public.positions where id = p_position_id;
  if v_pos.id is null then
    raise exception 'Ese casillero no existe.';
  end if;
  select warehouse_id into v_wh from public.racks where id = v_pos.rack_id;

  select coalesce(sum(quantity), 0) into v_hay
    from public.position_assignments
   where position_id = p_position_id and status in ('RESERVADA', 'OCUPADA', 'EN_PICKING');

  v_exceso := v_hay - v_pos.capacity_units;
  if v_exceso <= 0 then
    return jsonb_build_object('estado', 'OK', 'mensaje', v_pos.code || ' ya no está sobrecargado.');
  end if;

  for v_asg in
    select * from public.position_assignments
     where position_id = p_position_id and status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
     order by quantity desc
  loop
    exit when v_exceso <= 0;
    v_sacar := least(v_exceso, v_asg.quantity);

    if v_sacar = v_asg.quantity then
      update public.position_assignments
         set quantity = 0, status = 'LIBERADA', released_at = now(), updated_at = now()
       where id = v_asg.id;
    else
      update public.position_assignments
         set quantity = quantity - v_sacar, updated_at = now()
       where id = v_asg.id;
    end if;

    v_res := public.fn_colocar(v_wh, v_pos.rack_id, v_asg.item_id, v_sacar, v_asg.status,
                               p_position_id, 'Sobrante de ' || v_pos.code);
    v_donde  := v_donde || case when v_donde = '' then '' else ', ' end || (v_res->>'donde');
    v_exceso := v_exceso - v_sacar;
  end loop;

  return jsonb_build_object(
    'estado',  'REPARTIDA',
    'mensaje', (v_hay - v_pos.capacity_units) || ' cajas de ' || v_pos.code || ' repartidas en ' || v_donde || '.'
  );
end;
$fn$;

grant execute on function public.repartir_sobrecarga(uuid) to authenticated;

-- I.3 Stock en recepción: ubicarlo, juntando las tallas de cada modelo.
create or replace function public.ubicar_recepcion(p_inventory_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_inv     public.inventory;
  v_ubicado integer;
  v_falta   integer;
  v_res     jsonb;
begin
  perform public.fn_exigir_rol('OPERARIO', 'SUPERVISOR', 'JEFE');

  select * into v_inv from public.inventory where id = p_inventory_id;
  if v_inv.id is null then
    raise exception 'Ese registro de stock no existe.';
  end if;

  select coalesce(sum(pa.quantity), 0) into v_ubicado
    from public.position_assignments pa
    join public.positions pos on pos.id = pa.position_id
    join public.racks     r   on r.id   = pos.rack_id
   where pa.item_id = v_inv.item_id
     and r.warehouse_id = v_inv.warehouse_id
     and pa.status in ('OCUPADA', 'EN_PICKING');

  v_falta := v_inv.quantity - v_ubicado;
  if v_falta <= 0 then
    return jsonb_build_object('estado', 'OK', 'mensaje', 'No queda nada en recepción de este artículo.');
  end if;

  v_res := public.fn_colocar(v_inv.warehouse_id, null, v_inv.item_id, v_falta, 'OCUPADA',
                             null, 'Ubicada desde recepción');

  return jsonb_build_object(
    'estado',  'UBICADA',
    'mensaje', v_falta || ' pares ubicados en ' || (v_res->>'donde') || '.'
  );
end;
$fn$;

grant execute on function public.ubicar_recepcion(uuid) to authenticated;

-- I.4 Cajas fantasma: el usuario elige en qué confiar.
--   'STOCK'    -> los estantes mienten: se libera lo que sobra, de los
--                 casilleros con menos cajas primero (se limpian enteros).
--   'ESTANTES' -> el stock miente: se crea un AJUSTE por la diferencia, que
--                 sigue el flujo normal de aprobación. No se toca el stock a
--                 mano: el kardex tiene que decir por qué cambió.
create or replace function public.resolver_fantasma(
  p_item_id      uuid,
  p_warehouse_id uuid,
  p_confiar      text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_inv     public.inventory;
  v_ubicado integer;
  v_sobra   integer;
  v_resta   integer;
  v_sacar   integer;
  v_a       record;
begin
  perform public.fn_exigir_rol('SUPERVISOR', 'JEFE');

  select * into v_inv from public.inventory
   where item_id = p_item_id and warehouse_id = p_warehouse_id;

  select coalesce(sum(pa.quantity), 0) into v_ubicado
    from public.position_assignments pa
    join public.positions pos on pos.id = pa.position_id
    join public.racks     r   on r.id   = pos.rack_id
   where pa.item_id = p_item_id
     and r.warehouse_id = p_warehouse_id
     and pa.status in ('OCUPADA', 'EN_PICKING');

  v_sobra := v_ubicado - coalesce(v_inv.quantity, 0);
  if v_sobra <= 0 then
    return jsonb_build_object('estado', 'OK', 'mensaje', 'Estantes y stock ya coinciden.');
  end if;

  if p_confiar = 'STOCK' then
    v_resta := v_sobra;
    for v_a in
      select pa.* from public.position_assignments pa
        join public.positions pos on pos.id = pa.position_id
        join public.racks     r   on r.id   = pos.rack_id
       where pa.item_id = p_item_id
         and r.warehouse_id = p_warehouse_id
         and pa.status in ('OCUPADA', 'EN_PICKING')
       order by pa.quantity asc
    loop
      exit when v_resta <= 0;
      v_sacar := least(v_resta, v_a.quantity);
      if v_sacar = v_a.quantity then
        update public.position_assignments
           set quantity = 0, status = 'LIBERADA', released_at = now(), updated_at = now()
         where id = v_a.id;
      else
        update public.position_assignments
           set quantity = quantity - v_sacar, updated_at = now()
         where id = v_a.id;
      end if;
      v_resta := v_resta - v_sacar;
    end loop;

    return jsonb_build_object('estado', 'LIBERADA',
      'mensaje', v_sobra || ' pares que no existían liberados de los estantes.');
  end if;

  if p_confiar = 'ESTANTES' then
    if v_inv.id is null then
      raise exception 'Este artículo no tiene stock registrado en ese almacén, así que no hay nada que ajustar: confía en el stock y libera lo que sobra.';
    end if;

    insert into public.inventory_movements
      (item_id, inventory_id, movement_type, direction, quantity, expected_quantity, reason, status, created_by)
    values
      (p_item_id, v_inv.id, 'AJUSTE', 1, v_sobra, v_sobra,
       'Conteo: los estantes tienen ' || v_sobra || ' pares más que el stock', 'PENDIENTE', public.actor_actual());

    return jsonb_build_object('estado', 'AJUSTE_PENDIENTE',
      'mensaje', 'Ajuste de +' || v_sobra || ' creado. Cuando se apruebe y ejecute, el stock coincidirá con los estantes.');
  end if;

  raise exception 'Hay que elegir en qué confiar: STOCK o ESTANTES.';
end;
$fn$;

grant execute on function public.resolver_fantasma(uuid, uuid, text) to authenticated;

-- I.5 "Arreglar todos" de un tipo. Captura el error de cada uno y lo DEVUELVE:
-- que un artículo no quepa no debe impedir arreglar los demás, pero tampoco
-- puede quedar en silencio.
create or replace function public.resolver_revision(p_tipo text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  r        record;
  v_ok     integer := 0;
  v_fallas jsonb   := '[]'::jsonb;
begin
  perform public.fn_exigir_rol('OPERARIO', 'SUPERVISOR', 'JEFE');

  if p_tipo not in ('NIVEL', 'SOBRECARGA', 'RECEPCION') then
    raise exception 'Las cajas fantasma se resuelven una por una: el sistema no puede saber si miente el stock o el estante.';
  end if;

  for r in select * from public.v_revision_ubicaciones where tipo = p_tipo loop
    begin
      if p_tipo = 'NIVEL' then
        perform public.reubicar_asignacion(r.assignment_id);
      elsif p_tipo = 'SOBRECARGA' then
        perform public.repartir_sobrecarga(r.position_id);
      else
        perform public.ubicar_recepcion(r.inventory_id);
      end if;
      v_ok := v_ok + 1;
    exception when others then
      v_fallas := v_fallas || jsonb_build_object(
        'que', coalesce(r.sku, r.casillero), 'donde', r.almacen_code, 'motivo', sqlerrm);
    end;
  end loop;

  return jsonb_build_object('resueltos', v_ok, 'fallidos', jsonb_array_length(v_fallas), 'detalle', v_fallas);
end;
$fn$;

grant execute on function public.resolver_revision(text) to authenticated;


-- =============================================================================
--  VERIFICACIÓN
-- =============================================================================
-- 1. Cuánto ocupa un modelo hoy: el tamaño objetivo de un casillero.
select 'infantil' as publico, public.fn_cajas_por_modelo(true)  as cajas_por_modelo
union all
select 'adulto',              public.fn_cajas_por_modelo(false);

-- 2. Casilleros por nivel: los de hoy y los que propone la regla. Se aplican
--    rack por rack desde el editor ("Aplicar niveles y casilleros").
select w.code as almacen, r.code as rack, n.nivel,
       (select count(*) from public.positions p where p.rack_id = r.id and p.level = n.nivel) as hoy,
       public.fn_casilleros_para(greatest(r.grid_ancho, r.grid_alto), least(r.grid_ancho, r.grid_alto), n.nivel) as sugeridos
  from public.racks r
  join public.warehouses w on w.id = r.warehouse_id
  cross join lateral generate_series(1, r.niveles) as n(nivel)
 order by 1, 2, 3;

-- 3. Lo que hay para revisar, por tipo.
select tipo, count(*) as pendientes
  from public.v_revision_ubicaciones
 group by tipo
 order by tipo;


-- =============================================================================
-- =============================================================================
--  MIGRACIÓN 22 — LA ESTIMACIÓN DICE CÓMO LLEGÓ A SU NÚMERO
--
--  Misma regla para todos los niveles, datos distintos: la estimación devuelve
--  qué caja y qué objetivo usó cada nivel para que la pantalla lo diga.
-- =============================================================================
-- =============================================================================

create or replace function public.estimar_capacidad_rack(
  p_grid_ancho      integer,
  p_grid_alto       integer,
  p_niveles         integer,
  p_slots_por_nivel integer
)
returns jsonb
language plpgsql
stable
set search_path = public
as $fn$
declare
  v_frente   numeric := greatest(p_grid_ancho, p_grid_alto);
  v_fondo    numeric := least(p_grid_ancho, p_grid_alto);
  v_n        integer;
  v_cap      integer;
  v_caja     numeric[];
  v_infantil boolean;
  v_pos      integer := 0;
  v_cajas    integer := 0;
  v_por      jsonb   := '[]'::jsonb;
  v_nivel    integer;
begin
  for v_nivel in 1..greatest(p_niveles, 1) loop
    v_infantil := v_nivel <= public.fn_niveles_infantiles();
    v_caja     := public.fn_medidas_caja(v_nivel);
    v_n        := coalesce(nullif(p_slots_por_nivel, 0), public.fn_casilleros_para(v_frente, v_fondo, v_nivel));
    v_cap      := public.fn_cajas_en_slot(v_frente / v_n, v_fondo, v_nivel);
    v_pos      := v_pos + v_n;
    v_cajas    := v_cajas + v_cap * v_n;
    v_por      := v_por || jsonb_build_object(
      'nivel',               v_nivel,
      'publico',             case when v_infantil then 'niño' else 'adulto' end,
      'caja_cm',             round(v_caja[1] * 100) || '×' || round(v_caja[2] * 100) || '×' || round(v_caja[3] * 100),
      'objetivo',            public.fn_cajas_por_modelo(v_infantil),
      'casilleros',          v_n,
      'ancho_cm',            round(v_frente / v_n * 100),
      'cajas_por_casillero', v_cap,
      'cajas',               v_cap * v_n);
  end loop;

  return jsonb_build_object(
    'frente', v_frente, 'fondo', v_fondo,
    'posiciones', v_pos, 'cajas', v_cajas, 'por_nivel', v_por);
end;
$fn$;

grant execute on function public.estimar_capacidad_rack(integer, integer, integer, integer) to authenticated;


-- =============================================================================
--  VERIFICACIÓN
-- =============================================================================
-- Un rack de 14 x 2 m con 3 niveles: los dos infantiles y el de adulto salen
-- distintos porque usan caja y objetivo distintos.
select n->>'nivel' as nivel, n->>'publico' as publico, n->>'caja_cm' as caja_cm,
       n->>'objetivo' as un_modelo_ocupa, n->>'casilleros' as casilleros,
       n->>'ancho_cm' as ancho_cm, n->>'cajas_por_casillero' as cajas_c_u
  from jsonb_array_elements(public.estimar_capacidad_rack(14, 2, 3, null)->'por_nivel') as n;


-- =============================================================================
-- =============================================================================
--  MIGRACIÓN 23 — TODOS LOS RACKS CON CASILLEROS A MEDIDA
--
--  Aplica la regla de la 21 a todos los racks de una vez y reparte lo que
--  queda sobrecargado. Permite correrlo sin sesión (SQL Editor) y asigna los
--  códigos nuevos sin recorrer 999 posibles por casillero.
-- =============================================================================
-- =============================================================================

-- =============================================================================
--  BLOQUE A — fn_colocar ANOTA AL USUARIO SI LO HAY
-- =============================================================================
-- Idéntica a la de la migración 21 salvo por assigned_by.
create or replace function public.fn_colocar(
  p_warehouse_id   uuid,
  p_rack_preferido uuid,
  p_item_id        uuid,
  p_cantidad       integer,
  p_status         text,
  p_excluir        uuid,
  p_nota           text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_tope     integer := public.fn_niveles_infantiles();
  v_publico  text;
  v_modelo   uuid;
  v_sku      text;
  v_almacen  text;
  v_destino  record;
  v_restante integer := p_cantidad;
  v_cuanto   integer;
  v_usadas   integer := 0;
  v_donde    text := '';
begin
  select pr.audience, pr.id, it.sku into v_publico, v_modelo, v_sku
    from public.inventory_items it
    join public.products pr on pr.id = it.product_id
   where it.id = p_item_id;
  select code into v_almacen from public.warehouses where id = p_warehouse_id;

  for v_destino in
    select p.id, p.code, r.code as rack_code,
           p.capacity_units - coalesce(oc.ocupado, 0)     as libre,
           coalesce(oc.misma_talla, false)                as misma_talla,
           oc.ocupado is not null                         as mismo_modelo,
           coalesce(p.rack_id = p_rack_preferido, false)  as preferido
      from public.positions p
      join public.racks r on r.id = p.rack_id
      left join lateral (
        select sum(a.quantity)                    as ocupado,
               bool_or(a.item_id = p_item_id)     as misma_talla,
               bool_or(it.product_id <> v_modelo) as otro_modelo
          from public.position_assignments a
          join public.inventory_items it on it.id = a.item_id
         where a.position_id = p.id
           and a.status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
      ) oc on true
     where r.warehouse_id = p_warehouse_id
       and (p_excluir is null or p.id <> p_excluir)
       and p.is_active
       and case when v_publico = 'NINO'   then p.level <= v_tope
                when v_publico = 'ADULTO' then p.level >  v_tope
                else true end
       and not coalesce(oc.otro_modelo, false)
       and p.capacity_units - coalesce(oc.ocupado, 0) > 0
     order by preferido desc, misma_talla desc, mismo_modelo desc, libre desc, r.code, p.level, p.code
  loop
    exit when v_restante <= 0;

    v_cuanto := least(v_restante, v_destino.libre);

    update public.position_assignments
       set quantity = quantity + v_cuanto, updated_at = now()
     where position_id = v_destino.id
       and item_id     = p_item_id
       and status in ('RESERVADA', 'OCUPADA', 'EN_PICKING');
    if not found then
      insert into public.position_assignments (position_id, item_id, quantity, status, assigned_by, notes)
      values (v_destino.id, p_item_id, v_cuanto, coalesce(p_status, 'OCUPADA'),
              public.fn_usuario_actual(), p_nota);
    end if;

    v_restante := v_restante - v_cuanto;
    v_usadas   := v_usadas + 1;
    v_donde    := v_donde || case when v_donde = '' then '' else ', ' end
                          || v_destino.rack_code || ' ' || v_destino.code || ' (' || v_cuanto || ')';
  end loop;

  if v_restante > 0 then
    raise exception 'En % no queda sitio para % de las % cajas de %: los casilleros donde podría ir están llenos o guardan otro modelo. Amplía un rack o crea otro.',
      v_almacen, v_restante, p_cantidad, v_sku;
  end if;

  return jsonb_build_object('casilleros', v_usadas, 'donde', v_donde);
end;
$fn$;

revoke execute on function public.fn_colocar(uuid, uuid, uuid, integer, text, uuid, text) from public, anon, authenticated;


-- =============================================================================
--  BLOQUE B — REPARTIR: LA LÓGICA SIN ROL, LA RPC CON ROL
-- =============================================================================
create or replace function public.fn_repartir_sobrecarga(p_position_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_pos    public.positions;
  v_wh     uuid;
  v_hay    integer;
  v_exceso integer;
  v_asg    record;
  v_sacar  integer;
  v_res    jsonb;
  v_donde  text := '';
begin
  select * into v_pos from public.positions where id = p_position_id;
  if v_pos.id is null then
    raise exception 'Ese casillero no existe.';
  end if;
  select warehouse_id into v_wh from public.racks where id = v_pos.rack_id;

  select coalesce(sum(quantity), 0) into v_hay
    from public.position_assignments
   where position_id = p_position_id and status in ('RESERVADA', 'OCUPADA', 'EN_PICKING');

  v_exceso := v_hay - v_pos.capacity_units;
  if v_exceso <= 0 then
    return jsonb_build_object('estado', 'OK', 'mensaje', v_pos.code || ' ya no está sobrecargado.');
  end if;

  -- Se saca de la talla con más cajas: es la que más fácil encuentra sitio.
  for v_asg in
    select * from public.position_assignments
     where position_id = p_position_id and status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
     order by quantity desc
  loop
    exit when v_exceso <= 0;
    v_sacar := least(v_exceso, v_asg.quantity);

    if v_sacar = v_asg.quantity then
      update public.position_assignments
         set quantity = 0, status = 'LIBERADA', released_at = now(), updated_at = now()
       where id = v_asg.id;
    else
      update public.position_assignments
         set quantity = quantity - v_sacar, updated_at = now()
       where id = v_asg.id;
    end if;

    v_res := public.fn_colocar(v_wh, v_pos.rack_id, v_asg.item_id, v_sacar, v_asg.status,
                               p_position_id, 'Sobrante de ' || v_pos.code);
    v_donde  := v_donde || case when v_donde = '' then '' else ', ' end || (v_res->>'donde');
    v_exceso := v_exceso - v_sacar;
  end loop;

  return jsonb_build_object(
    'estado',  'REPARTIDA',
    'mensaje', (v_hay - v_pos.capacity_units) || ' cajas de ' || v_pos.code || ' repartidas en ' || v_donde || '.'
  );
end;
$fn$;

revoke execute on function public.fn_repartir_sobrecarga(uuid) from public, anon, authenticated;

create or replace function public.repartir_sobrecarga(p_position_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
begin
  perform public.fn_exigir_rol('OPERARIO', 'SUPERVISOR', 'JEFE');
  return public.fn_repartir_sobrecarga(p_position_id);
end;
$fn$;

grant execute on function public.repartir_sobrecarga(uuid) to authenticated;


-- =============================================================================
--  BLOQUE C — AJUSTAR UN RACK SIN RECORRER 999 CÓDIGOS POR CASILLERO
-- =============================================================================
-- Igual que en la migración 21 salvo por cómo se elige el código nuevo: los
-- números ya usados se cargan una vez y se avanza sobre ellos. Sigue sin
-- renumerar nada; los códigos que se liberan en esta misma pasada no se
-- reusan hasta la próxima, lo cual no molesta a nadie.
create or replace function public.fn_ajustar_casilleros(p_rack_id uuid, p_niveles integer)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_rack     public.racks;
  v_letra    text;
  v_num      text;
  v_donde    text;
  v_frente   numeric;
  v_fondo    numeric;
  v_min      integer := public.fn_niveles_infantiles() + 1;
  v_nivel    integer;
  v_quiero   integer;
  v_hay      integer;
  v_trabados integer;
  v_idx      integer := 0;
  v_usados   integer[];
  v_pos      record;
  v_detalle  jsonb := '[]'::jsonb;
begin
  if p_niveles not between v_min and 8 then
    raise exception 'Un rack tiene entre % y 8 niveles: los % de abajo son para calzado infantil y hace falta al menos uno encima para el de adulto. Se pidieron %.',
      v_min, public.fn_niveles_infantiles(), p_niveles;
  end if;

  select * into v_rack from public.racks where id = p_rack_id;
  if v_rack.id is null then
    raise exception 'El rack no existe.';
  end if;

  select right(w.code, 1), w.code || ' · ' || v_rack.code
    into v_letra, v_donde
    from public.warehouses w where w.id = v_rack.warehouse_id;
  v_num    := right(v_rack.code, 2);
  v_frente := greatest(v_rack.grid_ancho, v_rack.grid_alto);
  v_fondo  := least(v_rack.grid_ancho, v_rack.grid_alto);

  -- Niveles que se van: solo si están vacíos de presente y de pasado.
  for v_pos in
    select p.id, p.code from public.positions p
     where p.rack_id = p_rack_id and p.level > p_niveles
  loop
    if public.fn_posicion_con_historia(v_pos.id) then
      raise exception 'No se puede bajar % a % niveles: la posición % tiene historial de movimientos.',
        v_donde, p_niveles, v_pos.code;
    end if;
    delete from public.positions where id = v_pos.id;
  end loop;

  -- El último tramo del código es el número del casillero dentro del rack.
  select coalesce(array_agg(split_part(code, '-', 3)::integer), '{}')
    into v_usados
    from public.positions where rack_id = p_rack_id;

  for v_nivel in 1..p_niveles loop
    v_quiero   := public.fn_casilleros_para(v_frente, v_fondo, v_nivel);
    v_trabados := 0;
    select count(*) into v_hay from public.positions where rack_id = p_rack_id and level = v_nivel;

    if v_hay > v_quiero then
      for v_pos in
        select p.id from public.positions p
         where p.rack_id = p_rack_id and p.level = v_nivel
         order by p.slot desc nulls last, p.code desc
      loop
        exit when v_hay <= v_quiero;
        if public.fn_posicion_con_historia(v_pos.id) then
          v_trabados := v_trabados + 1;
        else
          delete from public.positions where id = v_pos.id;
          v_hay := v_hay - 1;
        end if;
      end loop;
    end if;

    while v_hay < v_quiero loop
      v_idx := v_idx + 1;
      while v_idx = any(v_usados) loop
        v_idx := v_idx + 1;
      end loop;
      if v_idx > 999 then
        raise exception 'El rack % ya usó los 999 códigos de posición disponibles.', v_donde;
      end if;

      insert into public.positions (rack_id, code, capacity_units, level, slot)
      values (p_rack_id,
              v_letra || '-' || v_num || '-' || lpad(v_idx::text, greatest(2, length(v_idx::text)), '0'),
              0, v_nivel, v_hay + 1);
      v_usados := v_usados || v_idx;
      v_hay    := v_hay + 1;
    end loop;

    v_detalle := v_detalle || jsonb_build_object(
      'nivel', v_nivel, 'casilleros', v_hay, 'sugeridos', v_quiero, 'trabados', v_trabados);
  end loop;

  update public.racks set niveles = p_niveles, updated_at = now() where id = p_rack_id;
  perform public.fn_recalcular_capacidades(p_rack_id);
  return v_detalle;
end;
$fn$;

revoke execute on function public.fn_ajustar_casilleros(uuid, integer) from public, anon, authenticated;


-- =============================================================================
--  BLOQUE D — AJUSTAR TODOS LOS RACKS Y REPARTIR LO QUE SOBRE
-- =============================================================================
-- Interna: se corre desde el SQL Editor. p_warehouse_id NULL = todos los
-- almacenes. Primero ajusta todos los racks y recién después reparte, porque
-- un sobrante puede ir a un casillero que el ajuste de otro rack acaba de crear.
-- Un casillero que no se pueda repartir no frena a los demás: queda en la
-- respuesta con su motivo.
create or replace function public.fn_ajustar_todo(p_warehouse_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  r          record;
  v_det      jsonb;
  v_racks    integer := 0;
  v_trabados integer := 0;
  v_antes    integer;
  v_despues  integer;
  v_reparts  integer := 0;
  v_fallas   jsonb   := '[]'::jsonb;
begin
  select count(*) into v_antes
    from public.positions p join public.racks rk on rk.id = p.rack_id
   where p_warehouse_id is null or rk.warehouse_id = p_warehouse_id;

  for r in
    select id, niveles from public.racks
     where p_warehouse_id is null or warehouse_id = p_warehouse_id
     order by warehouse_id, code
  loop
    v_det := public.fn_ajustar_casilleros(r.id, r.niveles);
    v_trabados := v_trabados + coalesce((select sum((e->>'trabados')::integer) from jsonb_array_elements(v_det) e), 0);
    v_racks := v_racks + 1;
  end loop;

  for r in
    select pos.id, w.code || ' · ' || rk.code || ' ' || pos.code as donde
      from public.positions pos
      join public.racks      rk on rk.id = pos.rack_id
      join public.warehouses w  on w.id  = rk.warehouse_id
      join public.position_assignments pa
        on pa.position_id = pos.id and pa.status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
     where p_warehouse_id is null or rk.warehouse_id = p_warehouse_id
     group by pos.id, w.code, rk.code, pos.code, pos.capacity_units
    having sum(pa.quantity) > pos.capacity_units
  loop
    begin
      perform public.fn_repartir_sobrecarga(r.id);
      v_reparts := v_reparts + 1;
    exception when others then
      v_fallas := v_fallas || jsonb_build_object('casillero', r.donde, 'motivo', sqlerrm);
    end;
  end loop;

  select count(*) into v_despues
    from public.positions p join public.racks rk on rk.id = p.rack_id
   where p_warehouse_id is null or rk.warehouse_id = p_warehouse_id;

  return jsonb_build_object(
    'racks',                   v_racks,
    'casilleros_antes',        v_antes,
    'casilleros_despues',      v_despues,
    'con_historia_sin_quitar', v_trabados,
    'sobrecargas_repartidas',  v_reparts,
    'sin_repartir',            v_fallas);
end;
$fn$;

revoke execute on function public.fn_ajustar_todo(uuid) from public, anon, authenticated;


-- =============================================================================
--  BLOQUE E — APLICARLO A TODOS LOS RACKS
-- =============================================================================
-- El resumen viaja en una variable de sesión y no en una tabla: una tabla,
-- aunque sea temporal, dispara el aviso de "tabla sin RLS" del SQL Editor, y
-- no hace falta ninguna para mostrar una sola fila.
do $bloque$
begin
  perform set_config('ajuste.resumen', public.fn_ajustar_todo(null)::text, false);
end;
$bloque$;


-- =============================================================================
--  RESULTADO (una sola fila: el SQL Editor solo muestra la última consulta)
-- =============================================================================
-- Esperado: niveles_sin_ajustar 0 (o solo los que tienen casilleros con
-- historia que no se pudieron quitar), sobrecargados 0, pendientes_revision 0,
-- y pares_en_stock = pares_en_estantes.
select
  (a.resumen->>'racks')::integer                      as racks_ajustados,
  (a.resumen->>'casilleros_antes')::integer           as casilleros_antes,
  (a.resumen->>'casilleros_despues')::integer         as casilleros_despues,
  (a.resumen->>'sobrecargas_repartidas')::integer     as sobrecargas_repartidas,
  jsonb_array_length(a.resumen->'sin_repartir')       as sin_repartir,
  (a.resumen->>'con_historia_sin_quitar')::integer    as con_historia_sin_quitar,
  (select count(*)
     from public.racks rk
     cross join lateral generate_series(1, rk.niveles) as n(nivel)
    where (select count(*) from public.positions p where p.rack_id = rk.id and p.level = n.nivel)
          <> public.fn_casilleros_para(greatest(rk.grid_ancho, rk.grid_alto), least(rk.grid_ancho, rk.grid_alto), n.nivel)
  )                                                   as niveles_sin_ajustar,
  (select count(*) from (
     select pos.id
       from public.positions pos
       join public.position_assignments pa
         on pa.position_id = pos.id and pa.status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
      group by pos.id, pos.capacity_units
     having sum(pa.quantity) > pos.capacity_units) x) as sobrecargados,
  (select count(*) from public.v_revision_ubicaciones) as pendientes_revision,
  (select coalesce(sum(quantity), 0) from public.inventory) as pares_en_stock,
  (select coalesce(sum(quantity), 0) from public.position_assignments
    where status in ('OCUPADA', 'EN_PICKING'))        as pares_en_estantes,
  a.resumen->'sin_repartir'                           as detalle_sin_repartir
from (select current_setting('ajuste.resumen', true)::jsonb as resumen) a;


-- =============================================================================
-- =============================================================================
--  MIGRACIÓN 24 — CÓDIGOS CON FORMATO Y DUPLICADOS CON MENSAJE
--
--  crear_rack avisa si el código ya existe en ese almacén (antes reventaba la
--  restricción única) y propone el siguiente libre. El código de almacén pasa
--  a exigir tres letras, guion y hasta seis alfanuméricos.
-- =============================================================================
-- =============================================================================

-- =============================================================================
--  BLOQUE A — UN RACK REPETIDO SE AVISA, NO SE ESTRELLA
-- =============================================================================
create or replace function public.crear_rack(
  p_warehouse_code  text,
  p_code            text,
  p_grid_x          integer,
  p_grid_y          integer,
  p_grid_ancho      integer,
  p_grid_alto       integer,
  p_niveles         integer default 3,
  p_slots_por_nivel integer default 7
)
returns public.racks
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_wh    public.warehouses;
  v_rack  public.racks;
  v_min   integer := public.fn_niveles_infantiles() + 1;
  v_libre text;
begin
  perform public.fn_exigir_rol('SUPERVISOR', 'JEFE');

  if p_code !~ '^RACK-[0-9]{2}$' then
    raise exception 'El código del rack debe tener el formato RACK-NN (por ejemplo RACK-09). Recibido: %.', p_code;
  end if;

  if p_niveles not between v_min and 8 then
    raise exception 'Un rack tiene entre % y 8 niveles: los % de abajo son para calzado infantil y hace falta al menos uno encima para el de adulto. Se pidieron %.',
      v_min, public.fn_niveles_infantiles(), p_niveles;
  end if;

  select * into v_wh from public.warehouses where code = p_warehouse_code;
  if v_wh.id is null then
    raise exception 'No existe el almacén %.', p_warehouse_code;
  end if;

  if exists (select 1 from public.racks where warehouse_id = v_wh.id and code = p_code) then
    -- El primer hueco en la numeración, que es lo que se iba a buscar a mano.
    select 'RACK-' || lpad(g.n::text, 2, '0') into v_libre
      from generate_series(1, 99) as g(n)
     where not exists (
       select 1 from public.racks
        where warehouse_id = v_wh.id
          and code = 'RACK-' || lpad(g.n::text, 2, '0'))
     order by g.n
     limit 1;

    raise exception 'En % ya hay un rack %. %',
      v_wh.name, p_code,
      coalesce('El siguiente código libre es ' || v_libre || '.',
               'Ese almacén ya usó los 99 códigos de rack.');
  end if;

  -- El trigger trg_racks_geometria valida acá forma, plano, solapes y puerta.
  insert into public.racks (warehouse_id, code, grid_x, grid_y, grid_ancho, grid_alto, niveles)
  values (v_wh.id, p_code, p_grid_x, p_grid_y, p_grid_ancho, p_grid_alto, p_niveles)
  returning * into v_rack;

  if p_slots_por_nivel is null then
    perform public.fn_ajustar_casilleros(v_rack.id, p_niveles);
  else
    perform public.fn_configurar_posiciones(v_rack.id, p_niveles, p_slots_por_nivel);
  end if;

  select * into v_rack from public.racks where id = v_rack.id;
  return v_rack;
end;
$fn$;

grant execute on function public.crear_rack(text, text, integer, integer, integer, integer, integer, integer) to authenticated;


-- =============================================================================
--  BLOQUE B — EL CÓDIGO DE ALMACÉN TIENE UN FORMATO
-- =============================================================================
-- Solo cambia la regla del código; el resto es igual que en la 13.
create or replace function public.crear_almacen(
  p_code       text,
  p_name       text,
  p_grid_ancho integer default 40,
  p_grid_alto  integer default 30,
  p_address    text    default null
)
returns public.warehouses
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_code text;
  v_wh   public.warehouses;
begin
  perform public.fn_exigir_rol('SUPERVISOR', 'JEFE');

  v_code := upper(trim(p_code));

  if v_code !~ '^[A-Z]{3}-[A-Z0-9]{1,6}$' then
    raise exception 'El código % no sirve: son tres letras, un guion y hasta seis letras o números, como ALM-D o BOD-02.', v_code;
  end if;

  if coalesce(trim(p_name), '') = '' then
    raise exception 'El almacén necesita un nombre.';
  end if;

  if length(trim(p_name)) > 40 then
    raise exception 'El nombre no puede pasar de 40 caracteres (tiene %).', length(trim(p_name));
  end if;

  if length(coalesce(trim(p_address), '')) > 120 then
    raise exception 'La dirección no puede pasar de 120 caracteres (tiene %).', length(trim(p_address));
  end if;

  if p_grid_ancho not between 10 and 80 or p_grid_alto not between 10 and 80 then
    raise exception 'El almacén debe medir entre 10 y 80 m por lado. Se pidió % x %.',
      p_grid_ancho, p_grid_alto;
  end if;

  if exists (select 1 from public.warehouses where code = v_code) then
    raise exception 'Ya existe un almacén con el código %.', v_code;
  end if;

  -- El último carácter del código encabeza los códigos de posición de sus
  -- racks (ALM-D -> D-07-01, ALM-04 -> 4-07-01; ver crear_rack). Dos almacenes
  -- que terminen igual generarían posiciones que se leen idénticas.
  if exists (select 1 from public.warehouses where right(code, 1) = right(v_code, 1)) then
    raise exception 'El código % termina en "%", igual que un almacén que ya existe. De ese carácter salen los códigos de posición, así que debe ser único.',
      v_code, right(v_code, 1);
  end if;

  insert into public.warehouses (code, name, address, grid_ancho, grid_alto, entrada_x, entrada_y)
  values (v_code, trim(p_name), nullif(trim(p_address), ''),
          p_grid_ancho, p_grid_alto, p_grid_ancho / 2, p_grid_alto - 1)
  returning * into v_wh;

  return v_wh;
end;
$fn$;

grant execute on function public.crear_almacen(text, text, integer, integer, text) to authenticated;


-- =============================================================================
--  VERIFICACIÓN
-- =============================================================================
-- Los códigos que ya existen tienen que seguir cumpliendo el formato nuevo: si
-- alguno saliera 'no cumple', crear otro almacén igual a él ya no sería posible.
select code,
       case when code ~ '^[A-Z]{3}-[A-Z0-9]{1,6}$' then 'cumple' else 'NO cumple' end as formato
  from public.warehouses
 order by code;
