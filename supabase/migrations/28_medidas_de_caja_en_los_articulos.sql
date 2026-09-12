-- =============================================================================
--  MIGRACIÓN 28 — LAS MEDIDAS DE LA CAJA, EN LOS ARTÍCULOS QUE YA EXISTÍAN
--
--  Los 80 artículos se cargaron antes de que el formulario propusiera la caja
--  estándar, así que tienen peso, largo, ancho y alto en NULL: al editarlos,
--  esos cuatro campos salían vacíos. El README los pide en el formulario de
--  edición, y el valor del inventario y la capacidad de los casilleros se
--  razonan sobre esas medidas, así que no deberían quedar sin llenar.
--
--  Las medidas son las de LA CAJA, no las del zapato: es lo que ocupa sitio en
--  el estante, y es lo que ya usa el cálculo de capacidad.
--
--  Se leen de fn_medidas_caja para que no puedan desincronizarse del cálculo
--  de casilleros: esa función las da en metros y por nivel, así que se pide la
--  del primer nivel (infantil) y la del primero que no lo es (adulto), y se
--  pasan a centímetros, que es la unidad de estas columnas.
--
--  Solo rellena lo que falta. Una medida cargada a mano se respeta: puede ser
--  un modelo con caja distinta, y pisarla sería perder el dato.
--
--  Requiere 01-27. Idempotente.
-- =============================================================================

with caja as (
  select 'NINO'::text   as publico,
         public.fn_medidas_caja(1) as m,
         0.600::numeric            as kg
  union all
  select 'ADULTO',
         public.fn_medidas_caja(public.fn_niveles_infantiles() + 1),
         0.900::numeric
)
update public.inventory_items it
   set length = coalesce(it.length, round(caja.m[1] * 100, 2)),
       width  = coalesce(it.width,  round(caja.m[2] * 100, 2)),
       height = coalesce(it.height, round(caja.m[3] * 100, 2)),
       weight = coalesce(it.weight, caja.kg),
       updated_at = now()
  from caja
 where caja.publico = it.audience
   and (it.length is null or it.width is null or it.height is null or it.weight is null);


comment on column public.inventory_items.weight is
  'Peso de la caja en kilos. Lo propone el formulario según el público; se puede corregir.';
comment on column public.inventory_items.length is
  'Largo de la CAJA en centímetros (no del zapato): es lo que ocupa en el estante. Infantil 22, adulto 35.';
comment on column public.inventory_items.width is
  'Ancho de la CAJA en centímetros. Infantil 15, adulto 25.';
comment on column public.inventory_items.height is
  'Alto de la CAJA en centímetros. Infantil 9, adulto 13.';


-- Qué quedó. Si "sin_medidas" no es 0, hay artículos con un audience que esta
-- migración no contempla y habría que mirarlos uno a uno.
do $$
declare
  v_sin  integer;
  v_nino integer;
  v_adu  integer;
begin
  select count(*) filter (where length is null or width is null or height is null or weight is null),
         count(*) filter (where audience = 'NINO'),
         count(*) filter (where audience = 'ADULTO')
    into v_sin, v_nino, v_adu
    from public.inventory_items
   where deleted_at is null;

  raise notice 'Artículos vivos: % infantiles, % de adulto. Sin medidas: %.', v_nino, v_adu, v_sin;
end;
$$;
