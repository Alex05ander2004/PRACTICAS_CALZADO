-- =============================================================================
--  MIGRACIÓN 27 — EL PÚBLICO Y EL PROVEEDOR PASAN A SER DE CADA TALLA
--
--  Dos cosas que el formulario no dejaba hacer, y las dos por el mismo motivo:
--  vivían en `products` (el modelo) cuando en realidad son de cada artículo.
--
--  1. EL PROVEEDOR. El README lo pone en inventory_items; el esquema lo había
--     puesto en products. Consecuencia: el mismo par comprado a otro proveedor
--     no se podía dar de alta, porque habría que duplicar el modelo entero.
--     Ahora `inventory_items.supplier_id` manda, y el del modelo queda como
--     sugerencia para las tallas nuevas.
--
--  2. EL PÚBLICO. Estaba en products, así que un modelo era entero de niño o
--     entero de adulto, y el selector tenía que ir bloqueado. Pero el público
--     es de la talla: la caja de una 30 es infantil vaya en el modelo que
--     vaya, y es lo que decide en qué nivel del rack puede ir.
--
--  Nada se mueve de sitio. Las dos columnas se rellenan con el valor del
--  modelo, así que los 80 artículos quedan exactamente como estaban, y como
--  hoy ningún modelo mezcla públicos, el tamaño de casillero que calcula
--  fn_cajas_por_modelo da el mismo resultado que antes: no hay que volver a
--  ajustar los racks.
--
--  Los objetos que leían products.audience se vuelven a crear leyendo el del
--  artículo. Son los que sostienen la ubicación de los 2376 pares, así que van
--  copiados de su definición vigente con el cambio justo, no reescritos.
--
--  Requiere 01-26. Idempotente.
-- =============================================================================


-- =============================================================================
--  BLOQUE A — LAS COLUMNAS NUEVAS
-- =============================================================================

-- Un código corto por proveedor, para poder distinguir en el SKU el mismo par
-- comprado a dos sitios: ZAP-030-41 e ZAP-030-41-SPO.
alter table public.suppliers add column if not exists code text;

update public.suppliers
   set code = upper(substring(regexp_replace(slug, '[^a-z0-9]', '', 'g') from 1 for 3))
 where code is null;

alter table public.suppliers drop constraint if exists ck_suppliers_code;
alter table public.suppliers
  add constraint ck_suppliers_code check (code is null or code ~ '^[A-Z0-9]{2,6}$');

create unique index if not exists ux_suppliers_code on public.suppliers (code);

comment on column public.suppliers.code is
  'Código corto para el SKU cuando el mismo modelo y talla vienen de más de un proveedor.';


-- El proveedor del artículo. NULL significa "el que tenga el modelo": no se
-- fuerza, porque products.supplier_id puede quedar en NULL al borrar uno.
alter table public.inventory_items
  add column if not exists supplier_id uuid references public.suppliers (id) on delete set null;

update public.inventory_items it
   set supplier_id = pr.supplier_id
  from public.products pr
 where pr.id = it.product_id
   and it.supplier_id is null;

comment on column public.inventory_items.supplier_id is
  'A quién se le compra ESTA talla. El mismo modelo puede venir de varios proveedores, cada uno con su SKU.';


-- El público del artículo. Es lo que decide el tamaño de la caja y el nivel
-- del rack, así que va aquí y no en el modelo.
alter table public.inventory_items add column if not exists audience text;

update public.inventory_items it
   set audience = case when pr.audience = 'NINO' then 'NINO' else 'ADULTO' end
  from public.products pr
 where pr.id = it.product_id
   and it.audience is null;

alter table public.inventory_items alter column audience set default 'ADULTO';
alter table public.inventory_items alter column audience set not null;

alter table public.inventory_items drop constraint if exists ck_items_audience;
alter table public.inventory_items
  add constraint ck_items_audience check (audience in ('ADULTO', 'NINO'));

comment on column public.inventory_items.audience is
  'Niño o adulto, POR TALLA. Decide el tamaño de caja (fn_medidas_caja) y en qué nivel del rack puede ubicarse.';


-- Con el proveedor en el artículo, "el mismo modelo y talla" deja de ser
-- duplicado si viene de otro proveedor. Va como índice y no como constraint
-- porque un supplier_id en NULL no chocaría con nada: dos filas sin proveedor
-- del mismo modelo y talla seguirían siendo el duplicado que se quiere evitar.
alter table public.inventory_items drop constraint if exists uq_items_product_size;
drop index if exists public.uq_items_product_size;

create unique index if not exists ux_items_product_size_supplier
  on public.inventory_items (
    product_id, size_label, size_system,
    coalesce(supplier_id, '00000000-0000-0000-0000-000000000000'::uuid)
  );

comment on index public.ux_items_product_size_supplier is
  'Impide repetir la misma talla del mismo modelo y proveedor. Con otro proveedor sí se permite: es otro artículo, con su propio SKU.';


-- =============================================================================
--  BLOQUE B — LOS OBJETOS QUE LEÍAN EL PÚBLICO DEL MODELO
--
--  Copiados de su definición vigente (migraciones 17, 20, 21 y 23) cambiando
--  únicamente de dónde sale el público.
-- =============================================================================

-- El trigger que impide dejar una caja en un nivel que no le corresponde.

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
  if new.status = 'LIBERADA' then
    return new;
  end if;

  if tg_op = 'UPDATE'
     and new.position_id = old.position_id
     and new.item_id     = old.item_id
     and new.quantity   <= old.quantity then
    return new;
  end if;

  select it.audience into v_audience
    from public.inventory_items it
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

  return new;
end;
$fn$;

-- El mapa del almacén.

create or replace view public.v_mapa_almacen as
select
  pos.id            as position_id,
  w.code            as almacen_code,
  w.name            as almacen,
  r.code            as rack,
  pos.code          as posicion,
  pos.level,
  pos.capacity_units,
  pa.id             as assignment_id,
  pa.status         as estado_ocupacion,   -- NULL = libre
  pa.quantity       as unidades,
  pa.item_id,
  it.sku,
  pr.name           as producto,
  it.size_label     as talla,
  it.audience,
  pa.assigned_at,
  it.product_id,
  pr.model_code
from public.positions pos
join public.racks      r on r.id = pos.rack_id
join public.warehouses w on w.id = r.warehouse_id
left join public.position_assignments pa
       on pa.position_id = pos.id
      and pa.status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
left join public.inventory_items it on it.id = pa.item_id
left join public.products        pr on pr.id = it.product_id;

alter view public.v_mapa_almacen set (security_invoker = on);

-- Lo que quedó en un nivel que su público ya no admite.

create or replace view public.v_reubicaciones_pendientes as
select
  pa.id                       as assignment_id,
  pa.quantity                 as unidades,
  pa.status,
  it.id                       as item_id,
  it.sku,
  pr.name                     as producto,
  it.size_label               as talla,
  it.audience                 as publico,
  w.code                      as almacen_code,
  w.name                      as almacen,
  r.id                        as rack_id,
  r.code                      as rack,
  pos.id                      as position_id,
  pos.code                    as posicion,
  pos.level                   as nivel,
  case when it.audience = 'NINO' then 1 else public.fn_niveles_infantiles() + 1 end
                              as nivel_sugerido
from public.position_assignments pa
join public.positions       pos on pos.id = pa.position_id
join public.racks           r   on r.id   = pos.rack_id
join public.warehouses      w   on w.id   = r.warehouse_id
join public.inventory_items it  on it.id  = pa.item_id
join public.products        pr  on pr.id  = it.product_id
where pa.status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
  and (
    (it.audience = 'NINO'   and pos.level >  public.fn_niveles_infantiles())
 or (it.audience = 'ADULTO' and pos.level <= public.fn_niveles_infantiles())
  );

alter view public.v_reubicaciones_pendientes set (security_invoker = on);

-- Mover una asignación a otro casillero.

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
  v_asg      public.position_assignments;
  v_origen   public.positions;
  v_rack     text;
  v_destino  record;
  v_tope     integer := public.fn_niveles_infantiles();
  v_publico  text;
  v_modelo   uuid;
  v_restante integer;
  v_cuanto   integer;
  v_usadas   integer := 0;
  v_donde    text := '';
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
  -- Con el almacén delante: los códigos de rack se repiten entre almacenes.
  select w.code || ' · ' || r.code into v_rack
    from public.racks r
    join public.warehouses w on w.id = r.warehouse_id
   where r.id = v_origen.rack_id;

  select it.audience, it.product_id into v_publico, v_modelo
    from public.inventory_items it
   where it.id = v_asg.item_id;

  -- Se libera primero; si algo falla más abajo, la excepción revierte también
  -- esto. La caja nunca queda en el limbo.
  update public.position_assignments
     set status = 'LIBERADA', released_at = now(), updated_at = now()
   where id = p_assignment_id;

  v_restante := v_asg.quantity;

  for v_destino in
    select p.id, p.code, p.level, p.slot,
           p.capacity_units - coalesce(oc.ocupado, 0) as libre,
           coalesce(oc.misma_talla, false)            as misma_talla,
           oc.ocupado is not null                     as mismo_modelo
      from public.positions p
      left join lateral (
        select sum(a.quantity)                    as ocupado,
               bool_or(a.item_id = v_asg.item_id) as misma_talla,
               bool_or(it.product_id <> v_modelo) as otro_modelo
          from public.position_assignments a
          join public.inventory_items it on it.id = a.item_id
         where a.position_id = p.id
           and a.status in ('RESERVADA', 'OCUPADA', 'EN_PICKING')
      ) oc on true
     where (p_position_id is null or p.id = p_position_id)
       and (p_position_id is not null or p.rack_id = v_origen.rack_id)
       and p.id <> v_origen.id
       and p.is_active
       and case when v_publico = 'NINO'   then p.level <= v_tope
                when v_publico = 'ADULTO' then p.level >  v_tope
                else true end
       and not coalesce(oc.otro_modelo, false)
       and p.capacity_units - coalesce(oc.ocupado, 0) > 0
     order by misma_talla desc, mismo_modelo desc, libre desc, p.level, p.slot
  loop
    exit when v_restante <= 0;

    v_cuanto := least(v_restante, v_destino.libre);

    update public.position_assignments
       set quantity = quantity + v_cuanto, updated_at = now()
     where position_id = v_destino.id
       and item_id     = v_asg.item_id
       and status in ('RESERVADA', 'OCUPADA', 'EN_PICKING');
    if not found then
      insert into public.position_assignments (position_id, item_id, quantity, status, notes)
      values (v_destino.id, v_asg.item_id, v_cuanto, v_asg.status,
              'Reubicada desde ' || v_origen.code || ' (nivel ' || v_origen.level || ')');
    end if;

    v_restante := v_restante - v_cuanto;
    v_usadas   := v_usadas + 1;
    v_donde    := v_donde || case when v_donde = '' then '' else ', ' end
                          || v_destino.code || ' (' || v_cuanto || ')';
  end loop;

  if v_restante > 0 then
    if v_usadas = 0 then
      raise exception 'En % no queda ningún casillero donde pueda ir este modelo de %: están ocupados por otros modelos, llenos, o son más angostos que la caja.',
        v_rack, lower(coalesce(v_publico, 'ese público'));
    end if;
    raise exception 'En % caben % de las % cajas en los % casilleros con sitio para este modelo. Faltan % — reparte el resto en otro rack.',
      v_rack, v_asg.quantity - v_restante, v_asg.quantity, v_usadas, v_restante;
  end if;

  return jsonb_build_object(
    'estado',     'REUBICADA',
    'casilleros', v_usadas,
    'desde',      v_origen.code,
    'mensaje',    case when v_usadas = 1
                    then 'Movida de ' || v_origen.code || ' a ' || v_donde || '.'
                    else v_asg.quantity || ' cajas de ' || v_origen.code ||
                         ' repartidas en ' || v_usadas || ' casilleros: ' || v_donde || '.'
                  end
  );
end;
$fn$;

-- Buscar hueco y colocar.

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
  select it.audience, it.product_id, it.sku into v_publico, v_modelo, v_sku
    from public.inventory_items it
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

-- El tamaño objetivo de un casillero. Antes agrupaba por modelo y filtraba por
-- el público del modelo; ahora la unidad es "modelo y público", porque un
-- mismo modelo puede tener tallas de niño y de adulto y sus cajas no miden lo
-- mismo. Mientras ningún modelo mezcle públicos el resultado es idéntico.
create or replace function public.fn_cajas_por_modelo(p_infantil boolean)
returns integer
language sql
stable
set search_path = public
as $fn$
  with por_modelo as (
    select it.product_id, it.audience, sum(inv.quantity) as cajas
      from public.inventory_items it
      join public.inventory       inv on inv.item_id = it.id
     where (it.audience = 'NINO') = p_infantil
     group by it.product_id, it.audience
    having sum(inv.quantity) > 0
  )
  select coalesce(
           least(80, greatest(20, round(percentile_cont(0.5) within group (order by cajas))::integer)),
           40)
    from por_modelo;
$fn$;

comment on function public.fn_cajas_por_modelo is
  'Mediana de cajas en stock por modelo y público, acotada entre 20 y 80. Es el tamaño objetivo de un casillero.';


-- =============================================================================
--  BLOQUE C — EL ALTA, CON PROVEEDOR Y PÚBLICO PROPIOS
-- =============================================================================
-- La versión de la migración 26 se retira ANTES de crear la nueva. Si se
-- dejara para después, las dos convivirían un momento y cualquier referencia
-- a la función por su nombre —el comment de aquí abajo, sin ir más lejos— sería
-- ambigua ("function name is not unique"). Además PostgREST no sabría cuál
-- elegir cuando la llamada no trae los parámetros nuevos.
drop function if exists public.crear_articulo_con_inventario(
  uuid, text, text, text, text, numeric, numeric, numeric, numeric, numeric, numeric, integer, integer
);

create or replace function public.crear_articulo_con_inventario(
  p_product_id     uuid,
  p_sku            text,
  p_size_label     text,
  p_warehouse_code text,
  p_size_system    text    default 'EU',
  p_price          numeric default null,
  p_cost           numeric default null,
  p_weight         numeric default null,
  p_length         numeric default null,
  p_width          numeric default null,
  p_height         numeric default null,
  p_min_stock      integer default 0,
  p_max_stock      integer default null,
  p_supplier_id    uuid    default null,
  p_audience       text    default null
)
returns public.inventory_items
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item     public.inventory_items;
  v_wh_id    uuid;
  v_sku      text := upper(btrim(p_sku));
  v_talla    text := btrim(p_size_label);
  v_publico  text;
  v_prov     uuid := p_supplier_id;
begin
  perform public.fn_exigir_rol('SUPERVISOR', 'JEFE');

  -- Sin público explícito se hereda el del modelo; sin proveedor, también.
  select case when coalesce(p_audience, pr.audience) = 'NINO' then 'NINO' else 'ADULTO' end,
         coalesce(v_prov, pr.supplier_id)
    into v_publico, v_prov
    from public.products pr
   where pr.id = p_product_id;

  if v_publico is null then
    raise exception 'No existe el producto indicado.';
  end if;

  select id into v_wh_id from public.warehouses where code = p_warehouse_code;
  if v_wh_id is null then
    raise exception 'No existe el almacén %.', p_warehouse_code;
  end if;

  if p_max_stock is not null and p_max_stock < p_min_stock then
    raise exception 'El stock máximo (%) no puede ser menor que el mínimo (%).', p_max_stock, p_min_stock;
  end if;

  insert into public.inventory_items
    (product_id, sku, size_label, size_system, price, cost, weight, length, width, height,
     supplier_id, audience)
  values
    (p_product_id, v_sku, v_talla, coalesce(p_size_system, 'EU'),
     p_price, p_cost, p_weight, p_length, p_width, p_height,
     v_prov, v_publico)
  returning * into v_item;

  -- La cantidad arranca en 0 siempre: el stock entra por un movimiento de
  -- ENTRADA aprobado, nunca por el alta del catálogo.
  insert into public.inventory (item_id, warehouse_id, quantity, min_stock, max_stock)
  values (v_item.id, v_wh_id, 0, p_min_stock, p_max_stock);

  return v_item;
end;
$$;

grant execute on function public.crear_articulo_con_inventario(
  uuid, text, text, text, text, numeric, numeric, numeric, numeric, numeric, numeric, integer, integer, uuid, text
) to authenticated;

-- Con la lista de argumentos: el nombre solo vuelve a ser ambiguo en cuanto
-- exista una segunda versión.
comment on function public.crear_articulo_con_inventario(
  uuid, text, text, text, text, numeric, numeric, numeric, numeric, numeric, numeric, integer, integer, uuid, text
) is
  'Alta de artículo + su registro de inventario en una sola transacción. El público y el proveedor son de la talla; si no vienen, se heredan del modelo. SUPERVISOR+.';


-- =============================================================================
--  BLOQUE D — UN SKU QUE NO SE ESCRIBE A MANO
--
--  El SKU es el modelo y la talla; cuando esa combinación ya existe para otro
--  proveedor, se le agrega el código del proveedor. Lo arma también el cliente
--  para mostrarlo mientras se escribe, pero la última palabra la tiene esta
--  función: es la que ve todos los artículos, incluidos los que otro usuario
--  acaba de crear.
-- =============================================================================
create or replace function public.fn_sku_sugerido(
  p_product_id  uuid,
  p_size_label  text,
  p_supplier_id uuid default null
)
returns text
language plpgsql
stable
set search_path = public
as $fn$
declare
  v_modelo text;
  v_talla  text := upper(replace(btrim(p_size_label), '.', '-'));
  v_base   text;
  v_cod    text;
  v_sku    text;
  v_n      integer := 2;
begin
  select model_code into v_modelo from public.products where id = p_product_id;
  if v_modelo is null or v_talla = '' then
    return null;
  end if;

  v_base := v_modelo || '-' || v_talla;

  -- Libre: es la primera vez que se carga esta talla de este modelo.
  if not exists (select 1 from public.inventory_items where sku = v_base) then
    return v_base;
  end if;

  -- Ocupado: se distingue por proveedor, que es el motivo por el que puede
  -- repetirse el modelo y la talla.
  select code into v_cod from public.suppliers where id = p_supplier_id;
  if v_cod is not null then
    v_sku := v_base || '-' || v_cod;
    if not exists (select 1 from public.inventory_items where sku = v_sku) then
      return v_sku;
    end if;
  end if;

  -- Sin proveedor o con el código ya usado, un correlativo antes que fallar.
  loop
    v_sku := v_base || '-' || v_n::text;
    exit when not exists (select 1 from public.inventory_items where sku = v_sku);
    v_n := v_n + 1;
  end loop;
  return v_sku;
end;
$fn$;

grant execute on function public.fn_sku_sugerido(uuid, text, uuid) to authenticated;

comment on function public.fn_sku_sugerido is
  'El SKU que le toca a una talla: modelo-talla, más el código del proveedor si esa combinación ya existe.';
