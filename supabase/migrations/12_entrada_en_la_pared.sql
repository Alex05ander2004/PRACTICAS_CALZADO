-- =============================================================================
--  MIGRACIÓN 12 — LA ENTRADA VIVE EN UNA PARED
--
--  La entrada del almacén era un punto fijo que nadie podía mover: la
--  migración 09 la escribió en (20, 28) para los tres almacenes y ahí se quedó.
--  Peor: (20, 28) en un plano de 40 x 30 no está ni sobre la pared — está una
--  celda adentro, flotando en medio del pasillo perimetral. Una puerta que no
--  toca ninguna pared no es una puerta.
--
--  Dos cosas, entonces:
--    1. La entrada se puede mover, pero SOLO sobre el perímetro. La regla se
--       aplica acá y no en el editor, igual que la geometría de los racks.
--    2. La orientación NO se guarda. Que la entrada esté "vertical" es una
--       consecuencia de estar en la pared izquierda o derecha, no un dato
--       aparte que se pueda desincronizar — mismo criterio que el giro de un
--       rack, que es su ancho y su largo intercambiados y no una columna
--       "orientación".
--
--  Requiere 01-11. Idempotente.
-- =============================================================================


-- =============================================================================
--  BLOQUE A — PEGAR UN PUNTO A LA PARED MÁS CERCANA
-- =============================================================================
-- Se usa en los dos lados: al mover la entrada a mano y al redimensionar el
-- almacén (si el plano crece, la pared se aleja y la puerta se quedaría
-- flotando adentro). Devuelve [x, y] ya recortado al plano.
create or replace function public.fn_pegar_a_pared(
  p_x     integer,
  p_y     integer,
  p_ancho integer,
  p_alto  integer
)
returns integer[]
language sql
immutable
as $fn$
  with punto as (
    select least(greatest(p_x, 0), p_ancho - 1) as x,
           least(greatest(p_y, 0), p_alto  - 1) as y
  ),
  distancias as (
    select x, y,
           x                as izquierda,
           p_ancho - 1 - x  as derecha,
           y                as arriba,
           p_alto  - 1 - y  as abajo
      from punto
  )
  select case
           when izquierda <= least(derecha, arriba, abajo) then array[0, y]
           when derecha   <= least(arriba, abajo)          then array[p_ancho - 1, y]
           when arriba    <= abajo                         then array[x, 0]
           else                                                 array[x, p_alto - 1]
         end
    from distancias;
$fn$;

comment on function public.fn_pegar_a_pared is
  'Lleva un punto a la pared más cercana del plano. La entrada del almacén siempre pasa por acá: una puerta en medio del piso no existe.';


-- =============================================================================
--  BLOQUE B — LAS ENTRADAS QUE YA ESTABAN, A LA PARED
-- =============================================================================
-- El CHECK del perímetro no se puede agregar antes de esto: las tres entradas
-- que escribió la migración 09 lo violarían y la migración abortaría.
alter table public.warehouses drop constraint if exists ck_warehouses_grilla;

update public.warehouses
   set entrada_x = (public.fn_pegar_a_pared(entrada_x, entrada_y, grid_ancho, grid_alto))[1],
       entrada_y = (public.fn_pegar_a_pared(entrada_x, entrada_y, grid_ancho, grid_alto))[2];

alter table public.warehouses
  add constraint ck_warehouses_grilla check (
    grid_ancho between 10 and 80
    and grid_alto between 10 and 80
    and entrada_x >= 0 and entrada_x < grid_ancho
    and entrada_y >= 0 and entrada_y < grid_alto
    -- Sobre el perímetro: al menos una coordenada tocando un borde.
    and (entrada_x = 0 or entrada_x = grid_ancho - 1
      or entrada_y = 0 or entrada_y = grid_alto - 1)
  );


-- =============================================================================
--  BLOQUE C — MOVER LA ENTRADA
-- =============================================================================
create or replace function public.mover_entrada_almacen(
  p_warehouse_code text,
  p_x              integer,
  p_y              integer
)
returns public.warehouses
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_wh     public.warehouses;
  v_punto  integer[];
  v_tapada text;
begin
  perform public.fn_exigir_rol('SUPERVISOR', 'JEFE');

  select * into v_wh from public.warehouses where code = p_warehouse_code;
  if v_wh.id is null then
    raise exception 'No existe el almacén %.', p_warehouse_code;
  end if;

  -- No se exige que el punto llegue exacto: se lleva a la pared más cercana.
  -- Así el editor puede soltar la puerta "cerca" del borde y la base decide.
  v_punto := public.fn_pegar_a_pared(p_x, p_y, v_wh.grid_ancho, v_wh.grid_alto);

  select code into v_tapada
    from public.racks
   where warehouse_id = v_wh.id
     and v_punto[1] >= grid_x and v_punto[1] < grid_x + grid_ancho
     and v_punto[2] >= grid_y and v_punto[2] < grid_y + grid_alto
   limit 1;

  if v_tapada is not null then
    raise exception 'Ahí no se puede: el rack % está contra esa pared y taparía la puerta.', v_tapada;
  end if;

  update public.warehouses
     set entrada_x  = v_punto[1],
         entrada_y  = v_punto[2],
         updated_at = now()
   where id = v_wh.id
  returning * into v_wh;

  return v_wh;
end;
$fn$;

grant execute on function public.mover_entrada_almacen(text, integer, integer) to authenticated;


-- =============================================================================
--  BLOQUE D — REDIMENSIONAR TAMBIÉN REACOMODA LA PUERTA
-- =============================================================================
-- La versión de la migración 11 recortaba la entrada con least(). Eso alcanza
-- cuando el plano se achica, pero si CRECE la pared se aleja y la puerta queda
-- flotando en medio del piso. Ahora se vuelve a pegar a la pared más cercana.
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
  v_punto  integer[];
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
  v_punto := public.fn_pegar_a_pared(v_wh.entrada_x, v_wh.entrada_y, p_grid_ancho, p_grid_alto);

  update public.warehouses
     set grid_ancho = p_grid_ancho,
         grid_alto  = p_grid_alto,
         entrada_x  = v_punto[1],
         entrada_y  = v_punto[2],
         updated_at = now()
   where id = v_wh.id
  returning * into v_wh;

  return v_wh;
end;
$fn$;


-- =============================================================================
--  VERIFICACIÓN
-- =============================================================================
select
  code                                     as almacen,
  grid_ancho || ' x ' || grid_alto         as plano,
  entrada_x || ',' || entrada_y            as entrada,
  case
    when entrada_x = 0                then 'pared izquierda (vertical)'
    when entrada_x = grid_ancho - 1   then 'pared derecha (vertical)'
    when entrada_y = 0                then 'pared superior (horizontal)'
    when entrada_y = grid_alto - 1    then 'pared inferior (horizontal)'
  end                                      as pared
from public.warehouses
order by code;
-- Esperado: ninguna fila con pared NULL — todas las entradas tocan un borde.
