-- =============================================================================
--  MIGRACIÓN 26 — QUE DAR DE ALTA UN ARTÍCULO NO DEJE LA MITAD HECHA
--
--  Se descubrió probando el alta de punta a punta desde el formulario: el
--  artículo se creaba y después fallaba con
--
--    Could not find the function public.crear_registro_inventario(...)
--
--  porque la migración 06 nunca llegó a correrse en esta base. Peor que el
--  error es lo que dejaba: el INSERT en inventory_items ya había pasado, así
--  que quedaba un artículo sin fila de inventario — sin stock, sin umbrales y
--  sin almacén—, invisible para el dashboard y para "Existencias".
--
--  Eran dos llamadas separadas desde el cliente, y entre una y otra no hay
--  transacción: si la segunda falla, la primera no se deshace. Esta migración
--  las junta en una sola función, que es la única forma de que "crear un
--  artículo" sea todo o nada.
--
--  Contiene tres cosas:
--
--    1. crear_registro_inventario — la de la migración 06, por si falta (es
--       `create or replace`, así que correrla de nuevo no molesta).
--    2. Dos CHECK que faltaban: precio y costo tienen que ser mayores que
--       cero, y el stock máximo no puede quedar por debajo del mínimo. El
--       formulario ya los pedía; sin esto, cualquier UPDATE los esquiva.
--    3. crear_articulo_con_inventario — el alta completa en una transacción.
--
--  El mínimo NO se exige >= 1 en la tabla a propósito: cuando se ejecuta una
--  ENTRADA de un artículo que todavía no tiene fila en ese almacén, el flujo
--  de movimientos (migración 02) la crea con los valores por defecto. Exigir
--  un mínimo ahí rompería la aprobación de movimientos. Que el mínimo sea al
--  menos 1 es una regla del formulario de alta, no del dominio.
--
--  Requiere 01-05. Idempotente.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. La función de la migración 06, que falta en esta base.
-- -----------------------------------------------------------------------------
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

  -- Ninguna unidad de stock existe sin asiento en el kardex, tampoco la carga
  -- inicial: si el artículo ya tenía existencias físicas al digitalizarlo,
  -- esto lo deja igual de trazable que un movimiento normal.
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


-- -----------------------------------------------------------------------------
-- 2. Los CHECK que el formulario ya pedía y la tabla no.
--
--    Los 80 artículos y las 80 filas de inventario que hay hoy cumplen los
--    tres (se verificó antes de agregarlos), así que no hay nada que migrar.
-- -----------------------------------------------------------------------------

-- Un artículo que se vende a 0 o que costó 0 es un dato sin cargar, no un
-- precio. El `is null` sigue permitido: el precio puede faltar todavía.
alter table public.inventory_items drop constraint if exists inventory_items_price_check;
alter table public.inventory_items
  add constraint inventory_items_price_check check (price is null or price > 0);

alter table public.inventory_items drop constraint if exists inventory_items_cost_check;
alter table public.inventory_items
  add constraint inventory_items_cost_check check (cost is null or cost > 0);

-- Un máximo por debajo del mínimo deja al artículo "bajo mínimo" y "sobre
-- máximo" a la vez: no es un umbral, es una contradicción.
alter table public.inventory drop constraint if exists ck_inventory_max_sobre_min;
alter table public.inventory
  add constraint ck_inventory_max_sobre_min
  check (max_stock is null or min_stock is null or max_stock >= min_stock);

comment on constraint ck_inventory_max_sobre_min on public.inventory is
  'El stock máximo no puede quedar por debajo del mínimo (el artículo estaría bajo mínimo y sobre máximo a la vez).';


-- -----------------------------------------------------------------------------
-- 3. El alta completa, en una sola transacción.
--
--    Recibe el artículo y el almacén donde se registra. Si algo falla —el SKU
--    repetido, la talla ya cargada para ese modelo, el almacén inexistente—
--    no queda nada a medias, porque todo ocurre dentro de la misma llamada.
-- -----------------------------------------------------------------------------
create or replace function public.crear_articulo_con_inventario(
  p_product_id     uuid,
  p_sku            text,
  p_size_label     text,
  p_warehouse_code text,
  p_size_system    text    default 'EU',
  p_price          numeric default null,
  p_cost           numeric default null,
  p_weight         numeric default null,
  p_length         numeric default null,
  p_width          numeric default null,
  p_height         numeric default null,
  p_min_stock      integer default 0,
  p_max_stock      integer default null
)
returns public.inventory_items
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item  public.inventory_items;
  v_wh_id uuid;
  v_sku   text := upper(btrim(p_sku));
  v_talla text := btrim(p_size_label);
begin
  -- El mismo rol que exige crear_registro_inventario: crear el artículo sin
  -- poder crear su inventario no serviría de nada.
  perform public.fn_exigir_rol('SUPERVISOR', 'JEFE');

  if not exists (select 1 from public.products where id = p_product_id) then
    raise exception 'No existe el producto indicado.';
  end if;

  select id into v_wh_id from public.warehouses where code = p_warehouse_code;
  if v_wh_id is null then
    raise exception 'No existe el almacén %.', p_warehouse_code;
  end if;

  if p_max_stock is not null and p_max_stock < p_min_stock then
    raise exception 'El stock máximo (%) no puede ser menor que el mínimo (%).', p_max_stock, p_min_stock;
  end if;

  insert into public.inventory_items
    (product_id, sku, size_label, size_system, price, cost, weight, length, width, height)
  values
    (p_product_id, v_sku, v_talla, coalesce(p_size_system, 'EU'),
     p_price, p_cost, p_weight, p_length, p_width, p_height)
  returning * into v_item;

  -- La cantidad arranca en 0 siempre: el stock entra por un movimiento de
  -- ENTRADA aprobado, nunca por el alta del catálogo.
  insert into public.inventory (item_id, warehouse_id, quantity, min_stock, max_stock)
  values (v_item.id, v_wh_id, 0, p_min_stock, p_max_stock);

  return v_item;
end;
$$;

grant execute on function public.crear_articulo_con_inventario(
  uuid, text, text, text, text, numeric, numeric, numeric, numeric, numeric, numeric, integer, integer
) to authenticated;

comment on function public.crear_articulo_con_inventario is
  'Alta de artículo + su registro de inventario en una sola transacción: si algo falla no queda un artículo sin inventario. SUPERVISOR+.';
