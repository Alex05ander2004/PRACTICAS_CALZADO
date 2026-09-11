-- =============================================================================
--  MIGRACIÓN 21 — CASILLEROS A MEDIDA DE UN MODELO Y REVISIÓN DE UBICACIONES
--
--  1. Cuántos casilleros tiene un nivel era un número que alguien escribía, y
--     salía mal en las dos direcciones. RACK-07 tenía 25 casilleros de 56 cm
--     por nivel: la caja infantil entra 3 veces y sobran 11 cm en cada uno.
--     Pero dejarlo en manos de "el tamaño que más cajas guarde" es peor: gana
--     UN casillero de 14 m por nivel —3 557 cajas para un solo modelo—, porque
--     menos divisiones desperdician menos al redondear. La medida la da el
--     negocio: un casillero guarda un modelo (migración 20), así que tiene que
--     medir lo que ocupa un modelo. Eso se calcula del stock real.
--
--  2. Con casilleros angostos para lo infantil, un rack largo pasa de 99
--     casilleros: el último tramo del código admite 3 dígitos (A-07-101). Los
--     códigos existentes, de 2, siguen valiendo y no se tocan.
--
--  3. Revisión de ubicaciones: una vista con todo lo que está fuera de lugar
--     (nivel equivocado, casillero sobrecargado, stock sin ubicar, cajas
--     fantasma) y una corrección por tipo. Las cajas fantasma no tienen
--     corrección automática: solo un conteo sabe si miente el stock o el
--     estante, así que se elige una por una.
--
--  Requiere 01-20. Idempotente.
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
