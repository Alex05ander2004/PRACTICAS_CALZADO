-- =============================================================================
--  MIGRACIÓN 11 — EL PLANO REALISTA: TAMAÑO DEL ALMACÉN Y CAPACIDAD EN CAJAS
--
--  Dos huecos que quedaron del editor de plano (migraciones 09 y 10):
--
--  1. El almacén tenía un tamaño fijo (40 x 30, escritos por la migración 09).
--     Un almacén real se mide una vez y se carga; el editor no servía si el
--     local no medía exactamente eso.
--
--  2. `positions.capacity_units` era ficción: crear_rack escribía 200 en cada
--     posición y los seeds 200/150, números inventados. Pero el trigger de la
--     migración 02 YA valida contra ese número, así que la validación estaba
--     comparando stock real contra un dato imaginario.
--
--  Acá capacity_units pasa a salir de la geometría: un rack de N x M metros
--  con P niveles tiene un volumen de estantería concreto, y una caja de
--  zapatos tiene un tamaño concreto. Cuántas caben es una división, no una
--  opinión. El nivel 1 (infantil, migración 04) rinde más porque la caja de
--  niño es más chica: la regla de negocio y la física coinciden.
--
--  Requiere 01-10. Idempotente.
-- =============================================================================


-- =============================================================================
--  BLOQUE A — EL TAMAÑO DEL ALMACÉN ES UN DATO, NO UNA CONSTANTE
-- =============================================================================
-- El tope de 80 celdas por lado no es decorativo: la ruta más corta se calcula
-- con A* sobre la grilla (js/plano-editor.js) y su cola de prioridad es una
-- búsqueda lineal del mínimo. A 80 x 80 son 6 400 celdas, que sigue siendo
-- instantáneo; dejarlo abierto convertiría "calcular ruta" en un cuelgue del
-- navegador. El piso de 10 evita un almacén donde no entre ni un rack.
alter table public.warehouses drop constraint if exists ck_warehouses_grilla;
alter table public.warehouses
  add constraint ck_warehouses_grilla check (
    grid_ancho between 10 and 80
    and grid_alto between 10 and 80
    and entrada_x >= 0 and entrada_x < grid_ancho
    and entrada_y >= 0 and entrada_y < grid_alto
  );

create or replace function public.redimensionar_almacen(
  p_warehouse_code text,
  p_grid_ancho     integer,
  p_grid_alto      integer
)
returns public.warehouses
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_wh     public.warehouses;
  v_afuera text;
begin
  perform public.fn_exigir_rol('SUPERVISOR', 'JEFE');

  if p_grid_ancho not between 10 and 80 or p_grid_alto not between 10 and 80 then
    raise exception 'El almacén debe medir entre 10 y 80 m por lado. Se pidió % x %.',
      p_grid_ancho, p_grid_alto;
  end if;

  select * into v_wh from public.warehouses where code = p_warehouse_code;
  if v_wh.id is null then
    raise exception 'No existe el almacén %.', p_warehouse_code;
  end if;

  -- Achicar el plano por debajo de un rack existente lo dejaría "fuera del
  -- almacén". Mover racks solo para que quepan sería decidir por el usuario
  -- dónde va su mercadería: se rechaza y se dice cuáles estorban.
  select string_agg(code, ', ' order by code) into v_afuera
    from public.racks
   where warehouse_id = v_wh.id
     and (grid_x + grid_ancho > p_grid_ancho or grid_y + grid_alto > p_grid_alto);

  if v_afuera is not null then
    raise exception 'No se puede achicar % a % x % m: % quedaría(n) fuera del plano. Muévelos primero.',
      v_wh.code, p_grid_ancho, p_grid_alto, v_afuera;
  end if;

  -- La entrada sí se reacomoda sola: es un punto de referencia del plano, no
  -- mercadería de nadie.
  update public.warehouses
     set grid_ancho = p_grid_ancho,
         grid_alto  = p_grid_alto,
         entrada_x  = least(entrada_x, p_grid_ancho - 1),
         entrada_y  = least(entrada_y, p_grid_alto - 1),
         updated_at = now()
   where id = v_wh.id
  returning * into v_wh;

  return v_wh;
end;
$fn$;

grant execute on function public.redimensionar_almacen(text, integer, integer) to authenticated;


-- =============================================================================
--  BLOQUE B — CUÁNTAS CAJAS ENTRAN: LA FÍSICA DEL ESTANTE
-- =============================================================================
-- Medidas de caja de calzado reales (largo x ancho x alto, en metros):
--   adulto    0.33 x 0.20 x 0.13
--   infantil  0.25 x 0.15 x 0.10   -> por eso el nivel 1 rinde casi el doble
-- Altura útil entre estantes: 0.45 m. Factor de aprovechamiento 0.85, el que
-- se usa en planificación de almacenes para descontar montantes, holguras y
-- el espacio que necesita la mano para sacar la caja.
create or replace function public.fn_cajas_en_slot(
  p_frente_m numeric,
  p_fondo_m  numeric,
  p_nivel    integer
)
returns integer
language sql
immutable
as $fn$
  select greatest(0, floor(
           floor(p_frente_m / c.largo)
         * floor(p_fondo_m  / c.ancho)
         * floor(0.45       / c.alto)
         * 0.85
         )::integer)
    from (select
            case when p_nivel = 1 then 0.25 else 0.33 end as largo,
            case when p_nivel = 1 then 0.15 else 0.20 end as ancho,
            case when p_nivel = 1 then 0.10 else 0.13 end as alto
         ) c;
$fn$;

comment on function public.fn_cajas_en_slot is
  'Cajas de calzado que entran en un casillero de p_frente_m x p_fondo_m en el nivel dado. El nivel 1 usa medidas de caja infantil (migración 04).';

-- Lo que el editor necesita ANTES de crear nada: "un rack de 14 x 2 m con 3
-- niveles y 7 posiciones por nivel, ¿cuánto guarda?". Vive en la base y no en
-- el JS para que la cifra que se muestra sea la misma que se va a grabar.
create or replace function public.estimar_capacidad_rack(
  p_grid_ancho      integer,
  p_grid_alto       integer,
  p_niveles         integer,
  p_slots_por_nivel integer
)
returns jsonb
language sql
immutable
as $fn$
  with medidas as (
    -- El frente es el lado largo (por donde se camina); el fondo, la
    -- profundidad del estante.
    select greatest(p_grid_ancho, p_grid_alto)::numeric as frente,
           least(p_grid_ancho, p_grid_alto)::numeric    as fondo,
           greatest(p_slots_por_nivel, 1)               as slots
  ),
  niveles as (
    select n.nivel,
           public.fn_cajas_en_slot(m.frente / m.slots, m.fondo, n.nivel) * m.slots as cajas
      from medidas m
      cross join generate_series(1, greatest(p_niveles, 1)) as n(nivel)
  )
  select jsonb_build_object(
    'frente',     (select frente from medidas),
    'fondo',      (select fondo  from medidas),
    'posiciones', greatest(p_niveles, 1) * greatest(p_slots_por_nivel, 1),
    'cajas',      (select sum(cajas) from niveles),
    'por_nivel',  (select jsonb_agg(jsonb_build_object('nivel', nivel, 'cajas', cajas) order by nivel) from niveles)
  );
$fn$;

grant execute on function public.estimar_capacidad_rack(integer, integer, integer, integer) to authenticated;


-- =============================================================================
--  BLOQUE C — CUÁNTOS PISOS TIENE EL RACK
-- =============================================================================
alter table public.racks
  add column if not exists niveles integer not null default 3;

alter table public.racks drop constraint if exists ck_racks_niveles;
alter table public.racks add constraint ck_racks_niveles check (niveles between 1 and 8);

comment on column public.racks.niveles is
  'Pisos de estantería del mueble. Propiedad física: junto con grid_ancho/grid_alto determina cuántas cajas entran. Las posiciones se reparten entre estos niveles.';

-- Los racks que ya existían: el nivel real se deduce de sus posiciones. Las
-- posiciones sin nivel declarado (los seeds las dejaron en NULL) son estantes
-- de adulto, así que van al nivel 2, nunca al 1 — el 1 está reservado para
-- calzado infantil y hoy no hay nada de eso ubicado ahí.
update public.positions set level = 2 where level is null;

update public.positions p
   set slot = s.orden
  from (select id, row_number() over (partition by rack_id, level order by code) as orden
          from public.positions) s
 where s.id = p.id and p.slot is distinct from s.orden;

update public.racks r
   set niveles = least(8, greatest(1, coalesce((select max(p.level) from public.positions p where p.rack_id = r.id), 3)));


-- =============================================================================
--  BLOQUE D — RECALCULAR LA CAPACIDAD DECLARADA A PARTIR DE LA GEOMETRÍA
-- =============================================================================
-- SECURITY DEFINER porque escribe en positions, que no tiene política de
-- UPDATE para authenticated (mismo criterio que crear_rack): la capacidad no
-- es un campo que se edite a mano, se deduce.
create or replace function public.fn_recalcular_capacidades(p_rack_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_frente numeric;
  v_fondo  numeric;
begin
  select greatest(grid_ancho, grid_alto), least(grid_ancho, grid_alto)
    into v_frente, v_fondo
    from public.racks where id = p_rack_id;

  update public.positions p
     set capacity_units = greatest(
           public.fn_cajas_en_slot(v_frente / n.slots, v_fondo, p.level),
           n.ocupado   -- nunca declarar menos de lo que ya hay adentro
         ),
         updated_at = now()
    from (
      select pp.id,
             count(*) over (partition by pp.level) as slots,
             (select coalesce(sum(pa.quantity), 0)
                from public.position_assignments pa
               where pa.position_id = pp.id
                 and pa.status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')) as ocupado
        from public.positions pp
       where pp.rack_id = p_rack_id
    ) n
   where n.id = p.id;
end;
$fn$;

-- Redimensionar un rack en el editor cambia cuántas cajas entran. Recalcular
-- desde el trigger evita que la UI tenga que acordarse de pedirlo.
create or replace function public.fn_racks_recalcular_capacidad()
returns trigger
language plpgsql
as $fn$
begin
  perform public.fn_recalcular_capacidades(new.id);
  return null;
end;
$fn$;

drop trigger if exists trg_racks_capacidad on public.racks;
create trigger trg_racks_capacidad
  after update of grid_ancho, grid_alto on public.racks
  for each row
  when (old.grid_ancho is distinct from new.grid_ancho or old.grid_alto is distinct from new.grid_alto)
  execute function public.fn_racks_recalcular_capacidad();


-- =============================================================================
--  BLOQUE E — DECLARAR NIVELES Y POSICIONES DE UN RACK
-- =============================================================================
-- Regla de oro: NUNCA se renumera una posición existente. El código de una
-- posición aparece en el kardex y en los movimientos; si 'A-03-02' pasara a
-- señalar otro casillero, el historial estaría mintiendo. Por eso esta función
-- solo AGREGA los casilleros que faltan (con el primer índice libre) y BORRA
-- los de niveles que se eliminan, negándose si tienen historial.
create or replace function public.fn_configurar_posiciones(
  p_rack_id         uuid,
  p_niveles         integer,
  p_slots_por_nivel integer
)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_rack   public.racks;
  v_letra  text;
  v_num    text;
  v_pos    record;
  v_nivel  integer;
  v_faltan integer;
  v_idx    integer;
begin
  if p_niveles not between 1 and 8 then
    raise exception 'Un rack tiene entre 1 y 8 niveles. Se pidieron %.', p_niveles;
  end if;
  if p_slots_por_nivel not between 1 and 40 then
    raise exception 'Las posiciones por nivel deben estar entre 1 y 40. Se pidieron %.', p_slots_por_nivel;
  end if;
  if p_niveles * p_slots_por_nivel > 99 then
    raise exception '% niveles x % posiciones son % casilleros y el código de posición solo admite 99. Divídelo en dos racks.',
      p_niveles, p_slots_por_nivel, p_niveles * p_slots_por_nivel;
  end if;

  select * into v_rack from public.racks where id = p_rack_id;
  if v_rack.id is null then
    raise exception 'El rack no existe.';
  end if;

  select right(w.code, 1) into v_letra from public.warehouses w where w.id = v_rack.warehouse_id;
  v_num := right(v_rack.code, 2);

  -- Niveles que se van: solo si están vacíos de presente y de pasado.
  for v_pos in
    select p.id, p.code from public.positions p
     where p.rack_id = p_rack_id and p.level > p_niveles
  loop
    if exists (select 1 from public.position_assignments where position_id = v_pos.id)
       or exists (select 1 from public.inventory_movements where position_id = v_pos.id)
       or exists (select 1 from public.stock_ledger      where position_id = v_pos.id)
    then
      raise exception 'No se puede bajar % a % niveles: la posición % tiene historial de movimientos.',
        v_rack.code, p_niveles, v_pos.code;
    end if;
    delete from public.positions where id = v_pos.id;
  end loop;

  -- Niveles que faltan o están incompletos.
  for v_nivel in 1..p_niveles loop
    select p_slots_por_nivel - count(*) into v_faltan
      from public.positions where rack_id = p_rack_id and level = v_nivel;

    while v_faltan > 0 loop
      -- Primer índice libre del rack: así los códigos ya emitidos no se tocan.
      select min(g.n) into v_idx
        from generate_series(1, 99) as g(n)
       where not exists (
         select 1 from public.positions
          where rack_id = p_rack_id
            and code = v_letra || '-' || v_num || '-' || lpad(g.n::text, 2, '0')
       );

      if v_idx is null then
        raise exception 'El rack % ya usó los 99 códigos de posición disponibles.', v_rack.code;
      end if;

      insert into public.positions (rack_id, code, capacity_units, level, slot)
      values (p_rack_id,
              v_letra || '-' || v_num || '-' || lpad(v_idx::text, 2, '0'),
              0, v_nivel,
              p_slots_por_nivel - v_faltan + 1);

      v_faltan := v_faltan - 1;
    end loop;
  end loop;

  update public.racks set niveles = p_niveles, updated_at = now() where id = p_rack_id;
  perform public.fn_recalcular_capacidades(p_rack_id);
end;
$fn$;

-- Entrada pública: el panel del editor la llama al cambiar niveles/posiciones.
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
  v_rack  public.racks;
  v_total integer;
  v_cajas integer;
begin
  perform public.fn_exigir_rol('SUPERVISOR', 'JEFE');
  perform public.fn_configurar_posiciones(p_rack_id, p_niveles, p_slots_por_nivel);

  select * into v_rack from public.racks where id = p_rack_id;
  select count(*), coalesce(sum(capacity_units), 0) into v_total, v_cajas
    from public.positions where rack_id = p_rack_id;

  return jsonb_build_object(
    'estado',     'OK',
    'posiciones', v_total,
    'cajas',      v_cajas,
    'mensaje',    v_rack.code || ': ' || p_niveles || ' niveles, ' || v_total ||
                  ' posiciones, capacidad ' || v_cajas || ' cajas.'
  );
end;
$fn$;

grant execute on function public.configurar_rack(uuid, integer, integer) to authenticated;


-- =============================================================================
--  BLOQUE F — crear_rack AHORA PIENSA EN PISOS, NO EN UN NIVEL SUELTO
-- =============================================================================
-- La versión de la migración 10 recibía UN nivel y N posiciones sueltas: un
-- rack de un solo piso. Un rack real tiene varios, y el nivel 1 de cualquiera
-- de ellos es el que admite calzado infantil. Se cambian los nombres de los
-- parámetros, así que hay que soltar la función anterior (Postgres no permite
-- renombrar parámetros con CREATE OR REPLACE).
drop function if exists public.crear_rack(text, text, integer, integer, integer, integer, integer, integer);

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
begin
  perform public.fn_exigir_rol('SUPERVISOR', 'JEFE');

  -- El código se exige con formato RACK-NN porque de ahí sale el número que
  -- va en el código de cada posición (A-07-01). Sin formato fijo, los códigos
  -- de posición dejarían de ser predecibles.
  if p_code !~ '^RACK-[0-9]{2}$' then
    raise exception 'El código del rack debe tener el formato RACK-NN (por ejemplo RACK-09). Recibido: %.', p_code;
  end if;

  select * into v_wh from public.warehouses where code = p_warehouse_code;
  if v_wh.id is null then
    raise exception 'No existe el almacén %.', p_warehouse_code;
  end if;

  -- El trigger trg_racks_geometria valida acá que quepa y que no pise a otro.
  insert into public.racks (warehouse_id, code, grid_x, grid_y, grid_ancho, grid_alto, niveles)
  values (v_wh.id, p_code, p_grid_x, p_grid_y, p_grid_ancho, p_grid_alto, greatest(least(p_niveles, 8), 1))
  returning * into v_rack;

  -- Un rack sin posiciones es un mueble que no puede guardar nada: se crean
  -- junto con él, repartidas entre sus niveles y con la capacidad que su
  -- geometría permite.
  perform public.fn_configurar_posiciones(v_rack.id, p_niveles, p_slots_por_nivel);

  select * into v_rack from public.racks where id = v_rack.id;
  return v_rack;
end;
$fn$;

grant execute on function public.crear_rack(text, text, integer, integer, integer, integer, integer, integer) to authenticated;


-- =============================================================================
--  BLOQUE G — PONER AL DÍA LA CAPACIDAD DE TODO LO QUE YA EXISTÍA
-- =============================================================================
do $bloque$
declare
  r record;
begin
  for r in select id from public.racks loop
    perform public.fn_recalcular_capacidades(r.id);
  end loop;
end;
$bloque$;


-- =============================================================================
--  VERIFICACIÓN
-- =============================================================================
select
  w.code                                   as almacen,
  w.grid_ancho || ' x ' || w.grid_alto     as plano,
  r.code                                   as rack,
  r.grid_ancho || ' x ' || r.grid_alto     as medidas,
  r.niveles,
  count(p.id)                              as posiciones,
  sum(p.capacity_units)                    as capacidad_cajas
from public.warehouses w
join public.racks      r on r.warehouse_id = w.id
left join public.positions p on p.rack_id = r.id
group by w.code, w.grid_ancho, w.grid_alto, r.code, r.grid_ancho, r.grid_alto, r.niveles
order by w.code, r.code;
-- Esperado: capacidad_cajas ya no es un múltiplo de 200/150, sino un número
-- que cambia con las medidas del rack y sube en los racks de nivel 1.
