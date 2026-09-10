-- =============================================================================
--  MIGRACIÓN 14 — EL PREFIJO DE UNA POSICIÓN TAMBIÉN PUEDE SER UN DÍGITO
--
--  Crear un rack en un almacén con código 'ALM-04' fallaba con:
--      new row for relation "positions" violates check constraint
--      "positions_code_check"
--
--  El prefijo del código de posición sale de la última letra del almacén
--  (crear_rack, migración 10: right(code, 1)), así que para 'ALM-04' daba '4'
--  y el código quedaba '4-01-01'. positions.code exigía ^[A-Z]- y lo rechazaba.
--
--  Las dos reglas venían de la 01 y nunca se contradijeron porque hasta la
--  migración 13 no se podían crear almacenes: los tres del seed terminaban en
--  A, B y C. En cuanto se pudo dar de alta uno, quedó a la vista que
--  warehouses.code SIEMPRE admitió dígitos (^[A-Z0-9]{2,10}...) y que era
--  positions el que no acompañaba.
--
--  Se relaja positions en vez de exigir que el almacén termine en letra: un
--  '4' identifica el almacén igual de bien que una 'A', el requisito real es
--  que el prefijo sea único (lo garantiza crear_almacen), y obligar a letra
--  habría techado el sistema en 26 almacenes — y obligado a borrar el que ya
--  existe. Los códigos viejos (A-03-02) siguen siendo válidos.
--
--  Requiere 01-13. Idempotente.
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
