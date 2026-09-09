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
