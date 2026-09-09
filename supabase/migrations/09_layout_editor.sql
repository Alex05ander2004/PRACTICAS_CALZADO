-- =============================================================================
--  MIGRACIÓN 09 — EL ALMACÉN COMO GEOMETRÍA: GRILLA, RACKS CON FORMA Y A*
--
--  Cambio de enfoque respecto de la migración 08. Ahí el grafo de pasillos se
--  declaraba a mano (el nodo A conecta con el nodo B). Eso funciona mientras
--  nadie mueva nada — pero si el layout se edita visualmente (arrastrar racks
--  para armar el almacén como es en la realidad), un grafo escrito a mano
--  queda desactualizado en el primer movimiento.
--
--  El modelo correcto para un layout editable es GEOMETRÍA, no topología:
--    - El almacén es una grilla de celdas (grid_ancho x grid_alto), 1 celda ≈ 1 m.
--    - Cada rack es un RECTÁNGULO sobre esa grilla: ocupa celdas y las bloquea.
--    - La ruta más corta se calcula con A* sobre las celdas libres, esquivando
--      los rectángulos. Al mover un rack las rutas cambian solas: no queda
--      ninguna topología que mantener sincronizada a mano.
--
--  Por eso esta migración ELIMINA warehouse_nodes y warehouse_edges. Solo
--  contenían la topología semilla que cargó la propia migración 08 — ningún
--  dato ingresado por un usuario.
--
--  Requiere 01-08. Idempotente.
-- =============================================================================


-- =============================================================================
--  BLOQUE A — DIMENSIONES DEL ALMACÉN Y GEOMETRÍA DE CADA RACK
-- =============================================================================
alter table public.warehouses
  add column if not exists grid_ancho integer not null default 40,
  add column if not exists grid_alto  integer not null default 30,
  add column if not exists entrada_x  integer not null default 20,
  add column if not exists entrada_y  integer not null default 28;

alter table public.racks
  add column if not exists grid_x     integer,
  add column if not exists grid_y     integer,
  add column if not exists grid_ancho integer not null default 14,
  add column if not exists grid_alto  integer not null default 2;

comment on column public.racks.grid_x is
  'Esquina superior izquierda del rack sobre la grilla del almacén. El rack ocupa (grid_ancho x grid_alto) celdas y las bloquea para el cálculo de rutas.';
comment on column public.warehouses.grid_ancho is
  'Ancho del piso en celdas (1 celda ≈ 1 metro). El editor de layout trabaja sobre esta grilla.';


-- =============================================================================
--  BLOQUE B — LAYOUT INICIAL REALISTA (dos columnas de racks con pasillos)
-- =============================================================================
-- Se aplica ANTES de crear el trigger anti-solape a propósito: mover los racks
-- de a uno los haría pisarse transitoriamente y el trigger abortaría la
-- migración. El layout que se escribe acá es válido por construcción:
--
--     x:  3────17    21────35        (racks de 14 celdas de ancho)
--     y:3  ███████    ███████        fila 1
--     y:9  ███████    ███████        fila 2   (pasillo horizontal entre filas)
--     y:15 ███████    ███████        fila 3
--     y:28        ▲ ENTRADA          (pasillo perimetral libre)
do $$
declare
  r record;
  v_i integer;
begin
  for r in
    select rk.id,
           (row_number() over (partition by rk.warehouse_id order by rk.code) - 1)::int as n
      from public.racks rk
  loop
    v_i := r.n;
    update public.racks
       set grid_x     = 3 + (v_i % 2) * 18,
           grid_y     = 3 + (v_i / 2) * 6,
           grid_ancho = 14,
           grid_alto  = 2
     where id = r.id;
  end loop;

  update public.warehouses set entrada_x = 20, entrada_y = 28;
  raise notice 'Layout inicial aplicado a % racks.', (select count(*) from public.racks);
end;
$$;

alter table public.racks
  alter column grid_x set not null,
  alter column grid_y set not null;

alter table public.racks drop constraint if exists ck_racks_geometria;
alter table public.racks
  add constraint ck_racks_geometria check (
    grid_x >= 0 and grid_y >= 0 and grid_ancho between 1 and 60 and grid_alto between 1 and 60
  );


-- =============================================================================
--  BLOQUE C — UN RACK NO PUEDE SALIRSE DEL PLANO NI PISAR A OTRO
-- =============================================================================
-- Mismo criterio que el resto del sistema: la regla vive en la base, no en el
-- editor. Si el arrastre del editor tiene un bug, la base no deja guardar un
-- layout imposible.
create or replace function public.fn_validar_geometria_rack()
returns trigger
language plpgsql
as $$
declare
  v_ancho_alm integer;
  v_alto_alm  integer;
  v_conflicto text;
begin
  select grid_ancho, grid_alto into v_ancho_alm, v_alto_alm
    from public.warehouses where id = new.warehouse_id;

  if new.grid_x + new.grid_ancho > v_ancho_alm or new.grid_y + new.grid_alto > v_alto_alm then
    raise exception 'El rack % no cabe: se sale del plano del almacén (% x % celdas).',
      new.code, v_ancho_alm, v_alto_alm
      using errcode = 'check_violation';
  end if;

  -- Dos rectángulos se pisan solo si se solapan en LOS DOS ejes a la vez.
  select code into v_conflicto
    from public.racks
   where warehouse_id = new.warehouse_id
     and id <> new.id
     and new.grid_x < grid_x + grid_ancho
     and grid_x     < new.grid_x + new.grid_ancho
     and new.grid_y < grid_y + grid_alto
     and grid_y     < new.grid_y + new.grid_alto
   limit 1;

  if v_conflicto is not null then
    raise exception 'El rack % se superpone con el rack %. Muévelo a un espacio libre.',
      new.code, v_conflicto
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_racks_geometria on public.racks;
create trigger trg_racks_geometria
  before insert or update of grid_x, grid_y, grid_ancho, grid_alto on public.racks
  for each row execute function public.fn_validar_geometria_rack();


-- =============================================================================
--  BLOQUE D — FUERA EL GRAFO DECLARADO A MANO
-- =============================================================================
drop table if exists public.warehouse_edges;
drop table if exists public.warehouse_nodes;


-- =============================================================================
--  VERIFICACIÓN
-- =============================================================================
select
  w.code as almacen,
  w.grid_ancho || ' x ' || w.grid_alto  as plano,
  w.entrada_x || ',' || w.entrada_y      as entrada,
  count(r.id)                            as racks,
  coalesce(max(r.grid_x + r.grid_ancho), 0) as borde_derecho,
  coalesce(max(r.grid_y + r.grid_alto), 0)  as borde_inferior
from public.warehouses w
left join public.racks r on r.warehouse_id = w.id
group by w.code, w.grid_ancho, w.grid_alto, w.entrada_x, w.entrada_y
order by w.code;
-- Esperado: 3 almacenes en 40x30, entrada 20,28, y ningún borde pasando de 40/30.
