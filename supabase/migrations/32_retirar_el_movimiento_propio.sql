-- =============================================================================
--  MIGRACIÓN 32 — RETIRAR UN MOVIMIENTO PROPIO
--
--  Probando el flujo con el supervisor apareció una asimetría fea:
--
--    · Aprobar el propio movimiento responde con un mensaje claro:
--      "No puedes aprobar un movimiento que tú mismo creaste."
--    · Rechazarlo suelta el constraint en crudo:
--      'new row for relation "inventory_movements" violates check constraint
--       "ck_mov_segregacion"'.
--
--  Y detrás del mensaje feo había una pregunta de fondo: ¿debe uno poder
--  retirar lo que pidió por error? Obligar a pedirle a otro que rechace tu
--  propia errata es rígido y no protege de nada — quien lo creó todavía no ha
--  obtenido ninguna autorización, así que retirarlo no salta ningún control.
--
--  Lo que sí es una decisión de autorización es rechazar algo que YA está
--  aprobado: ahí hay un permiso concedido de por medio y quitarlo le
--  corresponde a otra persona.
--
--  Queda entonces:
--
--    PENDIENTE + lo retira quien lo creó  -> se permite, como retirada.
--                                            approved_by queda NULL (nadie
--                                            autorizó nada) y la nota lo dice.
--    APROBADO  + lo rechaza quien lo creó -> se niega, con mensaje claro.
--
--  El constraint ck_mov_segregacion no se toca: sigue exigiendo
--  approved_by <> created_by, y la retirada pasa justamente porque no escribe
--  approved_by.
--
--  Requiere 01-31. Idempotente.
-- =============================================================================

create or replace function public.fn_rechazar_movimiento(
  p_movement_id uuid,
  p_user_id     uuid default null,
  p_motivo      text default null
)
returns public.inventory_movements
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mov     public.inventory_movements;
  v_propio  boolean;
begin
  select * into v_mov from public.inventory_movements where id = p_movement_id for update;
  if not found then
    raise exception 'El movimiento no existe.';
  end if;
  if v_mov.executed_at is not null then
    raise exception 'No se puede rechazar un movimiento ya ejecutado. Usa una reversión.';
  end if;
  if v_mov.status = 'RECHAZADO' then
    raise exception 'Este movimiento ya estaba rechazado.';
  end if;

  v_propio := p_user_id is not null and v_mov.created_by = p_user_id;

  -- Rechazar algo ya autorizado es revocar el permiso de otro: no es tuyo.
  if v_propio and v_mov.status = 'APROBADO' then
    raise exception 'Este movimiento ya fue autorizado por otra persona: no puedes rechazarlo tú, que lo creaste. Pídeselo a un supervisor.';
  end if;

  -- Si estaba aprobado, hay stock comprometido que hay que devolver.
  if v_mov.status = 'APROBADO' and v_mov.inventory_id is not null then
    if v_mov.movement_type = 'SALIDA' then
      update public.inventory set qty_reserved = greatest(qty_reserved - v_mov.quantity, 0)
       where id = v_mov.inventory_id;
    elsif v_mov.movement_type = 'ENTRADA' then
      update public.inventory set qty_incoming = greatest(qty_incoming - v_mov.quantity, 0)
       where id = v_mov.inventory_id;
    end if;
  end if;

  -- El hueco apartado vuelve a estar libre.
  update public.position_assignments
     set status = 'LIBERADA', quantity = 0, released_at = now(),
         movement_id = null, updated_at = now()
   where movement_id = v_mov.id
     and status = 'RESERVADA';

  -- Lo comprometido vuelve a ser stock normal, salvo que otro pedido siga
  -- esperándolo.
  update public.position_assignments
     set status = 'OCUPADA', movement_id = null, updated_at = now()
   where movement_id = v_mov.id
     and status = 'EN_PICKING'
     and not public.fn_hay_salida_viva(position_id, item_id, v_mov.id);

  update public.position_assignments
     set movement_id = null, updated_at = now()
   where movement_id = v_mov.id;

  -- La diferencia está en approved_by. Una retirada no la autoriza nadie, así
  -- que se queda en NULL: es lo que distingue "me equivoqué y lo quito" de
  -- "otra persona lo revisó y dijo que no", y de paso es lo que hace que
  -- ck_mov_segregacion la acepte.
  update public.inventory_movements
     set status      = 'RECHAZADO',
         approved_at = now(),
         approved_by = case when v_propio then null else p_user_id end,
         notes = concat_ws(' | ', notes,
                           case when v_propio
                                then concat_ws(': ', 'Retirado por quien lo creó', p_motivo)
                                else coalesce(p_motivo, 'Rechazado') end)
   where id = p_movement_id
  returning * into v_mov;

  return v_mov;   -- el stock nunca se tocó, por diseño
end;
$$;

comment on function public.fn_rechazar_movimiento is
  'Rechaza un movimiento no ejecutado. Si lo retira quien lo creó y sigue pendiente, se acepta como retirada y approved_by queda NULL; si ya estaba aprobado, tiene que rechazarlo otra persona.';
