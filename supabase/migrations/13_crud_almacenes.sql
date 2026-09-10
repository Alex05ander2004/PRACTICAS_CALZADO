-- =============================================================================
--  MIGRACIÓN 13 — CREAR Y ELIMINAR ALMACENES
--
--  Los tres almacenes venían del seed y no había forma de agregar un cuarto ni
--  de borrar uno creado por error: el <select> del dashboard los tenía escritos
--  a mano en el HTML, así que aunque la tabla admitiera un INSERT, el almacén
--  nuevo no habría aparecido en ninguna pantalla.
--
--  Eliminar sigue el mismo criterio que eliminar_rack (migración 10): uno
--  recién creado por error se borra sin drama; uno que ya guardó mercadería NO.
--  La diferencia es que un almacén es el contenedor de todo lo demás, así que
--  hay más cosas que revisar — racks, inventario, órdenes, kardex y conteos.
--
--  Requiere 01-12. Idempotente.
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
