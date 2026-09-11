-- =============================================================================
--  MIGRACIÓN 22 — LA ESTIMACIÓN DICE CÓMO LLEGÓ A SU NÚMERO
--
--  El editor mostraba "n1: 93 de 15 cm" sin decir por qué 93. La regla es la
--  misma para todos los niveles —un casillero mide lo que ocupa un modelo—,
--  pero con datos distintos: los niveles infantiles usan la caja de niño y lo
--  que ocupa un modelo infantil; los de adulto, la caja de hombre y lo que
--  ocupa un modelo de adulto. Ahora la estimación devuelve también qué caja y
--  qué objetivo usó cada nivel, para que la pantalla lo diga.
--
--  Solo redefine estimar_capacidad_rack: misma firma, más datos por nivel.
--  Requiere 01-21. Idempotente.
-- =============================================================================
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
  v_frente   numeric := greatest(p_grid_ancho, p_grid_alto);
  v_fondo    numeric := least(p_grid_ancho, p_grid_alto);
  v_n        integer;
  v_cap      integer;
  v_caja     numeric[];
  v_infantil boolean;
  v_pos      integer := 0;
  v_cajas    integer := 0;
  v_por      jsonb   := '[]'::jsonb;
  v_nivel    integer;
begin
  for v_nivel in 1..greatest(p_niveles, 1) loop
    v_infantil := v_nivel <= public.fn_niveles_infantiles();
    v_caja     := public.fn_medidas_caja(v_nivel);
    v_n        := coalesce(nullif(p_slots_por_nivel, 0), public.fn_casilleros_para(v_frente, v_fondo, v_nivel));
    v_cap      := public.fn_cajas_en_slot(v_frente / v_n, v_fondo, v_nivel);
    v_pos      := v_pos + v_n;
    v_cajas    := v_cajas + v_cap * v_n;
    v_por      := v_por || jsonb_build_object(
      'nivel',               v_nivel,
      'publico',             case when v_infantil then 'niño' else 'adulto' end,
      'caja_cm',             round(v_caja[1] * 100) || '×' || round(v_caja[2] * 100) || '×' || round(v_caja[3] * 100),
      'objetivo',            public.fn_cajas_por_modelo(v_infantil),
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
--  VERIFICACIÓN
-- =============================================================================
-- Un rack de 14 x 2 m con 3 niveles: los dos infantiles y el de adulto salen
-- distintos porque usan caja y objetivo distintos.
select n->>'nivel' as nivel, n->>'publico' as publico, n->>'caja_cm' as caja_cm,
       n->>'objetivo' as un_modelo_ocupa, n->>'casilleros' as casilleros,
       n->>'ancho_cm' as ancho_cm, n->>'cajas_por_casillero' as cajas_c_u
  from jsonb_array_elements(public.estimar_capacidad_rack(14, 2, 3, null)->'por_nivel') as n;
