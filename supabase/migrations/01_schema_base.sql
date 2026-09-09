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
