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
