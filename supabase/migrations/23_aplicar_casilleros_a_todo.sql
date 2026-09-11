-- =============================================================================
--  MIGRACIÓN 23 — TODOS LOS RACKS CON CASILLEROS A MEDIDA
--
--  La migración 21 dejó la regla lista pero sin aplicar: cada rack seguía con
--  los casilleros del seed hasta que alguien apretara "Aplicar niveles y
--  casilleros" en el editor, uno por uno. Hay racks con UN casillero de 14 m
--  por nivel, donde un solo modelo ocupa el estante entero. Esto los ajusta
--  todos de una vez y reparte lo que quede sobrecargado.
--
--  Qué significa en el almacén: ajustar un rack es poner separadores y
--  etiquetas nuevas en sus estantes. Los casilleros que ya tenían cajas se
--  quedan (su código está en el kardex) pero pasan a medir lo que mide uno
--  nuevo; las cajas que ya no entran en ellos son las que físicamente quedan
--  del otro lado del separador, y se anotan en los casilleros vecinos del
--  mismo rack. Por eso se reparte primero dentro del mismo rack.
--
--  Tres cosas que había que corregir para poder hacerlo desde el SQL Editor,
--  donde no hay ningún usuario con sesión:
--    - fn_colocar anotaba quién ubicó con actor_actual(), que lanza error sin
--      sesión. Ahora usa fn_usuario_actual() —la misma que usa la auditoría—:
--      desde la app guarda al usuario, desde acá deja null.
--    - repartir_sobrecarga exige rol, y sin sesión no hay rol. Se separa en
--      una función interna sin rol (bloqueada para la API) y la RPC de
--      siempre, que pide rol y llama a la interna.
--    - fn_ajustar_casilleros buscaba el primer código libre revisando los 999
--      posibles por cada casillero que agregaba: unas 2,8 millones de
--      consultas para todo el almacén. Ahora carga los códigos usados una vez.
--
--  Requiere 01-22. Idempotente: correrla de nuevo no cambia nada, salvo que
--  el stock haya cambiado lo que ocupa un modelo típico.
-- =============================================================================


-- =============================================================================
--  BLOQUE A — fn_colocar ANOTA AL USUARIO SI LO HAY
-- =============================================================================
-- Idéntica a la de la migración 21 salvo por assigned_by.
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
      values (v_destino.id, p_item_id, v_cuanto, coalesce(p_status, 'OCUPADA'),
              public.fn_usuario_actual(), p_nota);
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
--  BLOQUE B — REPARTIR: LA LÓGICA SIN ROL, LA RPC CON ROL
-- =============================================================================
create or replace function public.fn_repartir_sobrecarga(p_position_id uuid)
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

  -- Se saca de la talla con más cajas: es la que más fácil encuentra sitio.
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

revoke execute on function public.fn_repartir_sobrecarga(uuid) from public, anon, authenticated;

create or replace function public.repartir_sobrecarga(p_position_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
begin
  perform public.fn_exigir_rol('OPERARIO', 'SUPERVISOR', 'JEFE');
  return public.fn_repartir_sobrecarga(p_position_id);
end;
$fn$;

grant execute on function public.repartir_sobrecarga(uuid) to authenticated;


-- =============================================================================
--  BLOQUE C — AJUSTAR UN RACK SIN RECORRER 999 CÓDIGOS POR CASILLERO
-- =============================================================================
-- Igual que en la migración 21 salvo por cómo se elige el código nuevo: los
-- números ya usados se cargan una vez y se avanza sobre ellos. Sigue sin
-- renumerar nada; los códigos que se liberan en esta misma pasada no se
-- reusan hasta la próxima, lo cual no molesta a nadie.
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
  v_idx      integer := 0;
  v_usados   integer[];
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

  -- El último tramo del código es el número del casillero dentro del rack.
  select coalesce(array_agg(split_part(code, '-', 3)::integer), '{}')
    into v_usados
    from public.positions where rack_id = p_rack_id;

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
      v_idx := v_idx + 1;
      while v_idx = any(v_usados) loop
        v_idx := v_idx + 1;
      end loop;
      if v_idx > 999 then
        raise exception 'El rack % ya usó los 999 códigos de posición disponibles.', v_donde;
      end if;

      insert into public.positions (rack_id, code, capacity_units, level, slot)
      values (p_rack_id,
              v_letra || '-' || v_num || '-' || lpad(v_idx::text, greatest(2, length(v_idx::text)), '0'),
              0, v_nivel, v_hay + 1);
      v_usados := v_usados || v_idx;
      v_hay    := v_hay + 1;
    end loop;

    v_detalle := v_detalle || jsonb_build_object(
      'nivel', v_nivel, 'casilleros', v_hay, 'sugeridos', v_quiero, 'trabados', v_trabados);
  end loop;

  update public.racks set niveles = p_niveles, updated_at = now() where id = p_rack_id;
  perform public.fn_recalcular_capacidades(p_rack_id);
  return v_detalle;
end;
$fn$;

revoke execute on function public.fn_ajustar_casilleros(uuid, integer) from public, anon, authenticated;


-- =============================================================================
--  BLOQUE D — AJUSTAR TODOS LOS RACKS Y REPARTIR LO QUE SOBRE
-- =============================================================================
-- Interna: se corre desde el SQL Editor. p_warehouse_id NULL = todos los
-- almacenes. Primero ajusta todos los racks y recién después reparte, porque
-- un sobrante puede ir a un casillero que el ajuste de otro rack acaba de crear.
-- Un casillero que no se pueda repartir no frena a los demás: queda en la
-- respuesta con su motivo.
create or replace function public.fn_ajustar_todo(p_warehouse_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  r          record;
  v_det      jsonb;
  v_racks    integer := 0;
  v_trabados integer := 0;
  v_antes    integer;
  v_despues  integer;
  v_reparts  integer := 0;
  v_fallas   jsonb   := '[]'::jsonb;
begin
  select count(*) into v_antes
    from public.positions p join public.racks rk on rk.id = p.rack_id
   where p_warehouse_id is null or rk.warehouse_id = p_warehouse_id;

  for r in
    select id, niveles from public.racks
     where p_warehouse_id is null or warehouse_id = p_warehouse_id
     order by warehouse_id, code
  loop
    v_det := public.fn_ajustar_casilleros(r.id, r.niveles);
    v_trabados := v_trabados + coalesce((select sum((e->>'trabados')::integer) from jsonb_array_elements(v_det) e), 0);
    v_racks := v_racks + 1;
  end loop;

  for r in
    select pos.id, w.code || ' · ' || rk.code || ' ' || pos.code as donde
      from public.positions pos
      join public.racks      rk on rk.id = pos.rack_id
      join public.warehouses w  on w.id  = rk.warehouse_id
      join public.position_assignments pa
        on pa.position_id = pos.id and pa.status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
     where p_warehouse_id is null or rk.warehouse_id = p_warehouse_id
     group by pos.id, w.code, rk.code, pos.code, pos.capacity_units
    having sum(pa.quantity) > pos.capacity_units
  loop
    begin
      perform public.fn_repartir_sobrecarga(r.id);
      v_reparts := v_reparts + 1;
    exception when others then
      v_fallas := v_fallas || jsonb_build_object('casillero', r.donde, 'motivo', sqlerrm);
    end;
  end loop;

  select count(*) into v_despues
    from public.positions p join public.racks rk on rk.id = p.rack_id
   where p_warehouse_id is null or rk.warehouse_id = p_warehouse_id;

  return jsonb_build_object(
    'racks',                   v_racks,
    'casilleros_antes',        v_antes,
    'casilleros_despues',      v_despues,
    'con_historia_sin_quitar', v_trabados,
    'sobrecargas_repartidas',  v_reparts,
    'sin_repartir',            v_fallas);
end;
$fn$;

revoke execute on function public.fn_ajustar_todo(uuid) from public, anon, authenticated;


-- =============================================================================
--  BLOQUE E — APLICARLO A TODOS LOS RACKS
-- =============================================================================
-- El resumen viaja en una variable de sesión y no en una tabla: una tabla,
-- aunque sea temporal, dispara el aviso de "tabla sin RLS" del SQL Editor, y
-- no hace falta ninguna para mostrar una sola fila.
do $bloque$
begin
  perform set_config('ajuste.resumen', public.fn_ajustar_todo(null)::text, false);
end;
$bloque$;


-- =============================================================================
--  RESULTADO (una sola fila: el SQL Editor solo muestra la última consulta)
-- =============================================================================
-- Esperado: niveles_sin_ajustar 0 (o solo los que tienen casilleros con
-- historia que no se pudieron quitar), sobrecargados 0, pendientes_revision 0,
-- y pares_en_stock = pares_en_estantes.
select
  (a.resumen->>'racks')::integer                      as racks_ajustados,
  (a.resumen->>'casilleros_antes')::integer           as casilleros_antes,
  (a.resumen->>'casilleros_despues')::integer         as casilleros_despues,
  (a.resumen->>'sobrecargas_repartidas')::integer     as sobrecargas_repartidas,
  jsonb_array_length(a.resumen->'sin_repartir')       as sin_repartir,
  (a.resumen->>'con_historia_sin_quitar')::integer    as con_historia_sin_quitar,
  (select count(*)
     from public.racks rk
     cross join lateral generate_series(1, rk.niveles) as n(nivel)
    where (select count(*) from public.positions p where p.rack_id = rk.id and p.level = n.nivel)
          <> public.fn_casilleros_para(greatest(rk.grid_ancho, rk.grid_alto), least(rk.grid_ancho, rk.grid_alto), n.nivel)
  )                                                   as niveles_sin_ajustar,
  (select count(*) from (
     select pos.id
       from public.positions pos
       join public.position_assignments pa
         on pa.position_id = pos.id and pa.status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
      group by pos.id, pos.capacity_units
     having sum(pa.quantity) > pos.capacity_units) x) as sobrecargados,
  (select count(*) from public.v_revision_ubicaciones) as pendientes_revision,
  (select coalesce(sum(quantity), 0) from public.inventory) as pares_en_stock,
  (select coalesce(sum(quantity), 0) from public.position_assignments
    where status in ('OCUPADA', 'EN_PICKING'))        as pares_en_estantes,
  a.resumen->'sin_repartir'                           as detalle_sin_repartir
from (select current_setting('ajuste.resumen', true)::jsonb as resumen) a;
