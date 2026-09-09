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
