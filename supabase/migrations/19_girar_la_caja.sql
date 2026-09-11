-- =============================================================================
--  MIGRACIÓN 19 — LA CAJA SE PUEDE GIRAR
--
--  fn_cajas_en_slot probaba la caja en una sola orientación: el lado largo
--  siempre contra el frente del casillero y el ancho hacia el fondo. Nadie
--  acomoda un estante así. Girarla 90 grados es lo primero que hace cualquiera
--  cuando no entra, y para un casillero angosto es la diferencia entre guardar
--  algo y no guardar nada:
--
--    ALM-04/RACK-01 es un rack de 2 x 2 m con 7 casilleros, o sea 29 cm de
--    frente cada uno. Una caja de adulto de 35 cm no entra a lo largo — el
--    cálculo daba 0 y el nivel de adulto quedaba inservible. De lado ocupa
--    25 cm de frente y 35 de fondo: entran 12.
--
--    En los RACK-07 (56 cm de frente) pasa de 20 a 25 cajas: a lo largo entra
--    una sola por fila, de lado entran dos.
--
--  Donde el frente es holgado (1,4 m o más) no cambia nada: las dos
--  orientaciones dan el mismo resultado y la que sobra se descarta sola.
--
--  Lo que NO se contempla es poner la caja de canto, apoyada en un costado.
--  Cabría más en algunos casos, pero apilar calzado sobre el lateral de la caja
--  lo deforma, y una capacidad que solo se alcanza maltratando la mercadería no
--  es capacidad.
--
--  Requiere 01-18. Idempotente.
-- =============================================================================


-- =============================================================================
--  BLOQUE A — PROBAR LAS DOS ORIENTACIONES Y QUEDARSE CON LA MEJOR
-- =============================================================================
-- La caja siempre apoya sobre su base (el alto es siempre el alto); lo que rota
-- es el rectángulo de abajo. Son dos formas de poner la misma caja en el mismo
-- estante, así que se calcula cuántas entran de cada una y gana la mayor.
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
  with caja as (
    select
      case when p_nivel <= public.fn_niveles_infantiles() then 0.22 else 0.35 end as largo,
      case when p_nivel <= public.fn_niveles_infantiles() then 0.15 else 0.25 end as ancho,
      case when p_nivel <= public.fn_niveles_infantiles() then 0.09 else 0.13 end as alto
  ),
  -- Las dos formas de apoyarla: a lo largo del frente, o girada 90 grados.
  orientaciones as (
    select largo as x, ancho as y, alto from caja
    union all
    select ancho as x, largo as y, alto from caja
  ),
  cuentan as (
    select floor(p_frente_m / x) * floor(p_fondo_m / y) * floor(0.45 / alto) as cajas
      from orientaciones
  )
  select greatest(0, floor(max(cajas) * 0.85)::integer) from cuentan;
$fn$;

comment on function public.fn_cajas_en_slot is
  'Cajas que entran en un casillero de p_frente_m x p_fondo_m según su nivel, probando la caja en sus dos orientaciones horizontales. Infantil 22x15x9 cm en los niveles bajos; adulto 35x25x13 (caja de hombre, la mayor) del resto. 45 cm de luz entre estantes y 15% de holgura de maniobra.';


-- =============================================================================
--  BLOQUE B — VOLVER A MEDIR TODO LO YA DECLARADO
-- =============================================================================
-- Las capacidades vigentes se calcularon sin girar la caja: las de casillero
-- angosto están subestimadas, y una de ellas en 0. fn_recalcular_capacidades
-- nunca declara menos de lo que la posición ya tiene adentro.
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
-- 1. Un casillero angosto ya no da 0. Con 29 cm de frente y 2 m de fondo, una
--    caja de adulto solo entra girada.
select
  '29 cm de frente (ALM-04/RACK-01)' as caso,
  public.fn_cajas_en_slot(0.29, 2, 3)  as adulto,
  public.fn_cajas_en_slot(0.29, 2, 1)  as infantil
union all
select
  '56 cm de frente (RACK-07)',
  public.fn_cajas_en_slot(0.56, 2, 3),
  public.fn_cajas_en_slot(0.56, 2, 1);
-- Esperado: adulto 12 y 25 (antes 0 y 20).

-- 2. Ningún nivel debería quedar en capacidad 0. Si sale alguno, su casillero
--    es más angosto que la caja incluso girada: hay que darle menos posiciones
--    por nivel a ese rack para que cada una sea más ancha.
select
  w.code           as almacen,
  r.code           as rack,
  p.level          as nivel,
  count(*)         as casilleros,
  max(p.capacity_units) as capacidad
from public.positions p
join public.racks      r on r.id = p.rack_id
join public.warehouses w on w.id = r.warehouse_id
where p.capacity_units = 0
group by w.code, r.code, p.level
order by w.code, r.code, p.level;
