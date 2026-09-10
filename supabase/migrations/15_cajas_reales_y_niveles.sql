-- =============================================================================
--  MIGRACIÓN 15 — MEDIDAS REALES DE CAJA, INFANTIL EN DOS NIVELES,
--                 Y UN PISO DE TRES NIVELES POR RACK
--
--  Tres cosas que venían arrastrándose y una consecuencia:
--
--    1. Las cajas eran inventadas. El cálculo usaba 33x20x13 cm para adulto y
--       25x15x10 para infantil, números puestos a ojo. Las medidas comerciales
--       son otras y la capacidad declarada de cada rack se mueve hasta un 40%.
--
--    2. El calzado infantil cabía en un solo nivel. En un rack de 3 niveles eso
--       es un tercio del mueble para toda la línea infantil.
--
--    3. positions.level no tenía techo (`check (level >= 1)` a secas) mientras
--       racks.niveles sí estaba limitado a 8. El mismo número, dos reglas.
--
--    4. Consecuencia de ampliar lo infantil a dos niveles: un rack de 1 o 2
--       niveles se queda SIN sitio para calzado de adulto. Y así estaban 15 de
--       los 16 racks. Por eso el mínimo pasa de 1 a 3 niveles: dos abajo para
--       infantil y al menos uno arriba para adulto, en todos los racks. Los que
--       hoy tienen menos se amplían acá.
--
--  Lo que esta migración NO hace: mover mercadería. Las asignaciones de adulto
--  que hoy están en el nivel 2 se quedan donde están, y la consulta del final
--  las lista. Cambiarlas de posición en la base no las mueve del estante: el
--  sistema diría que el par está arriba cuando la caja sigue abajo, que es
--  exactamente el error que un WMS existe para evitar. Se reubican cuando
--  alguien las mueva de verdad. El trigger solo valida ubicaciones nuevas, así
--  que mientras tanto no bloquea nada — liberar una posición está exento.
--
--  Requiere 01-14. Idempotente.
-- =============================================================================


-- =============================================================================
--  BLOQUE A — DÓNDE VIVE EL LÍMITE DE LO INFANTIL
-- =============================================================================
-- El número aparece en el cálculo de capacidad y en la validación de ubicación.
-- Escrito dos veces, tarde o temprano una se queda vieja y el sistema calcula
-- la capacidad con una regla y valida con otra.
create or replace function public.fn_niveles_infantiles()
returns integer
language sql
immutable
as $fn$ select 2 $fn$;

comment on function public.fn_niveles_infantiles is
  'Hasta qué nivel llega el calzado infantil. Del siguiente en adelante es de adulto, y la exclusión vale en los dos sentidos: adulto no baja, infantil no sube. De acá sale también el mínimo de niveles de un rack (este número + 1).';


-- =============================================================================
--  BLOQUE B — LAS CAJAS, CON MEDIDAS COMERCIALES
-- =============================================================================
-- Adulto usa la caja de HOMBRE (35 x 25 x 13) y no la de mujer (33 x 19 x 11)
-- a propósito: es la mayor de las dos, y la capacidad se calcula al configurar
-- el rack, cuando todavía no se sabe qué par va a entrar ahí. Con la caja
-- grande como referencia, lo que el sistema promete siempre cabe; con la chica
-- prometería huecos que dejan de existir en cuanto llega un 44 de hombre.
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
  select greatest(0, floor(
           floor(p_frente_m / c.largo)
         * floor(p_fondo_m  / c.ancho)
         * floor(0.45       / c.alto)   -- 45 cm de luz entre estantes
         * 0.85                          -- holgura de maniobra y cajas mal puestas
         )::integer)
    from (select
            case when p_nivel <= public.fn_niveles_infantiles() then 0.22 else 0.35 end as largo,
            case when p_nivel <= public.fn_niveles_infantiles() then 0.15 else 0.25 end as ancho,
            case when p_nivel <= public.fn_niveles_infantiles() then 0.09 else 0.13 end as alto
         ) c;
$fn$;

comment on function public.fn_cajas_en_slot is
  'Cajas que entran en un casillero de p_frente_m x p_fondo_m según su nivel. Infantil 22x15x9 cm en los niveles bajos; adulto 35x25x13 (caja de hombre, la mayor) del resto.';


-- =============================================================================
--  BLOQUE C — INFANTIL ABAJO, ADULTO ARRIBA (AHORA CON DOS NIVELES ABAJO)
-- =============================================================================
-- La exclusión sigue valiendo en los dos sentidos. Que el adulto no pueda bajar
-- es lo que garantiza que el infantil tenga dónde ir: si pudiera ocupar
-- cualquier nivel, la línea infantil se quedaría sin sitio el día que el
-- almacén se llene, que es justo el día en que importa.
create or replace function public.fn_validar_publico_por_nivel()
returns trigger
language plpgsql
set search_path = public
as $fn$
declare
  v_audience text;
  v_level    smallint;
  v_tope     integer := public.fn_niveles_infantiles();
begin
  -- Liberar un espacio no reubica nada: no hay nada que validar.
  if new.status = 'LIBERADA' then
    return new;
  end if;

  select p.audience into v_audience
    from public.inventory_items it
    join public.products        p  on p.id = it.product_id
   where it.id = new.item_id;

  select level into v_level from public.positions where id = new.position_id;

  if v_level is null then
    raise exception 'La posición % no tiene nivel definido.', new.position_id;
  end if;

  if v_audience = 'NINO' and v_level > v_tope then
    raise exception
      'Calzado infantil solo puede ubicarse hasta el nivel % (los de abajo). La posición elegida está en el nivel %.',
      v_tope, v_level
      using errcode = 'check_violation';
  end if;

  if v_audience = 'ADULTO' and v_level <= v_tope then
    raise exception
      'Calzado de adulto no puede ubicarse en el nivel %: los niveles 1 a % están reservados para calzado infantil.',
      v_level, v_tope
      using errcode = 'check_violation';
  end if;

  -- UNISEX: sin restricción de nivel.
  return new;
end;
$fn$;

comment on trigger trg_assign_publico_nivel on public.position_assignments is
  'Regla del jefe de almacén: infantil en los niveles bajos, adulto por encima. El corte lo decide fn_niveles_infantiles(). Se aplica en la base, no confía en que la UI la respete.';


-- =============================================================================
--  BLOQUE D — EL NIVEL TIENE TECHO
-- =============================================================================
-- 8 niveles de 45 cm son 3,6 m de estantería, lo que se alcanza con escalera de
-- almacén. El tope ya existía en racks.niveles y en fn_configurar_posiciones,
-- pero no en positions.level, que es la columna donde de verdad se escribe.
alter table public.positions drop constraint if exists ck_positions_level;
alter table public.positions
  add constraint ck_positions_level check (level is null or level between 1 and 8);

comment on column public.positions.level is
  'Altura dentro del rack, de 1 (piso) a 8. El mismo tope que racks.niveles: son el mismo número visto desde la posición y desde el mueble.';


-- =============================================================================
--  BLOQUE E — UN RACK NO PUEDE TENER MENOS DE TRES NIVELES
-- =============================================================================
-- Con infantil ocupando dos niveles, un rack de dos no deja ni un estante para
-- adulto: sería un mueble donde la mayor parte del catálogo no puede entrar. El
-- mínimo sale de la propia regla (niveles infantiles + 1), no de un número
-- suelto, para que mover el corte de lo infantil arrastre el mínimo con él.
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
  v_min    integer := public.fn_niveles_infantiles() + 1;
begin
  if p_niveles not between v_min and 8 then
    raise exception 'Un rack tiene entre % y 8 niveles: los % de abajo son para calzado infantil y hace falta al menos uno encima para el de adulto. Se pidieron %.',
      v_min, public.fn_niveles_infantiles(), p_niveles;
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


-- =============================================================================
--  BLOQUE F — AMPLIAR LOS RACKS QUE SE QUEDARON CORTOS
-- =============================================================================
-- Sube a 3 niveles los que tienen menos, conservando su cantidad de casilleros
-- por nivel. No renumera nada: fn_configurar_posiciones solo agrega los códigos
-- que faltan, y los que ya están emitidos aparecen en el kardex.
--
-- Sin `exception when others` a propósito. Un intento anterior lo tenía, y lo
-- único que consiguió fue que el fallo de los 15 racks pasara desapercibido
-- hasta que el ALTER de abajo se estrelló sin decir contra qué. Si acá algo
-- falla, tiene que salir a la cara y detener la migración.
do $bloque$
declare
  r     record;
  v_min integer := public.fn_niveles_infantiles() + 1;
begin
  -- La lista se arma completa antes de tocar nada: fn_configurar_posiciones
  -- escribe en racks, y recorrer con un cursor la misma tabla que se está
  -- modificando es pedir problemas.
  for r in
    select id, code, slots from (
      select rk.id,
             rk.code,
             -- El nivel más poblado manda: si quedaron desparejos, ampliar al
             -- mayor completa los huecos en vez de dejarlos a medias.
             -- El ::integer no es decorativo: count(*) devuelve bigint y
             -- fn_configurar_posiciones recibe integer, así que sin el cast no
             -- hay sobrecarga que coincida y la llamada ni siquiera resuelve.
             coalesce(max(p.cuantas), 1)::integer as slots
        from public.racks rk
        left join (
          select rack_id, level, count(*) as cuantas
            from public.positions
           where level is not null
           group by rack_id, level
        ) p on p.rack_id = rk.id
       where rk.niveles < v_min
       group by rk.id, rk.code
    ) pendientes
  loop
    raise notice 'Ampliando % a % niveles con % casilleros por nivel', r.code, v_min, r.slots;
    perform public.fn_configurar_posiciones(r.id, v_min, r.slots);
  end loop;
end;
$bloque$;

-- Antes de exigir el mínimo, comprobar que no quedó ninguno corto. Sin esto, el
-- ALTER de abajo aborta con "check constraint ck_racks_niveles is violated by
-- some row" — que no dice qué fila, ni de qué almacén, ni por qué. Diez
-- segundos de guarda ahorran una hora de buscar a ciegas.
do $bloque$
declare
  v_cortos text;
begin
  select string_agg(code || ' (' || niveles || ')', ', ' order by code)
    into v_cortos
    from public.racks
   where niveles < public.fn_niveles_infantiles() + 1;

  if v_cortos is not null then
    raise exception 'Estos racks siguen por debajo de % niveles y el bloque anterior no pudo ampliarlos: %. Revisa el error que dio arriba antes de reintentar.',
      public.fn_niveles_infantiles() + 1, v_cortos;
  end if;
end;
$bloque$;

-- Recién ahora, con todos los racks ampliados, el mínimo se puede exigir: antes
-- el ALTER fallaría contra los racks que tenían 1 o 2 niveles.
alter table public.racks drop constraint if exists ck_racks_niveles;
alter table public.racks
  add constraint ck_racks_niveles check (niveles between 3 and 8);

comment on column public.racks.niveles is
  'Estantes del rack, de 3 a 8. El mínimo no es arbitrario: los dos de abajo son para calzado infantil y hace falta al menos uno encima para el de adulto.';


-- =============================================================================
--  BLOQUE F.2 — crear_rack AVISA ANTES DE INSERTAR
-- =============================================================================
-- La versión de la migración 11 inserta el rack con greatest(least(p_niveles,8),1)
-- y recién después llama a fn_configurar_posiciones. Con el mínimo de 3, pedir
-- un rack de 2 niveles ya no rebota en la función —con su mensaje explicando el
-- porqué— sino en el CHECK de la tabla, que solo dice "violates check constraint
-- ck_racks_niveles". Se valida antes de tocar nada.
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

  -- El código se exige con formato RACK-NN porque de ahí sale el número que va
  -- en el código de cada posición (A-07-01). Sin formato fijo, los códigos de
  -- posición dejarían de ser predecibles.
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

  -- El trigger trg_racks_geometria valida acá que quepa y que no pise a otro.
  insert into public.racks (warehouse_id, code, grid_x, grid_y, grid_ancho, grid_alto, niveles)
  values (v_wh.id, p_code, p_grid_x, p_grid_y, p_grid_ancho, p_grid_alto, p_niveles)
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
--  BLOQUE G — RECALCULAR LO YA DECLARADO CON LAS CAJAS NUEVAS
-- =============================================================================
-- fn_recalcular_capacidades (migración 11) reparte el frente entre los
-- casilleros del nivel y nunca declara menos de lo que la posición tiene
-- adentro: declarar 40 donde hay 60 dejaría el rack en sobrecarga permanente.
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
-- 1. Qué caja asume cada nivel y cuánto rinde.
select
  nivel,
  case when nivel <= public.fn_niveles_infantiles()
       then 'infantil 22x15x9' else 'adulto 35x25x13' end as caja,
  public.fn_cajas_en_slot(2, 2, nivel)                     as cajas_en_un_slot_de_2x2_m
from generate_series(1, 8) as g(nivel)
order by nivel;

-- 2. Ningún rack debe quedar por debajo del mínimo. Si sale alguno, es uno que
--    el bloque F no pudo ampliar (lo dijo con un warning) y hay que dividirlo.
select code, niveles
  from public.racks
 where niveles < public.fn_niveles_infantiles() + 1
 order by code;

-- 3. Mercadería que quedó fuera de sitio. La migración NO la movió a propósito:
--    cambiarla de posición en la base no la mueve del estante. Estas son las
--    cajas que hay que bajar o subir físicamente y reubicar después en el
--    sistema. Sin filas, no hay nada pendiente.
select
  w.code      as almacen,
  r.code      as rack,
  pos.code    as posicion,
  pos.level   as nivel,
  pr.audience as publico,
  it.sku,
  pa.quantity as unidades
from public.position_assignments pa
join public.positions       pos on pos.id = pa.position_id
join public.racks           r   on r.id   = pos.rack_id
join public.warehouses      w   on w.id   = r.warehouse_id
join public.inventory_items it  on it.id  = pa.item_id
join public.products        pr  on pr.id  = it.product_id
where pa.status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
  and (
    (pr.audience = 'NINO'   and pos.level >  public.fn_niveles_infantiles())
 or (pr.audience = 'ADULTO' and pos.level <= public.fn_niveles_infantiles())
  )
order by w.code, r.code, pos.code;
