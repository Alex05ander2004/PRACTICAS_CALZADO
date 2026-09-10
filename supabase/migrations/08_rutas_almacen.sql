-- =============================================================================
--  MIGRACIÓN 08 — GRAFO DEL ALMACÉN: COORDENADAS REALES Y RUTA MÁS CORTA
--
--  Pedido del jefe: posiciones exactas (no "tarjetas en fila") y poder
--  calcular la ruta más corta entre dos puntos. Se modela el almacén como un
--  GRAFO: cada rack (la unidad por la que realmente se camina, no cada
--  posición individual) es un nodo con coordenadas X/Y reales, más un nodo
--  "ENTRADA" por almacén. Los pasillos caminables son las aristas, con su
--  distancia. El algoritmo de ruta (Dijkstra) corre en el cliente — el grafo
--  es chico (≤7 nodos por almacén) y así queda visible/explicable en la
--  sustentación, no escondido en una función opaca.
--
--  Fuera de alcance a propósito: no se sube ninguna imagen/plano para que el
--  sistema "detecte" racks solo — eso es un problema de visión por
--  computadora, no de bases de datos, y no era razonable para el tiempo
--  disponible. Las coordenadas son reales pero se cargan a mano (como se
--  cargaría un plano en cualquier WMS real la primera vez).
--
--  Requiere 01-07. Idempotente.
-- =============================================================================


-- =============================================================================
--  BLOQUE A — TABLAS DEL GRAFO
-- =============================================================================
create table if not exists public.warehouse_nodes (
  id           uuid primary key default gen_random_uuid(),
  warehouse_id uuid        not null references public.warehouses (id) on delete cascade,
  rack_id      uuid        unique references public.racks (id) on delete cascade,
  node_type    text        not null check (node_type in ('ENTRADA', 'RACK')),
  code         text        not null,
  x_coord      numeric     not null,
  y_coord      numeric     not null,
  created_at   timestamptz not null default now(),
  constraint uq_node_almacen_code unique (warehouse_id, code),
  constraint ck_node_rack_consistente check (
    (node_type = 'RACK'    and rack_id is not null)
    or
    (node_type = 'ENTRADA' and rack_id is null)
  )
);
comment on table public.warehouse_nodes is
  'Nodos del grafo de ruteo: un nodo ENTRADA por almacén + un nodo por rack (el rack, no cada posición, es la unidad por la que se camina).';

-- Aristas NO dirigidas (un pasillo se camina en los dos sentidos): el par se
-- guarda siempre ordenado (least, greatest) y el índice único de abajo impide
-- cargar la misma arista dos veces sin importar en qué orden se inserte.
create table if not exists public.warehouse_edges (
  id          uuid primary key default gen_random_uuid(),
  node_a_id   uuid    not null references public.warehouse_nodes (id) on delete cascade,
  node_b_id   uuid    not null references public.warehouse_nodes (id) on delete cascade,
  distancia   numeric not null check (distancia > 0),
  created_at  timestamptz not null default now(),
  constraint ck_edge_no_autolazo check (node_a_id <> node_b_id)
);
create unique index if not exists uq_edge_par
  on public.warehouse_edges (least(node_a_id, node_b_id), greatest(node_a_id, node_b_id));

comment on table public.warehouse_edges is
  'Pasillos caminables entre dos nodos. La distancia es la que recorre una persona, no necesariamente la línea recta.';

create index if not exists ix_nodes_warehouse on public.warehouse_nodes (warehouse_id);
create index if not exists ix_edges_node_a    on public.warehouse_edges (node_a_id);
create index if not exists ix_edges_node_b    on public.warehouse_edges (node_b_id);


-- =============================================================================
--  BLOQUE B — RLS
-- =============================================================================
alter table public.warehouse_nodes enable row level security;
alter table public.warehouse_edges enable row level security;

-- Igual que el resto del mapa: cualquier perfil activo lo puede leer (hace
-- falta para calcular una ruta), pero definir la topología del almacén es
-- trabajo de SUPERVISOR+, no algo que un operario deba poder tocar.
drop policy if exists p_nodes_select on public.warehouse_nodes;
create policy p_nodes_select on public.warehouse_nodes
  for select to authenticated using ((select public.fn_rol_actual()) is not null);
drop policy if exists p_nodes_write on public.warehouse_nodes;
create policy p_nodes_write on public.warehouse_nodes
  for insert to authenticated with check ((select public.fn_es_al_menos_supervisor()));
drop policy if exists p_nodes_update on public.warehouse_nodes;
create policy p_nodes_update on public.warehouse_nodes
  for update to authenticated
  using ((select public.fn_es_al_menos_supervisor()))
  with check ((select public.fn_es_al_menos_supervisor()));

drop policy if exists p_edges_select on public.warehouse_edges;
create policy p_edges_select on public.warehouse_edges
  for select to authenticated using ((select public.fn_rol_actual()) is not null);
drop policy if exists p_edges_write on public.warehouse_edges;
create policy p_edges_write on public.warehouse_edges
  for insert to authenticated with check ((select public.fn_es_al_menos_supervisor()));

revoke all on public.warehouse_nodes from anon;
revoke all on public.warehouse_edges from anon;
-- Sin política de DELETE en ninguna de las dos: mismo criterio que el resto
-- del sistema — la topología no se borra, se corrige con un UPDATE.


-- =============================================================================
--  BLOQUE C — GRAFO DE LOS 3 ALMACENES (coordenadas reales de referencia)
-- =============================================================================
-- Layout de ALM-A: dos filas de racks con la entrada abajo al centro.
--
--     RACK-06   RACK-07   RACK-08          y=50
--     RACK-01   RACK-03   RACK-05          y=150
--              ENTRADA                     y=250
--     x=50      x=150     x=250
do $$
begin
  if exists (select 1 from public.warehouse_nodes) then
    raise notice 'El grafo de almacenes ya estaba cargado, no se duplica.';
    return;
  end if;

  insert into public.warehouse_nodes (warehouse_id, rack_id, node_type, code, x_coord, y_coord)
  select w.id, r.id, 'RACK', r.code, x.xc, x.yc
    from (values
      ('ALM-A','RACK-01', 50, 150), ('ALM-A','RACK-03',150, 150), ('ALM-A','RACK-05',250, 150),
      ('ALM-A','RACK-06', 50,  50), ('ALM-A','RACK-07',150,  50), ('ALM-A','RACK-08',250,  50),
      ('BOD-B','RACK-01',100,  50), ('BOD-B','RACK-02',200,  50), ('BOD-B','RACK-04',300,  50),
      ('BOD-B','RACK-07',200, 150),
      ('BOD-C','RACK-02',100,  50), ('BOD-C','RACK-06',200,  50), ('BOD-C','RACK-07',150, 150)
    ) as x(wh_code, rack_code, xc, yc)
    join public.warehouses w on w.code = x.wh_code
    join public.racks      r on r.warehouse_id = w.id and r.code = x.rack_code;

  insert into public.warehouse_nodes (warehouse_id, rack_id, node_type, code, x_coord, y_coord)
  select w.id, null, 'ENTRADA', 'ENTRADA', x.xc, x.yc
    from (values ('ALM-A',150,250), ('BOD-B',0,50), ('BOD-C',0,50)) as x(wh_code, xc, yc)
    join public.warehouses w on w.code = x.wh_code;

  raise notice 'Nodos del grafo cargados: % ', (select count(*) from public.warehouse_nodes);
end;
$$;

-- Aristas: se calcula la distancia real (euclidiana) entre los dos nodos en
-- vez de tipearla a mano, para que no se desincronice de las coordenadas de
-- arriba si alguna vez cambian.
do $$
begin
  if exists (select 1 from public.warehouse_edges) then
    raise notice 'Las aristas ya estaban cargadas, no se duplican.';
    return;
  end if;

  insert into public.warehouse_edges (node_a_id, node_b_id, distancia)
  select na.id, nb.id, sqrt(power(na.x_coord - nb.x_coord, 2) + power(na.y_coord - nb.y_coord, 2))
    from (values
      -- ALM-A: entrada a la fila de abajo, fila de abajo entre sí, y cada
      -- rack de abajo con el que tiene encima (pasillo vertical).
      ('ALM-A','ENTRADA','RACK-01'), ('ALM-A','ENTRADA','RACK-03'), ('ALM-A','ENTRADA','RACK-05'),
      ('ALM-A','RACK-01','RACK-03'), ('ALM-A','RACK-03','RACK-05'),
      ('ALM-A','RACK-01','RACK-06'), ('ALM-A','RACK-03','RACK-07'), ('ALM-A','RACK-05','RACK-08'),
      ('ALM-A','RACK-06','RACK-07'), ('ALM-A','RACK-07','RACK-08'),
      -- BOD-B: una fila principal + RACK-07 colgando de RACK-02.
      ('BOD-B','ENTRADA','RACK-01'), ('BOD-B','RACK-01','RACK-02'), ('BOD-B','RACK-02','RACK-04'),
      ('BOD-B','RACK-02','RACK-07'),
      -- BOD-C: triángulo simple, más de un camino posible (bueno para
      -- demostrar que Dijkstra elige el corto, no el primero que encuentra).
      ('BOD-C','ENTRADA','RACK-02'), ('BOD-C','RACK-02','RACK-06'),
      ('BOD-C','RACK-02','RACK-07'), ('BOD-C','RACK-06','RACK-07')
    ) as x(wh_code, code_a, code_b)
    join public.warehouses      w  on w.code = x.wh_code
    join public.warehouse_nodes na on na.warehouse_id = w.id and na.code = x.code_a
    join public.warehouse_nodes nb on nb.warehouse_id = w.id and nb.code = x.code_b;

  raise notice 'Aristas cargadas: %', (select count(*) from public.warehouse_edges);
end;
$$;


-- =============================================================================
--  VERIFICACIÓN
-- =============================================================================
select
  w.code as almacen,
  count(distinct n.id) as nodos,
  count(distinct e.id) as aristas
from public.warehouses w
left join public.warehouse_nodes n on n.warehouse_id = w.id
left join public.warehouse_edges e on e.node_a_id = n.id
group by w.code
order by w.code;
-- Esperado: ALM-A 7 nodos/10 aristas, BOD-B 5 nodos/4 aristas, BOD-C 4 nodos/4 aristas.
