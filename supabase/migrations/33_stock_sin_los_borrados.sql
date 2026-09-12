-- =============================================================================
--  MIGRACIÓN 33 — v_stock_actual DEJA FUERA LO QUE ESTÁ EN LA PAPELERA
--
--  La vista se escribió en la migración 01. El borrado lógico (`deleted_at`)
--  llegó en la 02, y la vista nunca se actualizó: sigue devolviendo los
--  artículos eliminados, con cantidad 0 y estado SIN_STOCK.
--
--  Hoy no se nota en pantalla porque el dashboard lee CatalogoAPI
--  .listarArticulos(), que sí filtra. Pero v_stock_actual es la vista que
--  cualquiera consultaría para preguntar "¿cuánto stock hay?", y responder con
--  filas de artículos que ya no existen es sencillamente incorrecto.
--
--  Se filtra por los dos lados: el artículo y su modelo. Borrar un producto
--  entero también debe sacar sus tallas de la vista.
--
--  create or replace view solo permite añadir columnas al final, no quitarlas
--  ni reordenarlas: aquí solo se agrega un WHERE, así que la firma no cambia.
--
--  Requiere 01-32. Idempotente.
-- =============================================================================

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
join public.warehouses      w  on w.id  = inv.warehouse_id
where it.deleted_at is null
  and p.deleted_at is null;

alter view public.v_stock_actual set (security_invoker = on);

comment on view public.v_stock_actual is
  'Stock por artículo y almacén, con su estado. Excluye lo que está en la papelera (inventory_items.deleted_at / products.deleted_at).';


do $$
declare
  v_vista   integer;
  v_vivos   integer;
begin
  select count(*) into v_vista from public.v_stock_actual;
  select count(*) into v_vivos
    from public.inventory inv
    join public.inventory_items it on it.id = inv.item_id
    join public.products        p  on p.id  = it.product_id
   where it.deleted_at is null and p.deleted_at is null;

  raise notice 'v_stock_actual: % filas (registros de inventario vivos: %)', v_vista, v_vivos;
end;
$$;
