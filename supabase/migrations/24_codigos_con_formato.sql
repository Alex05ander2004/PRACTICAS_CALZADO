-- =============================================================================
--  MIGRACIÓN 24 — CÓDIGOS CON FORMATO Y DUPLICADOS CON MENSAJE
--
--  1. crear_rack no revisaba si el código ya existía en ese almacén: reventaba
--     la restricción única y el usuario veía "duplicate key value violates
--     unique constraint uq_racks_warehouse_code". crear_almacen sí lo hacía
--     desde la 13; ahora los dos avisan igual, y el del rack propone el
--     siguiente código libre, que es lo que el usuario iba a buscar.
--
--  2. El código de almacén admitía casi cualquier cosa: 'AB', '12345',
--     'A-B-C-D'. Pasa a exigir tres letras, guion y hasta seis letras o
--     números (ALM-D, BOD-02), que es el formato que ya siguen los cuatro
--     almacenes existentes y el que valida el formulario. Se aprieta en la
--     función y no en el CHECK de la tabla: el CHECK es la red de seguridad
--     para datos que entren por otro lado, y estrecharlo obligaría a migrar
--     cualquier código heredado que no lo cumpla.
--
--  Requiere 01-23. Idempotente.
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
