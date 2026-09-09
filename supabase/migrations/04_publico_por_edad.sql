-- =============================================================================
--  MIGRACIÓN 04 — CALZADO INFANTIL EN NIVELES INFERIORES, ADULTO EN SUPERIORES
--
--  Pedido del jefe de almacén: por seguridad y accesibilidad, el calzado de
--  niños debe quedar en los niveles bajos de los racks (a la mano de un niño o
--  de quien lo acompaña) y el de adultos en los niveles altos.
--
--  El esquema base YA tenía el campo `positions.level` pensado para esto
--  (Fase 1: "altura/nivel dentro del rack") pero nunca se usó. Esta migración:
--    1. Agrega `products.audience` (ADULTO/NINO/UNISEX) — el público es un
--       atributo del MODELO, no de la talla: en la práctica una marca saca una
--       línea infantil como producto aparte, no el mismo modelo en talla chica.
--    2. Rellena `positions.level` en lo que ya existe (todo hoy es ADULTO, así
--       que el nivel 2 es seguro para todo lo ya ubicado) y lo vuelve obligatorio.
--    3. Agrega la regla como TRIGGER, no como convención: un INSERT/UPDATE que
--       intente poner un artículo infantil en nivel != 1, o uno de adulto en
--       nivel 1, falla. Mismo patrón que ya usamos para capacidad y para
--       impedir doble ocupación — la garantía vive en la base, no en la UI.
--
--  Requiere 01, 02 y 03. Idempotente.
-- =============================================================================


-- =============================================================================
--  BLOQUE A — PÚBLICO DEL PRODUCTO
-- =============================================================================
alter table public.products
  add column if not exists audience text not null default 'ADULTO';

alter table public.products drop constraint if exists ck_products_audience;
alter table public.products
  add constraint ck_products_audience check (audience in ('ADULTO', 'NINO', 'UNISEX'));

comment on column public.products.audience is
  'A quién está dirigido el modelo. Determina en qué nivel del rack puede ubicarse (ver trg_assign_publico_nivel).';


-- =============================================================================
--  BLOQUE B — NIVEL DE CADA POSICIÓN (obligatorio de aquí en adelante)
-- =============================================================================
-- Todo lo que existe hoy es ADULTO (no hay artículos infantiles todavía), así
-- que retroactivamente es seguro poner nivel 2 (superior) en cualquier
-- posición que no tuviera nivel definido.
update public.positions set level = 2 where level is null;

alter table public.positions alter column level set not null;

comment on column public.positions.level is
  'Nivel físico dentro del rack. Convención del almacén: 1 = inferior (solo calzado infantil), 2+ = superior (adulto/unisex). Obligatorio: una posición sin nivel no se puede usar para asignar stock.';


-- =============================================================================
--  BLOQUE C — LA REGLA, COMO TRIGGER
-- =============================================================================
create or replace function public.fn_validar_publico_por_nivel()
returns trigger
language plpgsql
as $$
declare
  v_audience text;
  v_level    smallint;
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
    -- No debería pasar (level es NOT NULL desde el Bloque B), pero si en el
    -- futuro alguien crea una posición sin nivel, mejor un error claro aquí
    -- que dejar pasar un calzado infantil a un nivel sin validar.
    raise exception 'La posición % no tiene nivel definido.', new.position_id;
  end if;

  if v_audience = 'NINO' and v_level <> 1 then
    raise exception
      'Calzado infantil solo puede ubicarse en el nivel 1 (inferior). La posición elegida está en el nivel %.',
      v_level
      using errcode = 'check_violation';
  end if;

  if v_audience = 'ADULTO' and v_level = 1 then
    raise exception
      'Calzado de adulto no puede ubicarse en el nivel 1: está reservado para calzado infantil.'
      using errcode = 'check_violation';
  end if;

  -- UNISEX: sin restricción de nivel.
  return new;
end;
$$;

drop trigger if exists trg_assign_publico_nivel on public.position_assignments;
create trigger trg_assign_publico_nivel
  before insert or update on public.position_assignments
  for each row execute function public.fn_validar_publico_por_nivel();

comment on trigger trg_assign_publico_nivel on public.position_assignments is
  'Regla del jefe de almacén: infantil abajo (nivel 1), adulto arriba (nivel 2+). Se aplica en la base, no confía en que la UI la respete.';
